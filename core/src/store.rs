use std::path::Path;

use rusqlite::{Connection, OptionalExtension, params};

use crate::search::TitleIndex;
use crate::{Error, Result, schema};

const TITLE_MAX_CHARS: usize = 300;

/// Pasteboard types that change on every copy and must not affect identity.
const TRANSIENT_UTIS: &[&str] = &[
    "org.chromium.source-url",
    "org.chromium.internal.source-rfh-token",
    "com.apple.linkpresentation.metadata",
    "com.apple.WebKit.custom-pasteboard-data",
];

const UTI_TEXT: &str = "public.utf8-plain-text";
const UTI_HTML: &str = "public.html";
const UTI_RTF: &str = "public.rtf";
const UTI_FILE_URL: &str = "public.file-url";
const IMAGE_UTIS: &[&str] = &["public.png", "public.tiff", "public.jpeg", "public.heic"];

#[derive(Debug, Clone, uniffi::Record)]
pub struct Rep {
    pub uti: String,
    pub data: Vec<u8>,
}

/// What the Swift side hands over after reading the pasteboard.
/// Anything that needs AppKit (RTF→text, image thumbnails) is done there,
/// off the main thread, before calling `ingest`.
#[derive(Debug, Clone, Default, uniffi::Record)]
pub struct Capture {
    pub reps: Vec<Rep>,
    pub app: Option<String>,
    /// Plain text derived from RTF by the caller, when the pasteboard had no plain text.
    pub derived_text: Option<String>,
    pub thumbnail_png: Option<Vec<u8>>,
    pub copied_at: i64,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct IngestResult {
    pub id: i64,
    pub deduplicated: bool,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct ItemSummary {
    pub id: i64,
    pub kind: String,
    pub title: String,
    pub app: Option<String>,
    pub text_bytes: i64,
    pub last_copied_at: i64,
    pub copy_count: i64,
    pub pin: Option<String>,
}

pub struct Store {
    conn: Connection,
    titles: TitleIndex,
}

impl Store {
    pub fn open(path: &Path) -> Result<Self> {
        Self::with_connection(Connection::open(path)?)
    }

    pub fn open_in_memory() -> Result<Self> {
        Self::with_connection(Connection::open_in_memory()?)
    }

    fn with_connection(conn: Connection) -> Result<Self> {
        schema::migrate(&conn)?;
        let mut store = Store { conn, titles: TitleIndex::default() };
        store.reload_titles()?;
        Ok(store)
    }

    fn reload_titles(&mut self) -> Result<()> {
        let mut stmt = self
            .conn
            .prepare("SELECT id, title FROM items ORDER BY last_copied_at DESC")?;
        let rows = stmt.query_map([], |r| Ok((r.get(0)?, r.get(1)?)))?;
        self.titles = TitleIndex::from_rows(rows.collect::<rusqlite::Result<_>>()?);
        Ok(())
    }

    pub fn ingest(&mut self, capture: Capture) -> Result<IngestResult> {
        let hash = *content_hash(&capture.reps).as_bytes();
        let tx = self.conn.transaction()?;

        let existing: Option<i64> = tx
            .query_row("SELECT id FROM items WHERE content_hash = ?1", [&hash[..]], |r| r.get(0))
            .optional()?;
        if let Some(id) = existing {
            tx.execute(
                "UPDATE items SET last_copied_at = ?2, copy_count = copy_count + 1, app = COALESCE(?3, app)
                 WHERE id = ?1",
                params![id, capture.copied_at, capture.app],
            )?;
            tx.commit()?;
            self.titles.touch(id);
            return Ok(IngestResult { id, deduplicated: true });
        }

        let kind = classify(&capture.reps);
        let text = plain_text(&capture);
        let title = make_title(&text, kind);

        tx.execute(
            "INSERT INTO items (content_hash, kind, title, app, text_bytes, first_copied_at, last_copied_at)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?6)",
            params![&hash[..], kind, title, capture.app, text.len() as i64, capture.copied_at],
        )?;
        let id = tx.last_insert_rowid();

        for rep in &capture.reps {
            tx.execute(
                "INSERT OR REPLACE INTO reps (item_id, uti, data) VALUES (?1, ?2, ?3)",
                params![id, rep.uti, rep.data],
            )?;
        }
        if !text.is_empty() {
            tx.execute("INSERT INTO item_text (item_id, body) VALUES (?1, ?2)", params![id, text])?;
            tx.execute("INSERT INTO item_fts (rowid, body) VALUES (?1, ?2)", params![id, text])?;
        }
        if let Some(png) = &capture.thumbnail_png {
            tx.execute("INSERT INTO thumbnails (item_id, png) VALUES (?1, ?2)", params![id, png])?;
        }
        tx.commit()?;

        self.titles.push_front(id, title);
        Ok(IngestResult { id, deduplicated: false })
    }

    /// One page of list rows. Never reads payload tables.
    pub fn list(&self, offset: i64, limit: i64) -> Result<Vec<ItemSummary>> {
        let mut stmt = self.conn.prepare_cached(
            "SELECT id, kind, title, app, text_bytes, last_copied_at, copy_count, pin
             FROM items ORDER BY last_copied_at DESC LIMIT ?1 OFFSET ?2",
        )?;
        let rows = stmt.query_map(params![limit, offset], summary_from_row)?;
        Ok(rows.collect::<rusqlite::Result<_>>()?)
    }

    pub fn summaries(&self, ids: &[i64]) -> Result<Vec<ItemSummary>> {
        let mut stmt = self.conn.prepare_cached(
            "SELECT id, kind, title, app, text_bytes, last_copied_at, copy_count, pin
             FROM items WHERE id = ?1",
        )?;
        // Ids deleted since the caller got them are skipped, not an error.
        let mut out = Vec::with_capacity(ids.len());
        for id in ids {
            if let Some(summary) = stmt.query_row([id], summary_from_row).optional()? {
                out.push(summary);
            }
        }
        Ok(out)
    }

    /// Reads at most `max_bytes` of the item's text starting at `byte_offset`,
    /// trimmed to UTF-8 boundaries. Preview pages through long text with this.
    pub fn preview_text(&self, id: i64, byte_offset: i64, max_bytes: i64) -> Result<String> {
        // Read 3 extra bytes on each side so a boundary-split scalar can be dropped cleanly.
        let start = (byte_offset - 3).max(0);
        let lead = byte_offset - start;
        let bytes: Option<Vec<u8>> = self
            .conn
            .query_row(
                "SELECT substr(CAST(body AS BLOB), ?2 + 1, ?3) FROM item_text WHERE item_id = ?1",
                params![id, start, max_bytes + lead],
                |r| r.get(0),
            )
            .optional()?;
        let bytes = bytes.ok_or(Error::NotFound(id))?;
        Ok(utf8_window(&bytes, lead as usize))
    }

    pub fn thumbnail(&self, id: i64) -> Result<Option<Vec<u8>>> {
        Ok(self
            .conn
            .query_row("SELECT png FROM thumbnails WHERE item_id = ?1", [id], |r| r.get(0))
            .optional()?)
    }

    /// Raw representations for writing back to the pasteboard.
    pub fn reps(&self, id: i64) -> Result<Vec<Rep>> {
        let mut stmt = self.conn.prepare_cached("SELECT uti, data FROM reps WHERE item_id = ?1")?;
        let rows = stmt.query_map([id], |r| Ok(Rep { uti: r.get(0)?, data: r.get(1)? }))?;
        Ok(rows.collect::<rusqlite::Result<_>>()?)
    }

    pub fn set_pin(&mut self, id: i64, pin: Option<&str>) -> Result<()> {
        self.conn.execute("UPDATE items SET pin = ?2 WHERE id = ?1", params![id, pin])?;
        Ok(())
    }

    pub fn delete(&mut self, id: i64) -> Result<()> {
        let tx = self.conn.transaction()?;
        tx.execute("DELETE FROM item_fts WHERE rowid = ?1", [id])?;
        tx.execute("DELETE FROM items WHERE id = ?1", [id])?;
        tx.commit()?;
        self.titles.remove(id);
        Ok(())
    }

    /// Keeps the newest `max_items` unpinned items.
    pub fn trim(&mut self, max_items: i64) -> Result<usize> {
        let tx = self.conn.transaction()?;
        let doomed = "SELECT id FROM items WHERE pin IS NULL
                      ORDER BY last_copied_at DESC LIMIT -1 OFFSET ?1";
        tx.execute(&format!("DELETE FROM item_fts WHERE rowid IN ({doomed})"), [max_items])?;
        let removed = tx.execute(&format!("DELETE FROM items WHERE id IN ({doomed})"), [max_items])?;
        tx.commit()?;
        if removed > 0 {
            self.reload_titles()?;
        }
        Ok(removed)
    }

    pub fn len(&self) -> usize {
        self.titles.len()
    }

    pub fn is_empty(&self) -> bool {
        self.titles.len() == 0
    }

    pub(crate) fn conn(&self) -> &Connection {
        &self.conn
    }

    pub(crate) fn titles_mut(&mut self) -> &mut TitleIndex {
        &mut self.titles
    }
}

fn summary_from_row(r: &rusqlite::Row) -> rusqlite::Result<ItemSummary> {
    Ok(ItemSummary {
        id: r.get(0)?,
        kind: r.get(1)?,
        title: r.get(2)?,
        app: r.get(3)?,
        text_bytes: r.get(4)?,
        last_copied_at: r.get(5)?,
        copy_count: r.get(6)?,
        pin: r.get(7)?,
    })
}

fn content_hash(reps: &[Rep]) -> blake3::Hash {
    let mut stable: Vec<&Rep> = reps.iter().filter(|r| !TRANSIENT_UTIS.contains(&r.uti.as_str())).collect();
    stable.sort_by(|a, b| a.uti.cmp(&b.uti));
    let mut hasher = blake3::Hasher::new();
    for rep in stable {
        hasher.update(&(rep.uti.len() as u64).to_le_bytes());
        hasher.update(rep.uti.as_bytes());
        hasher.update(&(rep.data.len() as u64).to_le_bytes());
        hasher.update(&rep.data);
    }
    hasher.finalize()
}

fn find<'a>(reps: &'a [Rep], uti: &str) -> Option<&'a [u8]> {
    reps.iter().find(|r| r.uti == uti).map(|r| r.data.as_slice())
}

