use rusqlite::Connection;

/// Metadata (`items`) is split from payloads (`reps`, `item_text`, `thumbnails`)
/// so listing and searching never page in blobs.
pub const SCHEMA: &str = r#"
PRAGMA journal_mode = WAL;
PRAGMA foreign_keys = ON;

CREATE TABLE IF NOT EXISTS items (
    id              INTEGER PRIMARY KEY,
    content_hash    BLOB    NOT NULL UNIQUE,
    kind            TEXT    NOT NULL,          -- text | link | rich | image | files | color | note
    title           TEXT    NOT NULL,          -- <= TITLE_MAX_CHARS, single line
    app             TEXT,
    text_bytes      INTEGER NOT NULL DEFAULT 0,
    first_copied_at INTEGER NOT NULL,
    last_copied_at  INTEGER NOT NULL,
    copy_count      INTEGER NOT NULL DEFAULT 1,
    pin             TEXT UNIQUE
);
-- Browse order. Ties on the time break by id so every view agrees (see search.rs).
CREATE INDEX IF NOT EXISTS items_recent ON items(last_copied_at DESC, id DESC);

-- Raw pasteboard representations, read only when pasting.
CREATE TABLE IF NOT EXISTS reps (
    item_id INTEGER NOT NULL REFERENCES items(id) ON DELETE CASCADE,
    uti     TEXT    NOT NULL,
    data    BLOB    NOT NULL,
    PRIMARY KEY (item_id, uti)
);

-- Full plain text, read in byte-range chunks for preview.
CREATE TABLE IF NOT EXISTS item_text (
    item_id INTEGER PRIMARY KEY REFERENCES items(id) ON DELETE CASCADE,
    body    TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS thumbnails (
    item_id INTEGER PRIMARY KEY REFERENCES items(id) ON DELETE CASCADE,
    png     BLOB NOT NULL
);

-- Substring search over full text. Trigram works for CJK without a segmenter.
CREATE VIRTUAL TABLE IF NOT EXISTS item_fts USING fts5(
    body, content='', contentless_delete=1, tokenize='trigram'
);
"#;

/// Steps applied in order after `SCHEMA`; `PRAGMA user_version` records how many ran.
/// Append only: never edit or reorder a step that has shipped.
const MIGRATIONS: &[&str] = &[
    // 1: counts for the preview's info line, computed once at ingest.
    "ALTER TABLE items ADD COLUMN char_count INTEGER NOT NULL DEFAULT 0;
     ALTER TABLE items ADD COLUMN line_count INTEGER NOT NULL DEFAULT 0;",
    // 2: text recognized in images. A row, even an empty one, marks the image as done.
    "CREATE TABLE item_ocr (
         item_id INTEGER PRIMARY KEY REFERENCES items(id) ON DELETE CASCADE,
         body    TEXT NOT NULL
     );",
    // 3: break ties on copy time by id, so equal times have one order everywhere.
    "DROP INDEX items_recent;
     CREATE INDEX items_recent ON items(last_copied_at DESC, id DESC);",
    // 4: say how many files a multi-file copy holds, as new ones are titled.
    "UPDATE items SET title = line_count || ' files: ' || title WHERE kind = 'files' AND line_count > 1;",
    // 5: browser tabs seen, open (closed_at NULL) or closed, one row per address per browser (tabs.rs).
    "CREATE TABLE tabs (
         id         INTEGER PRIMARY KEY,
         browser    TEXT    NOT NULL,
         url        TEXT    NOT NULL,
         title      TEXT    NOT NULL,
         first_seen INTEGER NOT NULL,
         last_seen  INTEGER NOT NULL,
         closed_at  INTEGER,
         text       TEXT,
         UNIQUE (browser, url)
     );
     CREATE INDEX tabs_closed ON tabs(closed_at DESC, id DESC) WHERE closed_at IS NOT NULL;",
    // 6: pages visited, copied from the browsers' history (history.rs).
    "CREATE TABLE history (
         id          INTEGER PRIMARY KEY,
         browser     TEXT    NOT NULL,
         url         TEXT    NOT NULL,
         title       TEXT    NOT NULL,
         last_visit  INTEGER NOT NULL,
         visit_count INTEGER NOT NULL,
         UNIQUE (browser, url)
     );
     CREATE INDEX history_recent ON history(last_visit DESC, id DESC);",
    // 7: when each tab was last the one shown, for listing tabs latest first (tabs.rs).
    "ALTER TABLE tabs ADD COLUMN last_active INTEGER;",
];

pub fn migrate(conn: &Connection) -> rusqlite::Result<()> {
    conn.execute_batch(SCHEMA)?;
    let applied: i64 = conn.query_row("PRAGMA user_version", [], |r| r.get(0))?;
    for (i, step) in MIGRATIONS.iter().enumerate().skip(applied as usize) {
        let tx = conn.unchecked_transaction()?;
        tx.execute_batch(step)?;
        tx.pragma_update(None, "user_version", i as i64 + 1)?;
        tx.commit()?;
    }
    Ok(())
}
