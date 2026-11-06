//! Browser tabs Remvel has seen, so a tab closed in the browser can still be found and opened again.
//!
//! The app reads a browser's tabs when the user leaves it and when the tab switcher opens, and hands
//! over the whole list each time: a tab missing from a later list was closed by then. Only web and
//! file addresses are kept; a browser's own pages (new tab, settings) say nothing worth finding.

use rusqlite::{OptionalExtension, params, params_from_iter};

use crate::{Result, Store};

/// Closed tabs kept at most; the oldest go first.
const MAX_CLOSED: i64 = 20_000;
/// Closed tabs are kept for a year, as visits are (history.rs).
const MAX_CLOSED_AGE_MS: i64 = 365 * 24 * 60 * 60 * 1000;
/// Page text kept per tab, in characters.
const MAX_TEXT_CHARS: usize = 100_000;

/// One open tab as the browser reports it.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct TabSeen {
    pub url: String,
    pub title: String,
}

/// An open tab, by the browser's bundle identifier and the tab's address.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct TabKey {
    pub browser: String,
    pub url: String,
}

/// A tab that is no longer open, newest closed first.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct ClosedTab {
    /// The browser's bundle identifier.
    pub browser: String,
    pub url: String,
    pub title: String,
    pub last_seen: i64,
    pub closed_at: i64,
}

fn worth_keeping(url: &str) -> bool {
    ["https://", "http://", "file://"].iter().any(|p| url.starts_with(p))
}

impl Store {
    /// Every tab `browser` has open now. Tabs of it seen before and missing here are closed at `at`.
    pub fn record_tabs(&mut self, browser: &str, tabs: &[TabSeen], at: i64) -> Result<()> {
        let tx = self.conn.transaction()?;
        {
            let mut upsert = tx.prepare_cached(
                "INSERT INTO tabs (browser, url, title, first_seen, last_seen) VALUES (?1, ?2, ?3, ?4, ?4)
                 ON CONFLICT (browser, url) DO UPDATE SET
                     title = CASE WHEN excluded.title = '' THEN title ELSE excluded.title END,
                     last_seen = excluded.last_seen,
                     closed_at = NULL",
            )?;
            for tab in tabs.iter().filter(|t| worth_keeping(&t.url)) {
                upsert.execute(params![browser, tab.url, tab.title, at])?;
            }
        }
        tx.execute(
            "UPDATE tabs SET closed_at = ?2 WHERE browser = ?1 AND closed_at IS NULL AND last_seen < ?2",
            params![browser, at],
        )?;
        tx.execute(
            "DELETE FROM tabs WHERE id IN (
                 SELECT id FROM tabs WHERE closed_at IS NOT NULL ORDER BY closed_at DESC, id DESC LIMIT -1 OFFSET ?1)",
            [MAX_CLOSED],
        )?;
        tx.execute("DELETE FROM tabs WHERE closed_at < ?1", [at - MAX_CLOSED_AGE_MS])?;
        tx.commit()?;
        Ok(())
    }

    /// For a tab closed from Remvel: it is closed now, without waiting for the next read.
    pub fn tab_closed(&mut self, browser: &str, url: &str, at: i64) -> Result<()> {
        self.conn.execute(
            "UPDATE tabs SET closed_at = ?3 WHERE browser = ?1 AND url = ?2 AND closed_at IS NULL",
            params![browser, url, at],
        )?;
        Ok(())
    }

    /// Removes a tab from memory, open or closed.
    pub fn forget_tab(&mut self, browser: &str, url: &str) -> Result<()> {
        self.conn.execute("DELETE FROM tabs WHERE browser = ?1 AND url = ?2", params![browser, url])?;
        Ok(())
    }

    /// The text of a tab's page, so searches find what it said. Ignored for tabs not recorded.
    pub fn set_tab_text(&mut self, browser: &str, url: &str, text: &str) -> Result<()> {
        let text: String = text.chars().take(MAX_TEXT_CHARS).collect();
        self.conn.execute("UPDATE tabs SET text = ?3 WHERE browser = ?1 AND url = ?2", params![browser, url, text])?;
        Ok(())
    }

    pub fn tab_text(&self, browser: &str, url: &str) -> Result<Option<String>> {
        Ok(self
            .conn
            .query_row("SELECT text FROM tabs WHERE browser = ?1 AND url = ?2", params![browser, url], |r| r.get(0))
            .optional()?
            .flatten())
    }

    /// Closed tabs whose title, address or page text holds every word of `query`, ignoring case;
    /// a blank query lists them all. Newest closed first.
    pub fn closed_tabs(&self, query: &str, limit: i64) -> Result<Vec<ClosedTab>> {
        let words: Vec<String> = query.split_whitespace().map(|w| format!("%{}%", escape_like(w))).collect();
        let mut sql =
            String::from("SELECT browser, url, title, last_seen, closed_at FROM tabs WHERE closed_at IS NOT NULL");
        for i in 0..words.len() {
            let n = i + 1;
            sql += &format!(
                " AND (title LIKE ?{n} ESCAPE '\\' OR url LIKE ?{n} ESCAPE '\\' OR text LIKE ?{n} ESCAPE '\\')"
            );
        }
        sql += &format!(" ORDER BY closed_at DESC, id DESC LIMIT {}", limit.max(0));
        let mut stmt = self.conn.prepare(&sql)?;
        let rows = stmt.query_map(params_from_iter(words.iter()), |r| {
            Ok(ClosedTab {
                browser: r.get(0)?,
                url: r.get(1)?,
                title: r.get(2)?,
                last_seen: r.get(3)?,
                closed_at: r.get(4)?,
            })
        })?;
        Ok(rows.collect::<rusqlite::Result<_>>()?)
    }
}