fn classify(reps: &[Rep]) -> &'static str {
    let has = |uti: &str| reps.iter().any(|r| r.uti == uti);
    if has(UTI_FILE_URL) {
        "files"
    } else if IMAGE_UTIS.iter().any(|u| has(u)) && !has(UTI_TEXT) {
        "image"
    } else if has(UTI_HTML) || has(UTI_RTF) {
        "rich"
    } else {
        "text"
    }
}

fn plain_text(capture: &Capture) -> String {
    if let Some(text) = find(&capture.reps, UTI_TEXT) {
        return String::from_utf8_lossy(text).into_owned();
    }
    if let Some(text) = &capture.derived_text {
        return text.clone();
    }
    if let Some(html) = find(&capture.reps, UTI_HTML) {
        // Width is effectively unlimited: we want text, not wrapped layout.
        return html2text::from_read(html, usize::MAX / 2).unwrap_or_default();
    }
    String::new()
}

fn make_title(text: &str, kind: &str) -> String {
    let mut title = String::with_capacity(TITLE_MAX_CHARS);
    let mut last_space = true;
    for ch in text.chars() {
        if title.chars().count() >= TITLE_MAX_CHARS {
            break;
        }
        if ch.is_whitespace() || ch.is_control() {
            if !last_space {
                title.push(' ');
            }
            last_space = true;
        } else {
            title.push(ch);
            last_space = false;
        }
    }
    let title = title.trim_end().to_owned();
    if title.is_empty() { format!("[{kind}]") } else { title }
}

