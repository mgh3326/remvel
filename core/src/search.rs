//! Search and browse order.
//!
//! Every view of the history is ordered here, so the popup, Shortcuts and tests all agree:
//!
//! - **Browsing** (no search text, with or without a filter): pinned items first in pin order,
//!   then the rest newest first. `Store::list` pages through the same order.
//! - **Searching** (search text): no pin priority. Fuzzy title matches by score, then text matches
//!   that fuzzy missed. Within equal scores, and among text matches, newest first.
//!
//! "Newest first" always means `last_copied_at DESC, id DESC`, in SQL and in memory, so items
//! copied in the same millisecond keep one order everywhere.

use std::collections::HashSet;

use nucleo_matcher::pattern::{CaseMatching, Normalization, Pattern};
use nucleo_matcher::{Config, Matcher, Utf32String};
use rusqlite::params;

use crate::{Kind, Result, Store};

/// FTS5 trigram needs at least 3 characters to use the index.
const TRIGRAM_MIN_CHARS: usize = 3;

/// One matching strategy on its own. Apps call `Store::search`, which combines them;
/// this exists for benchmarks and tests.
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum SearchMode {
    /// Case-insensitive substring over the full text and recognized image text.
    /// Queries shorter than 3 characters match titles and recognized image text only.
    Exact,
    /// fzf-style ranking over titles.
    Fuzzy,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct SearchHit {
    pub id: i64,
    /// Fuzzy score; 0 for browse results and text matches.
    pub score: u32,
    /// Matched char indices in the title, for highlighting. Empty unless the title matched fuzzily.
    pub title_indices: Vec<u32>,
}

/// Narrows any search or listing. Empty lists mean "any".
#[derive(Debug, Clone, Default, PartialEq, uniffi::Record)]
pub struct Filter {
    pub kinds: Vec<Kind>,
    /// Bundle ids of the apps items were copied from.
    pub apps: Vec<String>,
}

impl Filter {
    pub fn is_empty(&self) -> bool {
        self.kinds.is_empty() && self.apps.is_empty()
    }

    fn allows(&self, e: &Entry) -> bool {
        (self.kinds.is_empty() || self.kinds.contains(&e.kind))
            && (self.apps.is_empty() || e.app.as_deref().is_some_and(|a| self.apps.iter().any(|x| x == a)))
    }
}

/// What the in-memory index keeps per item: enough to filter, rank and order without SQLite.
pub(crate) struct Entry {
    id: i64,
    title: Utf32String,
    kind: Kind,
    app: Option<Box<str>>,
    last_copied_at: i64,
    pin: Option<Box<str>>,
}

impl Entry {
    pub fn new(id: i64, title: String, kind: Kind, app: Option<&str>, last_copied_at: i64, pin: Option<&str>) -> Self {
        Entry {
            id,
            title: Utf32String::from(title),
            kind,
            app: app.map(Into::into),
            last_copied_at,
            pin: pin.map(Into::into),
        }
    }

    /// Larger is newer. Matches SQL's `ORDER BY last_copied_at DESC, id DESC`.
    fn recency(&self) -> (i64, i64) {
        (self.last_copied_at, self.id)
    }

    fn hit(&self) -> SearchHit {
        SearchHit { id: self.id, score: 0, title_indices: Vec::new() }
    }
}

/// Titles kept in memory, newest first, so browsing and fuzzy search never hit SQLite.
/// Mirrors the `items` columns it holds; every write to those columns updates both.
#[derive(Default)]
pub(crate) struct TitleIndex {
    entries: Vec<Entry>,
}

impl TitleIndex {
    pub fn from_entries(mut entries: Vec<Entry>) -> Self {
        entries.sort_by_key(|e| std::cmp::Reverse(e.recency()));
        TitleIndex { entries }
    }

    pub fn insert(&mut self, entry: Entry) {
        let key = entry.recency();
        let at = self.entries.partition_point(|e| e.recency() > key);
        self.entries.insert(at, entry);
    }

    /// A new copy time; a new source app replaces the old one, as in the database.
    pub fn touch(&mut self, id: i64, at: i64, app: Option<&str>) {
        if let Some(mut entry) = self.take(id) {
            entry.last_copied_at = at;
            if let Some(app) = app {
                entry.app = Some(app.into());
            }
            self.insert(entry);
        }
    }

    pub fn set_pin(&mut self, id: i64, pin: Option<&str>) {
        if let Some(entry) = self.entries.iter_mut().find(|e| e.id == id) {
            entry.pin = pin.map(Into::into);
        }
    }

    pub fn remove(&mut self, id: i64) {
        self.take(id);
    }

    pub fn len(&self) -> usize {
        self.entries.len()
    }

    fn take(&mut self, id: i64) -> Option<Entry> {
        let pos = self.entries.iter().position(|e| e.id == id)?;
        Some(self.entries.remove(pos))
    }

    /// Browse order: pinned items in pin order, then the rest newest first.
    fn browse(&self, filter: &Filter, limit: usize) -> Vec<SearchHit> {
        let mut pinned: Vec<&Entry> = self.entries.iter().filter(|e| e.pin.is_some() && filter.allows(e)).collect();
        pinned.sort_by(|a, b| a.pin.cmp(&b.pin));
        let unpinned = self.entries.iter().filter(|e| e.pin.is_none() && filter.allows(e));
        pinned.into_iter().chain(unpinned).take(limit).map(Entry::hit).collect()
    }

    /// Best score first; equal scores stay newest first.
    fn fuzzy(&self, query: &str, filter: &Filter, limit: usize) -> Vec<SearchHit> {
        let pattern = Pattern::parse(query, CaseMatching::Smart, Normalization::Smart);
        let mut matcher = Matcher::new(Config::DEFAULT);
        let mut hits: Vec<SearchHit> = self
            .entries
            .iter()
            .filter(|e| filter.allows(e))
            .filter_map(|e| {
                let mut indices = Vec::new();
                let score = pattern.indices(e.title.slice(..), &mut matcher, &mut indices)?;
                indices.sort_unstable();
                indices.dedup();
                Some(SearchHit { id: e.id, score, title_indices: indices })
            })
            .collect();
        // Stable sort keeps recency order among equal scores.
        hits.sort_by_key(|h| std::cmp::Reverse(h.score));
        hits.truncate(limit);
        hits
    }

    /// Newest first.
    /// Newest first: titles containing `query`, plus the items in `also`.
    fn title_substring(&self, query: &str, also: &HashSet<i64>, filter: &Filter, limit: usize) -> Vec<SearchHit> {
        let needle = query.to_lowercase();
        self.entries
            .iter()
            .filter(|e| {
                filter.allows(e) && (also.contains(&e.id) || e.title.to_string().to_lowercase().contains(&needle))
            })
            .take(limit)
            .map(Entry::hit)
            .collect()
    }
}

/// A JSON array literal, so SQL can take a variable-length list as one bound parameter.
fn json_list<S: AsRef<str>>(items: &[S]) -> String {
    let quoted: Vec<String> = items.iter().map(|k| format!("\"{}\"", k.as_ref().replace(['"', '\\'], ""))).collect();
    format!("[{}]", quoted.join(","))
}

impl Store {
    /// The one entry point for what a history view shows; see the module docs for the order.
    /// Blank `query` browses the items `filter` allows (all items when it is empty).
    pub fn search(&self, query: &str, filter: &Filter, limit: usize) -> Result<Vec<SearchHit>> {
        let query = query.trim();
        if query.is_empty() {
            return Ok(self.titles().browse(filter, limit));
        }
        let mut hits = self.search_by(query, SearchMode::Fuzzy, filter, limit)?;
        let seen: HashSet<i64> = hits.iter().map(|h| h.id).collect();
        hits.extend(
            self.search_by(query, SearchMode::Exact, filter, limit)?.into_iter().filter(|h| !seen.contains(&h.id)),
        );
        hits.truncate(limit);
        Ok(hits)
    }

    /// One strategy alone. Apps use `search`.
    pub fn search_by(&self, query: &str, mode: SearchMode, filter: &Filter, limit: usize) -> Result<Vec<SearchHit>> {
        match mode {
            SearchMode::Fuzzy => Ok(self.titles().fuzzy(query, filter, limit)),
            SearchMode::Exact if query.chars().count() >= TRIGRAM_MIN_CHARS => self.match_text(query, filter, limit),
            SearchMode::Exact => {
                // Too short for the index. Text in images has no title to fall back on, and Korean
                // words are often two syllables, so their recognized text is scanned instead;
                // it is small next to the history's text.
                let in_images = self.recognized_text_containing(query)?;
                Ok(self.titles().title_substring(query, &in_images, filter, limit))
            }
        }
    }

    fn recognized_text_containing(&self, query: &str) -> Result<HashSet<i64>> {
        let mut stmt =
            self.conn().prepare_cached("SELECT item_id FROM item_ocr WHERE instr(lower(body), lower(?1)) > 0")?;
        let ids = stmt.query_map([query], |r| r.get(0))?;
        Ok(ids.collect::<rusqlite::Result<_>>()?)
    }

    /// Newest first.
    fn match_text(&self, query: &str, filter: &Filter, limit: usize) -> Result<Vec<SearchHit>> {
        let phrase = format!("\"{}\"", query.replace('"', "\"\""));
        // Lists travel as JSON arrays so the statement text, and its cache entry, never change.
        let mut stmt = self.conn().prepare_cached(
            "SELECT items.id FROM item_fts JOIN items ON items.id = item_fts.rowid
             WHERE item_fts MATCH ?1
               AND (json_array_length(?3) = 0 OR items.kind IN (SELECT value FROM json_each(?3)))
               AND (json_array_length(?4) = 0 OR items.app IN (SELECT value FROM json_each(?4)))
             ORDER BY items.last_copied_at DESC, items.id DESC LIMIT ?2",
        )?;
        let rows = stmt.query_map(
            params![
                phrase,
                limit as i64,
                json_list(&filter.kinds.iter().map(|k| k.as_str()).collect::<Vec<_>>()),
                json_list(&filter.apps)
            ],
            |r| r.get(0),
        )?;
        rows.map(|id| Ok(SearchHit { id: id?, score: 0, title_indices: Vec::new() })).collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{Capture, Rep};

    fn capture(text: &str, at: i64) -> Capture {
        Capture {
            reps: vec![Rep { uti: "public.utf8-plain-text".into(), data: text.as_bytes().to_vec() }],
            copied_at: at,
            ..Default::default()
        }
    }

    fn store_with(texts: &[&str]) -> Store {
        let mut store = Store::open_in_memory().unwrap();
        for (i, t) in texts.iter().enumerate() {
            store.ingest(capture(t, i as i64)).unwrap();
        }
        store
    }

    fn ids(hits: Vec<SearchHit>) -> Vec<i64> {
        hits.into_iter().map(|h| h.id).collect()
    }

    fn list_ids(store: &Store) -> Vec<i64> {
        store.list(0, 1000).unwrap().into_iter().map(|r| r.id).collect()
    }

    #[test]
    fn exact_search_finds_text_beyond_the_title() {
        let tail = format!("{}needle-here", "x ".repeat(2_000));
        let store = store_with(&["alpha", &tail, "한국어 클립보드 검색"]);
        let any = Filter::default();
        assert_eq!(store.search_by("needle-here", SearchMode::Exact, &any, 10).unwrap().len(), 1);
        assert_eq!(store.search_by("클립보드", SearchMode::Exact, &any, 10).unwrap().len(), 1);
        assert_eq!(store.search_by("al", SearchMode::Exact, &any, 10).unwrap().len(), 1);
        // The combined search finds it too, though the fuzzy title pass cannot.
        assert_eq!(store.search("needle-here", &any, 10).unwrap().len(), 1);
    }

    #[test]
    fn fuzzy_ranks_and_reports_indices() {
        let store = store_with(&["git commit --amend", "grep -r foo", "cargo build"]);
        let hits = store.search("gca", &Filter::default(), 10).unwrap();
        let top = store.summaries(&[hits[0].id]).unwrap().remove(0);
        assert_eq!(top.title, "git commit --amend");
        assert!(!hits[0].title_indices.is_empty());
    }

    #[test]
    fn search_ranks_fuzzy_by_score_then_text_matches_newest_first() {
        // "deploy" fuzzily matches the first two titles; the third has it only beyond the title.
        let hidden = format!("{} deploy", "x".repeat(400));
        let store = store_with(&["deploy", "d e p l o y spread", &hidden, "unrelated"]);
        let hits = store.search("deploy", &Filter::default(), 10).unwrap();
        assert_eq!(ids(hits.clone()), [1, 2, 3]);
        assert!(hits[0].score > hits[1].score);
        assert_eq!(hits[2].score, 0);
    }

    #[test]
    fn search_ignores_pins_but_browse_puts_them_first() {
        let mut store = store_with(&["deploy old", "deploy new", "other"]);
        store.set_pin(1, Some("001")).unwrap();
        // Searching: equal scores, newest first; the pin does not lift item 1.
        assert_eq!(ids(store.search("deploy", &Filter::default(), 10).unwrap()), [2, 1]);
        // Browsing, filtered or not: the pin leads, as in `list`.
        assert_eq!(ids(store.search("", &Filter::default(), 10).unwrap()), [1, 3, 2]);
        assert_eq!(ids(store.search("  ", &Filter { kinds: vec![Kind::Text], apps: vec![] }, 10).unwrap()), [1, 3, 2]);
        assert_eq!(list_ids(&store), [1, 3, 2]);
    }

    #[test]
    fn browse_matches_list_when_copies_share_a_millisecond() {
        let mut store = Store::open_in_memory().unwrap();
        for (i, t) in ["a", "b", "c", "d"].iter().enumerate() {
            store.ingest(capture(t, (i / 2) as i64)).unwrap();
        }
        // Pasting a queue touches several items with the same time.
        store.touch(1, 5).unwrap();
        store.touch(3, 5).unwrap();
        store.touch(2, 5).unwrap();
        let expected = vec![3, 2, 1, 4];
        assert_eq!(list_ids(&store), expected);
        assert_eq!(ids(store.search("", &Filter::default(), 10).unwrap()), expected);
        // Text matches with equal rank follow the same order.
        assert_eq!(ids(store.search_by("", SearchMode::Exact, &Filter::default(), 10).unwrap()), expected);
    }

    #[test]
    fn order_survives_reopening() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("db.sqlite");
        let before = {
            let mut store = Store::open(&path).unwrap();
            for (i, t) in ["a", "b", "c", "d", "e"].iter().enumerate() {
                store.ingest(capture(t, (i % 2) as i64)).unwrap();
            }
            store.touch(1, 9).unwrap();
            store.touch(4, 9).unwrap();
            store.set_pin(5, Some("001")).unwrap();
            ids(store.search("", &Filter::default(), 10).unwrap())
        };
        let store = Store::open(&path).unwrap();
        assert_eq!(ids(store.search("", &Filter::default(), 10).unwrap()), before);
        assert_eq!(list_ids(&store), before);
        assert_eq!(before, [5, 4, 1, 2, 3]);
    }

    #[test]
    fn deleted_items_leave_both_indexes() {
        let mut store = store_with(&["remove me please"]);
        let id = store.list(0, 1).unwrap()[0].id;
        store.delete(id).unwrap();
        assert!(store.search_by("remove", SearchMode::Exact, &Filter::default(), 10).unwrap().is_empty());
        assert!(store.search_by("rmp", SearchMode::Fuzzy, &Filter::default(), 10).unwrap().is_empty());
    }

    #[test]
    fn kind_filter_applies_to_every_path() {
        let store = store_with(&["https://example.com/docs", "docs folder notes", "another link https://x.y"]);
        let links = Filter { kinds: vec![Kind::Link], apps: vec![] };
        let count = |hits: Result<Vec<SearchHit>>| hits.unwrap().len();
        assert_eq!(count(store.search("", &links, 10)), 1);
        assert_eq!(count(store.search("docs", &links, 10)), 1);
        assert_eq!(count(store.search_by("docs", SearchMode::Exact, &Filter::default(), 10)), 2);
        assert_eq!(count(store.search_by("dcs", SearchMode::Fuzzy, &links, 10)), 1);
        assert_eq!(count(store.search_by("do", SearchMode::Exact, &links, 10)), 1);
    }

    #[test]
    fn app_filter_follows_the_latest_source_app() {
        let mut store = Store::open_in_memory().unwrap();
        let capture = |text: &str, app: &str, at| Capture { app: Some(app.into()), ..capture(text, at) };
        store.ingest(capture("deploy notes", "com.tinyspeck.slackmacgap", 1)).unwrap();
        store.ingest(capture("deploy script", "com.apple.Terminal", 2)).unwrap();
        let slack = Filter { kinds: vec![], apps: vec!["com.tinyspeck.slackmacgap".into()] };
        assert_eq!(ids(store.search("", &slack, 10).unwrap()), [1]);
        assert_eq!(ids(store.search("deploy", &slack, 10).unwrap()), [1]);
        assert_eq!(ids(store.search_by("dpl", SearchMode::Fuzzy, &slack, 10).unwrap()), [1]);
        // Copying it again from Terminal moves it to Terminal.
        store.ingest(capture("deploy notes", "com.apple.Terminal", 3)).unwrap();
        assert!(store.search("", &slack, 10).unwrap().is_empty());
    }
}
