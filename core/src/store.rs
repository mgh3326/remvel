use std::path::Path;

use rusqlite::{Connection, OptionalExtension, params};

use crate::search::{Entry, TitleIndex};
use crate::{Error, Kind, Result, schema};

const TITLE_MAX_CHARS: usize = 300;

/// The columns `summary_from_row` reads, in its order.
const SUMMARY_COLUMNS: &str =
    "id, kind, title, app, text_bytes, last_copied_at, copy_count, pin, char_count, line_count, first_copied_at";

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
/// Remvel's own rep for file copies: every copied path, one per line.
/// The pasteboard keeps one item per file; this keeps all of them in one item.
pub const UTI_FILE_PATHS: &str = "io.github.remvel.file-paths";
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
    /// Title for items without text, e.g. "Image 1920 × 1080".
    pub title: Option<String>,
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
    pub kind: Kind,
    pub title: String,
    pub app: Option<String>,
    pub text_bytes: i64,
    pub first_copied_at: i64,
    pub last_copied_at: i64,
    pub copy_count: i64,
    pub pin: Option<String>,
    pub char_count: i64,
    pub line_count: i64,
}

/// A source app and how many items came from it.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct Facet {
    pub name: String,
    pub count: i64,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct KindFacet {
    pub kind: Kind,
    pub count: i64,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct Facets {
    pub kinds: Vec<KindFacet>,
    pub apps: Vec<Facet>,
}

/// The pin value for an item pinned at `at` (Unix ms). Pins sort as strings, so values are
/// fixed-width and the first pinned stays first.
pub fn pin_value(at: i64) -> String {
    format!("{:013}", at.max(0))
}

pub struct Store {
    pub(crate) conn: Connection,
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
        let mut stmt = self.conn.prepare(
            "SELECT id, title, kind, app, last_copied_at, pin FROM items ORDER BY last_copied_at DESC, id DESC",
        )?;
        let rows = stmt.query_map([], |r| {
            Ok(Entry::new(
                r.get(0)?,
                r.get(1)?,
                r.get(2)?,
                r.get::<_, Option<String>>(3)?.as_deref(),
                r.get(4)?,
                r.get::<_, Option<String>>(5)?.as_deref(),
            ))
        })?;
        self.titles = TitleIndex::from_entries(rows.collect::<rusqlite::Result<_>>()?);
        Ok(())
    }

    pub fn ingest(&mut self, capture: Capture) -> Result<IngestResult> {
        let hash = *content_hash(&capture.reps).as_bytes();
        let tx = self.conn.transaction()?;

        let existing: Option<i64> =
            tx.query_row("SELECT id FROM items WHERE content_hash = ?1", [&hash[..]], |r| r.get(0)).optional()?;
        if let Some(id) = existing {
            tx.execute(
                "UPDATE items SET last_copied_at = ?2, copy_count = copy_count + 1, app = COALESCE(?3, app)
                 WHERE id = ?1",
                params![id, capture.copied_at, capture.app],
            )?;
            tx.commit()?;
            self.titles.touch(id, capture.copied_at, capture.app.as_deref());
            return Ok(IngestResult { id, deduplicated: true });
        }

        let text = plain_text(&capture);
        let kind = classify(&capture.reps, &text);
        let title = match (find(&capture.reps, UTI_FILE_PATHS), &capture.title) {
            (Some(paths), _) => file_title(&String::from_utf8_lossy(paths)),
            (None, Some(title)) if text.trim().is_empty() => make_title(title, kind),
            _ => make_title(&text, kind),
        };
        let char_count = text.chars().count() as i64;
        let line_count = if text.is_empty() { 0 } else { text.lines().count() as i64 };

        tx.execute(
            "INSERT INTO items (content_hash, kind, title, app, text_bytes, first_copied_at, last_copied_at,
                                char_count, line_count)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?6, ?7, ?8)",
            params![&hash[..], kind, title, capture.app, text.len() as i64, capture.copied_at, char_count, line_count],
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

        self.titles.insert(Entry::new(id, title, kind, capture.app.as_deref(), capture.copied_at, None));
        Ok(IngestResult { id, deduplicated: false })
    }

    /// Marks an item as just used, e.g. after Remvel pasted it, without a new capture.
    pub fn touch(&mut self, id: i64, at: i64) -> Result<()> {
        let changed = self.conn.execute(
            "UPDATE items SET last_copied_at = ?2, copy_count = copy_count + 1 WHERE id = ?1",
            params![id, at],
        )?;
        if changed == 0 {
            return Err(Error::NotFound(id));
        }
        self.titles.touch(id, at, None);
        Ok(())
    }

    /// One page of the browse order (see `search`): pinned items first in pin order,
    /// then the rest newest first. Never reads payload tables.
    pub fn list(&self, offset: i64, limit: i64) -> Result<Vec<ItemSummary>> {
        let pinned = self.pinned()?;
        let pinned_count = pinned.len() as i64;
        let mut out: Vec<ItemSummary> =
            pinned.into_iter().skip(offset.max(0) as usize).take(limit.max(0) as usize).collect();
        let remaining = limit - out.len() as i64;
        if remaining > 0 {
            // Without INDEXED BY, SQLite reads every unpinned row through the pin index and sorts them.
            let mut stmt = self.conn.prepare_cached(&format!(
                "SELECT {SUMMARY_COLUMNS} FROM items INDEXED BY items_recent
                 WHERE pin IS NULL ORDER BY last_copied_at DESC, id DESC LIMIT ?1 OFFSET ?2"
            ))?;
            let rows = stmt.query_map(params![remaining, (offset - pinned_count).max(0)], summary_from_row)?;
            out.extend(rows.collect::<rusqlite::Result<Vec<_>>>()?);
        }
        Ok(out)
    }

    /// Pinned items, in the order of their pin values.
    pub fn pinned(&self) -> Result<Vec<ItemSummary>> {
        let mut stmt = self
            .conn
            .prepare_cached(&format!("SELECT {SUMMARY_COLUMNS} FROM items WHERE pin IS NOT NULL ORDER BY pin"))?;
        let rows = stmt.query_map([], summary_from_row)?;
        Ok(rows.collect::<rusqlite::Result<_>>()?)
    }

    pub fn summaries(&self, ids: &[i64]) -> Result<Vec<ItemSummary>> {
        let mut stmt = self.conn.prepare_cached(&format!("SELECT {SUMMARY_COLUMNS} FROM items WHERE id = ?1"))?;
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

    /// For thumbnails made after ingest, such as Quick Look renders of copied files.
    pub fn set_thumbnail(&mut self, id: i64, png: &[u8]) -> Result<()> {
        self.conn.execute("INSERT OR REPLACE INTO thumbnails (item_id, png) VALUES (?1, ?2)", params![id, png])?;
        Ok(())
    }

    pub fn thumbnail(&self, id: i64) -> Result<Option<Vec<u8>>> {
        Ok(self.conn.query_row("SELECT png FROM thumbnails WHERE item_id = ?1", [id], |r| r.get(0)).optional()?)
    }

    /// Raw representations for writing back to the pasteboard.
    pub fn reps(&self, id: i64) -> Result<Vec<Rep>> {
        let mut stmt = self.conn.prepare_cached("SELECT uti, data FROM reps WHERE item_id = ?1")?;
        let rows = stmt.query_map([id], |r| Ok(Rep { uti: r.get(0)?, data: r.get(1)? }))?;
        Ok(rows.collect::<rusqlite::Result<_>>()?)
    }

    /// Pins or unpins an item; a new pin goes after the existing ones (see `pin_value`).
    pub fn set_pinned(&mut self, id: i64, pinned: bool, at: i64) -> Result<()> {
        self.set_pin(id, pinned.then(|| pin_value(at)).as_deref())
    }

    /// Pins sort as strings, so values must be fixed-width. The app goes through `set_pinned`.
    pub fn set_pin(&mut self, id: i64, pin: Option<&str>) -> Result<()> {
        let changed = self.conn.execute("UPDATE items SET pin = ?2 WHERE id = ?1", params![id, pin])?;
        if changed == 0 {
            return Err(Error::NotFound(id));
        }
        self.titles.set_pin(id, pin);
        Ok(())
    }

    /// Stores text recognized in an image and makes it searchable alongside the item's own text.
    /// An empty `text` still records that recognition ran, so the image is not offered again.
    pub fn set_recognized_text(&mut self, id: i64, text: &str) -> Result<()> {
        let tx = self.conn.transaction()?;
        let own: Option<String> =
            tx.query_row("SELECT body FROM item_text WHERE item_id = ?1", [id], |r| r.get(0)).optional()?;
        let changed = tx.execute(
            "INSERT OR REPLACE INTO item_ocr (item_id, body) SELECT id, ?2 FROM items WHERE id = ?1",
            params![id, text],
        )?;
        if changed == 0 {
            return Err(Error::NotFound(id));
        }
        tx.execute("DELETE FROM item_fts WHERE rowid = ?1", [id])?;
        let body = [own.as_deref().unwrap_or(""), text]
            .iter()
            .filter(|s| !s.is_empty())
            .copied()
            .collect::<Vec<_>>()
            .join("\n");
        if !body.is_empty() {
            tx.execute("INSERT INTO item_fts (rowid, body) VALUES (?1, ?2)", params![id, body])?;
        }
        tx.commit()?;
        Ok(())
    }

    /// Everything readable in an item: its own text (file paths for files, extracted text for
    /// rich-only copies) or, for images, the text recognized in them. Empty when there is neither.
    pub fn full_text(&self, id: i64) -> Result<String> {
        let found: Option<(Option<String>, Option<String>)> = self
            .conn
            .query_row(
                "SELECT (SELECT body FROM item_text WHERE item_id = ?1), (SELECT body FROM item_ocr WHERE item_id = ?1)
                 FROM items WHERE id = ?1",
                [id],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .optional()?;
        let (own, recognized) = found.ok_or(Error::NotFound(id))?;
        Ok(own.filter(|t| !t.is_empty()).or(recognized).unwrap_or_default())
    }

    pub fn recognized_text(&self, id: i64) -> Result<Option<String>> {
        Ok(self.conn.query_row("SELECT body FROM item_ocr WHERE item_id = ?1", [id], |r| r.get(0)).optional()?)
    }

    /// Images that text recognition has not seen yet, newest first.
    pub fn unrecognized_images(&self, limit: i64) -> Result<Vec<i64>> {
        let mut stmt = self.conn.prepare_cached(
            "SELECT id FROM items WHERE kind = ?2 AND id NOT IN (SELECT item_id FROM item_ocr)
             ORDER BY last_copied_at DESC, id DESC LIMIT ?1",
        )?;
        let rows = stmt.query_map(params![limit, Kind::Image], |r| r.get(0))?;
        Ok(rows.collect::<rusqlite::Result<_>>()?)
    }

    pub fn delete(&mut self, id: i64) -> Result<()> {
        let tx = self.conn.transaction()?;
        tx.execute("DELETE FROM item_fts WHERE rowid = ?1", [id])?;
        if tx.execute("DELETE FROM items WHERE id = ?1", [id])? == 0 {
            return Err(Error::NotFound(id));
        }
        tx.commit()?;
        self.titles.remove(id);
        Ok(())
    }

    /// Keeps the newest `max_items` unpinned items.
    pub fn trim(&mut self, max_items: i64) -> Result<usize> {
        let tx = self.conn.transaction()?;
        let doomed = "SELECT id FROM items WHERE pin IS NULL
                      ORDER BY last_copied_at DESC, id DESC LIMIT -1 OFFSET ?1";
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

    /// Item counts per kind and per source app, largest first, for browsing by facet.
    pub fn facets(&self, max_apps: i64) -> Result<Facets> {
        // Ties break by name, so equal counts keep one order.
        let mut stmt = self.conn.prepare_cached("SELECT kind, count(*) FROM items GROUP BY kind ORDER BY 2 DESC, 1")?;
        let kinds = stmt.query_map([], |r| Ok(KindFacet { kind: r.get(0)?, count: r.get(1)? }))?;
        let kinds = kinds.collect::<rusqlite::Result<_>>()?;
        let mut stmt = self.conn.prepare_cached(
            "SELECT app, count(*) FROM items WHERE app IS NOT NULL GROUP BY app ORDER BY 2 DESC, 1 LIMIT ?1",
        )?;
        let apps = stmt.query_map([max_apps], |r| Ok(Facet { name: r.get(0)?, count: r.get(1)? }))?;
        Ok(Facets { kinds, apps: apps.collect::<rusqlite::Result<_>>()? })
    }

    pub fn is_empty(&self) -> bool {
        self.titles.len() == 0
    }

    pub(crate) fn conn(&self) -> &Connection {
        &self.conn
    }

    pub(crate) fn titles(&self) -> &TitleIndex {
        &self.titles
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
        char_count: r.get(8)?,
        line_count: r.get(9)?,
        first_copied_at: r.get(10)?,
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

fn classify(reps: &[Rep], text: &str) -> Kind {
    let has = |uti: &str| reps.iter().any(|r| r.uti == uti);
    if has(UTI_FILE_URL) || has(UTI_FILE_PATHS) {
        Kind::Files
    } else if IMAGE_UTIS.iter().any(|u| has(u)) && !has(UTI_TEXT) {
        Kind::Image
    } else if is_link(text) {
        Kind::Link
    } else if is_color(text) {
        Kind::Color
    } else if has(UTI_HTML) || has(UTI_RTF) {
        Kind::Rich
    } else {
        Kind::Text
    }
}

/// A CSS-style colour and nothing else: #rgb, #rrggbb, #rrggbbaa, rgb()/rgba(), hsl()/hsla().
fn is_color(text: &str) -> bool {
    let text = text.trim();
    if let Some(hex) = text.strip_prefix('#') {
        return matches!(hex.len(), 3 | 6 | 8) && hex.chars().all(|c| c.is_ascii_hexdigit());
    }
    let lower = text.to_ascii_lowercase();
    ["rgb(", "rgba(", "hsl(", "hsla("].iter().any(|p| lower.starts_with(p)) && lower.ends_with(')') && text.len() <= 40
}

/// A single web URL and nothing else.
fn is_link(text: &str) -> bool {
    let text = text.trim();
    (text.starts_with("https://") || text.starts_with("http://"))
        && text.len() > "https://".len()
        && !text.contains(char::is_whitespace)
}

fn plain_text(capture: &Capture) -> String {
    // Full paths, so search finds a file by any folder in its path.
    if let Some(paths) = find(&capture.reps, UTI_FILE_PATHS) {
        return String::from_utf8_lossy(paths).into_owned();
    }
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

fn make_title(text: &str, kind: Kind) -> String {
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

/// "a.csv" for one file, "2 files: a.csv, b.png" for more.
fn file_title(paths: &str) -> String {
    let names: Vec<&str> = paths.lines().filter(|l| !l.is_empty()).map(|p| p.rsplit('/').next().unwrap_or(p)).collect();
    let count = if names.len() > 1 { format!("{} files: ", names.len()) } else { String::new() };
    make_title(&(count + &names.join(", ")), Kind::Files)
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
        assert_eq!(row.kind, Kind::Rich);
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
        let title = make_title(&long, Kind::Text);
        assert!(title.starts_with("first second"));
        assert_eq!(title.chars().count(), TITLE_MAX_CHARS);
    }

    #[test]
    fn counts_and_link_kind_are_set_at_ingest() {
        let mut store = Store::open_in_memory().unwrap();
        store.ingest(text("한글 줄\nsecond line", 1)).unwrap();
        store.ingest(text("  https://example.com/a?b=c \n", 2)).unwrap();
        let rows = store.list(0, 10).unwrap();
        assert_eq!(rows[0].kind, Kind::Link);
        assert_eq!((rows[1].kind, rows[1].char_count, rows[1].line_count), (Kind::Text, 16, 2));
    }

    #[test]
    fn file_copies_are_titled_by_name_and_searchable_by_path() {
        let mut store = Store::open_in_memory().unwrap();
        let capture = Capture {
            reps: vec![
                Rep { uti: UTI_TEXT.into(), data: "a.csv".into() },
                Rep { uti: UTI_FILE_PATHS.into(), data: "/Users/me/Downloads/a.csv\n/Users/me/Pictures/b.png".into() },
            ],
            copied_at: 1,
            ..Default::default()
        };
        let id = store.ingest(capture).unwrap().id;
        let row = &store.list(0, 1).unwrap()[0];
        assert_eq!((row.kind, row.title.as_str(), row.line_count), (Kind::Files, "2 files: a.csv, b.png", 2));
        assert_eq!(store.search("Pictures", &crate::Filter::default(), 10).unwrap()[0].id, id);

        assert_eq!(store.thumbnail(id).unwrap(), None);
        store.set_thumbnail(id, b"png").unwrap();
        assert_eq!(store.thumbnail(id).unwrap().as_deref(), Some(&b"png"[..]));
    }

    #[test]
    fn colors_image_titles_and_facets() {
        let mut store = Store::open_in_memory().unwrap();
        for (i, t) in ["#1274DF", "rgb(18, 116, 223)", "#12", "not #fff"].iter().enumerate() {
            let mut c = text(t, i as i64);
            c.app = Some("com.apple.Terminal".into());
            store.ingest(c).unwrap();
        }
        let image = Capture {
            reps: vec![Rep { uti: "public.png".into(), data: vec![1, 2, 3] }],
            title: Some("Image 1920 × 1080".into()),
            app: Some("com.apple.Safari".into()),
            copied_at: 9,
            ..Default::default()
        };
        store.ingest(image).unwrap();
        let rows = store.list(0, 10).unwrap();
        let kinds: Vec<_> = rows.iter().map(|r| (r.title.as_str(), r.kind)).collect();
        assert_eq!(
            kinds,
            [
                ("Image 1920 × 1080", Kind::Image),
                ("not #fff", Kind::Text),
                ("#12", Kind::Text),
                ("rgb(18, 116, 223)", Kind::Color),
                ("#1274DF", Kind::Color),
            ]
        );
        assert_eq!(rows[4].first_copied_at, 0);

        let facets = store.facets(10).unwrap();
        // Equal counts break by name, so color comes before text every time.
        let kinds: Vec<_> = facets.kinds.iter().map(|f| (f.kind, f.count)).collect();
        assert_eq!(kinds, [(Kind::Color, 2), (Kind::Text, 2), (Kind::Image, 1)]);
        assert_eq!(
            facets.apps,
            [
                Facet { name: "com.apple.Terminal".into(), count: 4 },
                Facet { name: "com.apple.Safari".into(), count: 1 },
            ]
        );
    }

    #[test]
    fn full_text_prefers_own_text_and_reports_missing_items() {
        let mut store = Store::open_in_memory().unwrap();
        let id = store.ingest(text("own words", 1)).unwrap().id;
        store.set_recognized_text(id, "ignored").unwrap();
        assert_eq!(store.full_text(id).unwrap(), "own words");
        assert!(matches!(store.full_text(999), Err(Error::NotFound(999))));
    }

    #[test]
    fn writes_to_missing_items_are_not_found() {
        let mut store = Store::open_in_memory().unwrap();
        assert!(matches!(store.set_pin(7, Some("1")), Err(Error::NotFound(7))));
        assert!(matches!(store.delete(7), Err(Error::NotFound(7))));
    }

    #[test]
    fn touch_moves_item_to_front() {
        let mut store = Store::open_in_memory().unwrap();
        let first = store.ingest(text("first", 1)).unwrap().id;
        store.ingest(text("second", 2)).unwrap();
        store.touch(first, 3).unwrap();
        let rows = store.list(0, 10).unwrap();
        assert_eq!((rows[0].id, rows[0].copy_count), (first, 2));
        assert!(matches!(store.touch(999, 4), Err(Error::NotFound(999))));
    }

    #[test]
    fn migrations_upgrade_an_unversioned_database() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("old.sqlite");
        {
            let conn = Connection::open(&path).unwrap();
            conn.execute_batch(schema::SCHEMA).unwrap();
            conn.execute(
                "INSERT INTO items (content_hash, kind, title, first_copied_at, last_copied_at)
                 VALUES (x'00', 'text', 'old', 1, 1)",
                [],
            )
            .unwrap();
        }
        let store = Store::open(&path).unwrap();
        assert_eq!(store.list(0, 1).unwrap()[0].char_count, 0);
        drop(store);
        // Opening again must not re-run steps.
        Store::open(&path).unwrap();
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
        assert_eq!(titles, ["pinned", "item 10", "item 9", "item 8"]);
    }

    #[test]
    fn set_pinned_keeps_the_first_pinned_first() {
        let mut store = Store::open_in_memory().unwrap();
        let ids: Vec<i64> = (0..3).map(|i| store.ingest(text(&format!("item {i}"), i)).unwrap().id).collect();
        // Pinned 900 ms apart and then 99 s apart: string order must still follow time.
        store.set_pinned(ids[0], true, 99_000).unwrap();
        store.set_pinned(ids[2], true, 900).unwrap();
        let first: Vec<i64> = store.list(0, 2).unwrap().into_iter().map(|r| r.id).collect();
        assert_eq!(first, [ids[2], ids[0]]);
        store.set_pinned(ids[2], false, 0).unwrap();
        assert_eq!(store.list(0, 1).unwrap()[0].id, ids[0]);
        assert!(matches!(store.set_pinned(99, true, 1), Err(Error::NotFound(99))));
    }

    #[test]
    fn pinned_items_lead_every_page_in_pin_order() {
        let mut store = Store::open_in_memory().unwrap();
        let ids: Vec<i64> = (0..6).map(|i| store.ingest(text(&format!("item {i}"), i)).unwrap().id).collect();
        store.set_pin(ids[1], Some("002")).unwrap();
        store.set_pin(ids[4], Some("001")).unwrap();
        let titles = |store: &Store, offset, limit| -> Vec<String> {
            store.list(offset, limit).unwrap().into_iter().map(|r| r.title).collect()
        };
        assert_eq!(titles(&store, 0, 10), ["item 4", "item 1", "item 5", "item 3", "item 2", "item 0"]);
        // Pages split anywhere still add up to the same order.
        assert_eq!(titles(&store, 1, 2), ["item 1", "item 5"]);
        assert_eq!(titles(&store, 3, 10), ["item 3", "item 2", "item 0"]);
        store.set_pin(ids[4], None).unwrap();
        assert_eq!(titles(&store, 0, 2), ["item 1", "item 5"]);
    }

    #[test]
    fn recognized_text_is_searchable_and_marks_images_done() {
        use crate::Filter;
        let mut store = Store::open_in_memory().unwrap();
        let image = |data: u8, at| Capture {
            reps: vec![Rep { uti: "public.png".into(), data: vec![data] }],
            title: Some("Image 10 × 10".into()),
            copied_at: at,
            ..Default::default()
        };
        let a = store.ingest(image(1, 1)).unwrap().id;
        let b = store.ingest(image(2, 2)).unwrap().id;
        store.ingest(text("휴지통 비우기", 3)).unwrap();
        assert_eq!(store.unrecognized_images(10).unwrap(), [b, a]);

        store.set_recognized_text(a, "PastePal 모든 항목 휴지통").unwrap();
        store.set_recognized_text(b, "").unwrap();
        assert!(store.unrecognized_images(10).unwrap().is_empty());
        assert_eq!(store.recognized_text(a).unwrap().as_deref(), Some("PastePal 모든 항목 휴지통"));
        assert_eq!(store.full_text(a).unwrap(), "PastePal 모든 항목 휴지통");
        assert_eq!(store.full_text(b).unwrap(), "");

        let ids = |store: &mut Store, q| -> Vec<i64> {
            store.search(q, &Filter::default(), 10).unwrap().into_iter().map(|h| h.id).collect()
        };
        assert_eq!(ids(&mut store, "휴지통").len(), 2);
        let images = Filter { kinds: vec![Kind::Image], apps: vec![] };
        assert_eq!(store.search("휴지통", &images, 10).unwrap()[0].id, a);
        // Two-syllable words are too short for the index but still find the image, newest first.
        assert_eq!(ids(&mut store, "항목"), [a]);
        assert_eq!(ids(&mut store, "pastepal"), [a]);
        assert_eq!(ids(&mut store, "휴지"), [3, a]);
        // Recognizing again replaces, not appends.
        store.set_recognized_text(a, "other words").unwrap();
        assert!(ids(&mut store, "휴지통").iter().all(|&id| id != a));
        store.delete(a).unwrap();
        assert!(ids(&mut store, "other words").is_empty());
        assert!(matches!(store.set_recognized_text(a, "x"), Err(Error::NotFound(_))));
    }
}