/// Drops the partial scalars at both ends of a byte window.
/// `lead` is how many bytes before the requested offset were included.
fn utf8_window(bytes: &[u8], lead: usize) -> String {
    let is_cont = |b: u8| b & 0b1100_0000 == 0b1000_0000;
    let mut start = lead.min(bytes.len());
    while start < bytes.len() && is_cont(bytes[start]) {
        start += 1;
    }
    let mut end = bytes.len();
    // Walk back to the last scalar start and keep it only if it is complete.
    if let Some(last) = (start..end).rev().find(|&i| !is_cont(bytes[i])) {
        let width = match bytes[last] {
            b if b < 0x80 => 1,
            b if b >= 0xF0 => 4,
            b if b >= 0xE0 => 3,
            _ => 2,
        };
        if last + width > end {
            end = last;
        }
    }
    String::from_utf8_lossy(&bytes[start..end]).into_owned()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn text(s: &str, at: i64) -> Capture {
        Capture {
            reps: vec![Rep { uti: UTI_TEXT.into(), data: s.as_bytes().to_vec() }],
            copied_at: at,
            ..Default::default()
        }
    }

    #[test]
    fn dedup_ignores_transient_reps_and_bumps_recency() {
        let mut store = Store::open_in_memory().unwrap();
        let a = store.ingest(text("hello", 1)).unwrap();
        let _b = store.ingest(text("other", 2)).unwrap();
        let mut again = text("hello", 3);
        again.reps.push(Rep { uti: "org.chromium.source-url".into(), data: b"x".to_vec() });
        let c = store.ingest(again).unwrap();

        assert_eq!(c, IngestResult { id: a.id, deduplicated: true });
        let rows = store.list(0, 10).unwrap();
        assert_eq!(rows.len(), 2);
        assert_eq!(rows[0].title, "hello");
        assert_eq!(rows[0].copy_count, 2);
    }

    #[test]
    fn html_only_capture_gets_text_title_and_preview() {
        let mut store = Store::open_in_memory().unwrap();
        let capture = Capture {
            reps: vec![Rep { uti: UTI_HTML.into(), data: b"<p>Hello <b>world</b></p>".to_vec() }],
            copied_at: 1,
            ..Default::default()
        };
        let id = store.ingest(capture).unwrap().id;
        let row = &store.list(0, 1).unwrap()[0];
        assert_eq!(row.kind, "rich");
        assert!(row.title.contains("Hello") && row.title.contains("world"), "{}", row.title);
        assert!(store.preview_text(id, 0, 100).unwrap().contains("world"));
    }

    #[test]
    fn preview_pages_on_utf8_boundaries() {
        let mut store = Store::open_in_memory().unwrap();
        let body = "가나다라마바사".repeat(1000); // 3 bytes per scalar
        let id = store.ingest(text(&body, 1)).unwrap().id;

        let mut rebuilt = String::new();
        let mut offset = 0;
        while offset < body.len() as i64 {
            let chunk = store.preview_text(id, offset, 1000).unwrap();
            assert!(!chunk.is_empty());
            offset += chunk.len() as i64;
            rebuilt.push_str(&chunk);
        }
        assert_eq!(rebuilt, body);
    }

    #[test]
    fn title_is_single_line_and_bounded() {
        let long = format!("  first\n\tsecond {}", "x".repeat(10_000));
        let title = make_title(&long, "text");
        assert!(title.starts_with("first second"));
        assert_eq!(title.chars().count(), TITLE_MAX_CHARS);
    }

    #[test]
    fn trim_keeps_pins_and_newest() {
        let mut store = Store::open_in_memory().unwrap();
        let pinned = store.ingest(text("pinned", 0)).unwrap().id;
        store.set_pin(pinned, Some("p")).unwrap();
        for i in 1..=10 {
            store.ingest(text(&format!("item {i}"), i)).unwrap();
        }
        assert_eq!(store.trim(3).unwrap(), 7);
        let titles: Vec<_> = store.list(0, 10).unwrap().into_iter().map(|r| r.title).collect();
        assert_eq!(titles, ["item 10", "item 9", "item 8", "pinned"]);
    }
}
