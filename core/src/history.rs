//! Pages visited in browsers, copied from each browser's own history so they outlive it:
//! Chromium browsers keep 90 days. One row per address per browser, with its latest visit.
//! The app reads the browsers' history files (see HistoryImport.swift) and hands rows over here.

use rusqlite::{params, params_from_iter};

use crate::{Result, Store};

/// Visits kept at most, and for at most a year; the oldest go first.
const MAX_VISITS: i64 = 100_000;
const MAX_AGE_MS: i64 = 365 * 24 * 60 * 60 * 1000;

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct Visit {
    /// The browser's bundle identifier.
    pub browser: String,
    pub url: String,
    pub title: String,
    /// Unix milliseconds.
    pub last_visit: i64,
    pub visit_count: i64,
}

impl Store {
    /// Adds or updates visits; a row keeps its latest visit, highest count and last non-empty title.
    /// Rows older than a year, or beyond the newest `MAX_VISITS`, are dropped. `now` is Unix ms.
    pub fn import_visits(&mut self, visits: &[Visit], now: i64) -> Result<()> {
        let tx = self.conn.transaction()?;
        {
            let mut upsert = tx.prepare_cached(
                "INSERT INTO history (browser, url, title, last_visit, visit_count) VALUES (?1, ?2, ?3, ?4, ?5)
                 ON CONFLICT (browser, url) DO UPDATE SET
                     title = CASE WHEN excluded.title = '' THEN title ELSE excluded.title END,
                     last_visit = max(last_visit, excluded.last_visit),
                     visit_count = max(visit_count, excluded.visit_count)",
            )?;
            for v in visits.iter().filter(|v| v.url.starts_with("https://") || v.url.starts_with("http://")) {
                upsert.execute(params![v.browser, v.url, v.title, v.last_visit, v.visit_count])?;
            }
        }
        tx.execute("DELETE FROM history WHERE last_visit < ?1", [now - MAX_AGE_MS])?;
        tx.execute(
            "DELETE FROM history WHERE id IN (
                 SELECT id FROM history ORDER BY last_visit DESC, id DESC LIMIT -1 OFFSET ?1)",
            [MAX_VISITS],
        )?;
        tx.commit()?;
        Ok(())
    }

    /// The latest visit stored for `browser`, so the next import reads only what came after. 0 when none.
    pub fn last_visit(&self, browser: &str) -> Result<i64> {
        Ok(self.conn.query_row(
            "SELECT coalesce(max(last_visit), 0) FROM history WHERE browser = ?1",
            [browser],
            |r| r.get(0),
        )?)
    }

    /// Visits whose title or address holds every word of `query`, ignoring case, latest first.
    /// A blank query finds nothing: history is for searching, not browsing.
    pub fn search_visits(&self, query: &str, limit: i64) -> Result<Vec<Visit>> {
        let words: Vec<String> =
            query.split_whitespace().map(|w| format!("%{}%", crate::tabs::escape_like(w))).collect();
        if words.is_empty() {
            return Ok(vec![]);
        }
        let mut sql = String::from("SELECT browser, url, title, last_visit, visit_count FROM history WHERE 1");
        for n in 1..=words.len() {
            sql += &format!(" AND (title LIKE ?{n} ESCAPE '\\' OR url LIKE ?{n} ESCAPE '\\')");
        }
        sql += &format!(" ORDER BY last_visit DESC, id DESC LIMIT {}", limit.max(0));
        let mut stmt = self.conn.prepare(&sql)?;
        let rows = stmt.query_map(params_from_iter(words.iter()), |r| {
            Ok(Visit {
                browser: r.get(0)?,
                url: r.get(1)?,
                title: r.get(2)?,
                last_visit: r.get(3)?,
                visit_count: r.get(4)?,
            })
        })?;
        Ok(rows.collect::<rusqlite::Result<_>>()?)
    }

    /// Removes a page from Remvel's copy of the history; the browser's own history is left alone.
    pub fn forget_visit(&mut self, browser: &str, url: &str) -> Result<()> {
        self.conn.execute("DELETE FROM history WHERE browser = ?1 AND url = ?2", params![browser, url])?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn visit(url: &str, title: &str, at: i64, count: i64) -> Visit {
        Visit {
            browser: "com.naver.Whale".into(),
            url: url.into(),
            title: title.into(),
            last_visit: at,
            visit_count: count,
        }
    }

    #[test]
    fn imports_merge_and_search_latest_first() {
        let mut store = Store::open_in_memory().unwrap();
        let day = 24 * 60 * 60 * 1000;
        let now = 400 * day;
        store
            .import_visits(
                &[
                    visit("https://map.naver.com/", "네이버 지도", now - 2 * day, 3),
                    visit("https://doc.rust-lang.org/std/", "Rust std", now - day, 1),
                    visit("chrome://settings/", "Settings", now, 1),
                    visit("https://old.example/", "Old", now - 380 * day, 1),
                ],
                now,
            )
            .unwrap();
        // A later import of an older visit keeps the latest visit and highest count.
        store.import_visits(&[visit("https://map.naver.com/", "", now - 5 * day, 2)], now).unwrap();
        let found = store.search_visits("지도", 10).unwrap();
        assert_eq!(
            (found[0].title.as_str(), found[0].last_visit, found[0].visit_count),
            ("네이버 지도", now - 2 * day, 3)
        );
        assert_eq!(
            store.search_visits("HTTPS", 10).unwrap().len(),
            2,
            "settings pages and year-old visits are dropped"
        );
        assert!(store.search_visits("", 10).unwrap().is_empty());
        assert_eq!(store.last_visit("com.naver.Whale").unwrap(), now - day);
        assert_eq!(store.last_visit("com.apple.Safari").unwrap(), 0);
        store.forget_visit("com.naver.Whale", "https://map.naver.com/").unwrap();
        assert!(store.search_visits("지도", 10).unwrap().is_empty());
    }
}
