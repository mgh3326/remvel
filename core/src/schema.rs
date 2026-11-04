use rusqlite::Connection;

/// Metadata (`items`) is split from payloads (`reps`, `item_text`, `thumbnails`)
/// so listing and searching never page in blobs.
pub const SCHEMA: &str = r#"
PRAGMA journal_mode = WAL;
PRAGMA foreign_keys = ON;

CREATE TABLE IF NOT EXISTS items (
    id              INTEGER PRIMARY KEY,
    content_hash    BLOB    NOT NULL UNIQUE,
    kind            TEXT    NOT NULL,          -- text | rich | image | files
    title           TEXT    NOT NULL,          -- <= TITLE_MAX_CHARS, single line
    app             TEXT,
    text_bytes      INTEGER NOT NULL DEFAULT 0,
    first_copied_at INTEGER NOT NULL,
    last_copied_at  INTEGER NOT NULL,
    copy_count      INTEGER NOT NULL DEFAULT 1,
    pin             TEXT UNIQUE
);
CREATE INDEX IF NOT EXISTS items_recent ON items(last_copied_at DESC);

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

pub fn migrate(conn: &Connection) -> rusqlite::Result<()> {
    conn.execute_batch(SCHEMA)
}