impl Store {
    /// Open tabs whose kept page text holds every word of `query`, ignoring case. The app matches
    /// titles and addresses itself; this finds the tabs only their page mentions.
    pub fn open_tabs_with_text(&self, query: &str, limit: i64) -> Result<Vec<TabKey>> {
        let words: Vec<String> = query.split_whitespace().map(|w| format!("%{}%", escape_like(w))).collect();
        if words.is_empty() {
            return Ok(vec![]);
        }
        let mut sql = String::from("SELECT browser, url FROM tabs WHERE closed_at IS NULL AND text IS NOT NULL");
        for n in 1..=words.len() {
            sql += &format!(" AND text LIKE ?{n} ESCAPE '\\'");
        }
        sql += &format!(" ORDER BY last_seen DESC, id DESC LIMIT {}", limit.max(0));
        let mut stmt = self.conn.prepare(&sql)?;
        let rows =
            stmt.query_map(params_from_iter(words.iter()), |r| Ok(TabKey { browser: r.get(0)?, url: r.get(1)? }))?;
        Ok(rows.collect::<rusqlite::Result<_>>()?)
    }
}

pub(crate) fn escape_like(word: &str) -> String {
    word.replace('\\', "\\\\").replace('%', "\\%").replace('_', "\\_")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tab(url: &str, title: &str) -> TabSeen {
        TabSeen { url: url.into(), title: title.into() }
    }

    fn closed(store: &Store, query: &str) -> Vec<(String, i64)> {
        store.closed_tabs(query, 100).unwrap().into_iter().map(|t| (t.title, t.closed_at)).collect()
    }

    #[test]
    fn a_tab_missing_from_the_next_read_is_closed_then() {
        let mut store = Store::open_in_memory().unwrap();
        let edge = "com.microsoft.edgemac";
        store
            .record_tabs(
                edge,
                &[tab("https://a.example/", "A"), tab("https://b.example/", "B"), tab("edge://newtab/", "New")],
                10,
            )
            .unwrap();
        assert!(closed(&store, "").is_empty());
        store.record_tabs(edge, &[tab("https://a.example/", "A")], 20).unwrap();
        assert_eq!(closed(&store, ""), [("B".to_string(), 20)]);
        // Another browser's read leaves this one's tabs alone.
        store.record_tabs("com.apple.Safari", &[], 30).unwrap();
        assert_eq!(closed(&store, "").len(), 1);
        // Opened again: no longer closed. Closed again later: the later time counts.
        store.record_tabs(edge, &[tab("https://a.example/", "A"), tab("https://b.example/", "")], 40).unwrap();
        assert!(closed(&store, "").is_empty());
        store.record_tabs(edge, &[], 50).unwrap();
        // An empty title from a loading tab keeps the one seen before.
        assert_eq!(closed(&store, ""), [("B".to_string(), 50), ("A".to_string(), 50)]);
    }

    #[test]
    fn closed_tabs_match_title_address_and_page_text() {
        let mut store = Store::open_in_memory().unwrap();
        let safari = "com.apple.Safari";
        store
            .record_tabs(
                safari,
                &[tab("https://shop.example/cart", "장바구니"), tab("https://docs.example/100%_done", "Docs")],
                1,
            )
            .unwrap();
        store.set_tab_text(safari, "https://docs.example/100%_done", "Release checklist for Remvel").unwrap();
        store.record_tabs(safari, &[], 2).unwrap();
        store.tab_closed(safari, "https://shop.example/cart", 3).unwrap();
        assert_eq!(closed(&store, "장바구니").len(), 1);
        assert_eq!(closed(&store, "SHOP cart").len(), 1);
        assert_eq!(closed(&store, "remvel checklist")[0].0, "Docs");
        assert_eq!(closed(&store, "100%_").len(), 1);
        assert!(closed(&store, "100%x").is_empty());
        // Open tabs are found by their page text alone; titles and addresses are the app's to match.
        store.record_tabs(safari, &[tab("https://docs.example/100%_done", "Docs")], 4).unwrap();
        let keys = store.open_tabs_with_text("CHECKLIST", 10).unwrap();
        assert_eq!(keys, [TabKey { browser: safari.into(), url: "https://docs.example/100%_done".into() }]);
        assert!(store.open_tabs_with_text("docs", 10).unwrap().is_empty());
        assert!(store.open_tabs_with_text("", 10).unwrap().is_empty());
        store.forget_tab(safari, "https://shop.example/cart").unwrap();
        assert!(closed(&store, "장바구니").is_empty());
    }
}
