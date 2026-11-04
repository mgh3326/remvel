use nucleo_matcher::pattern::{CaseMatching, Normalization, Pattern};
use nucleo_matcher::{Config, Matcher, Utf32String};
use rusqlite::params;

use crate::{Result, Store};

/// FTS5 trigram needs at least 3 characters to use the index.
const TRIGRAM_MIN_CHARS: usize = 3;

#[derive(Debug, Clone, Copy, PartialEq, uniffi::Enum)]
pub enum SearchMode {
    /// Case-insensitive substring over the full text.
    Exact,
    /// fzf-style ranking over titles.
    Fuzzy,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct SearchHit {
    pub id: i64,
    pub score: u32,
    /// Matched char indices in the title, for highlighting. Empty for full-text hits.
    pub title_indices: Vec<u32>,
}

struct Entry {
    id: i64,
    title: Utf32String,
    kind: Box<str>,
    app: Option<Box<str>>,
}

/// Narrows any search or listing. Empty lists mean "any".
#[derive(Debug, Clone, Default, PartialEq, uniffi::Record)]
pub struct Filter {
    pub kinds: Vec<String>,
    /// Bundle ids of the apps items were copied from.
    pub apps: Vec<String>,
}

impl Filter {
    pub fn is_empty(&self) -> bool {
        self.kinds.is_empty() && self.apps.is_empty()
    }

    fn allows(&self, e: &Entry) -> bool {
        (self.kinds.is_empty() || self.kinds.iter().any(|k| **k == *e.kind))
            && (self.apps.is_empty() || e.app.as_deref().is_some_and(|a| self.apps.iter().any(|x| x == a)))
    }
}

/// Titles kept in memory, newest first, so fuzzy search never hits SQLite.
#[derive(Default)]
pub(crate) struct TitleIndex {
    entries: Vec<Entry>,
}

impl TitleIndex {
    pub fn from_rows(rows: Vec<(i64, String, String, Option<String>)>) -> Self {
        TitleIndex { entries: rows.into_iter().map(|(id, t, k, a)| Entry::new(id, t, &k, a.as_deref())).collect() }
    }

    pub fn push_front(&mut self, id: i64, title: String, kind: &str, app: Option<&str>) {
        self.entries.insert(0, Entry::new(id, title, kind, app));
    }

    /// Moves the item to the front; a new source app replaces the old one, as in the database.
    pub fn touch(&mut self, id: i64, app: Option<&str>) {
        if let Some(pos) = self.entries.iter().position(|e| e.id == id) {
            let mut entry = self.entries.remove(pos);
            if let Some(app) = app {
                entry.app = Some(app.into());
            }
            self.entries.insert(0, entry);
        }
    }

    pub fn remove(&mut self, id: i64) {
        self.entries.retain(|e| e.id != id);
    }

    pub fn len(&self) -> usize {
        self.entries.len()
    }
}

impl Entry {
    fn new(id: i64, title: String, kind: &str, app: Option<&str>) -> Self {
        Entry { id, title: Utf32String::from(title), kind: kind.into(), app: app.map(Into::into) }
    }
}

/// A JSON array literal, so SQL can take a variable-length list as one bound parameter.
fn json_list(items: &[String]) -> String {
    let quoted: Vec<String> = items.iter().map(|k| format!("\"{}\"", k.replace(['"', '\\'], ""))).collect();
    format!("[{}]", quoted.join(","))
}

impl Store {
    /// With an empty query and a filter, lists the matching items newest first.
    pub fn search(&mut self, query: &str, mode: SearchMode, filter: &Filter, limit: usize) -> Result<Vec<SearchHit>> {
        if query.is_empty() {
            return Ok(if filter.is_empty() { Vec::new() } else { self.recent(filter, limit) });
        }
        match mode {
            SearchMode::Fuzzy => Ok(self.fuzzy(query, filter, limit)),
            SearchMode::Exact if query.chars().count() >= TRIGRAM_MIN_CHARS => self.full_text(query, filter, limit),
            SearchMode::Exact => Ok(self.title_substring(query, filter, limit)),
        }
    }

    fn recent(&mut self, filter: &Filter, limit: usize) -> Vec<SearchHit> {
        self.titles_mut()
            .entries
            .iter()
            .filter(|e| filter.allows(e))
            .take(limit)
            .map(|e| SearchHit { id: e.id, score: 0, title_indices: Vec::new() })
            .collect()
    }

    fn fuzzy(&mut self, query: &str, filter: &Filter, limit: usize) -> Vec<SearchHit> {
        let pattern = Pattern::parse(query, CaseMatching::Smart, Normalization::Smart);
        let mut matcher = Matcher::new(Config::DEFAULT);
        let mut hits: Vec<SearchHit> = self
            .titles_mut()
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
        hits.sort_by(|a, b| b.score.cmp(&a.score));
        hits.truncate(limit);
        hits
    }

    fn full_text(&self, query: &str, filter: &Filter, limit: usize) -> Result<Vec<SearchHit>> {
        let phrase = format!("\"{}\"", query.replace('"', "\"\""));
        // Lists travel as JSON arrays so the statement text, and its cache entry, never change.
        let mut stmt = self.conn().prepare_cached(
            "SELECT items.id FROM item_fts JOIN items ON items.id = item_fts.rowid
             WHERE item_fts MATCH ?1
               AND (json_array_length(?3) = 0 OR items.kind IN (SELECT value FROM json_each(?3)))
               AND (json_array_length(?4) = 0 OR items.app IN (SELECT value FROM json_each(?4)))
             ORDER BY items.last_copied_at DESC LIMIT ?2",
        )?;
        let rows = stmt.query_map(
            params![phrase, limit as i64, json_list(&filter.kinds), json_list(&filter.apps)],
            |r| r.get(0),
        )?;
        rows.map(|id| Ok(SearchHit { id: id?, score: 0, title_indices: Vec::new() })).collect()
    }

    fn title_substring(&mut self, query: &str, filter: &Filter, limit: usize) -> Vec<SearchHit> {
        let needle = query.to_lowercase();
        self.titles_mut()
            .entries
            .iter()
            .filter(|e| filter.allows(e) && e.title.to_string().to_lowercase().contains(&needle))
            .take(limit)
            .map(|e| SearchHit { id: e.id, score: 0, title_indices: Vec::new() })
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{Capture, Rep};

    fn store_with(texts: &[&str]) -> Store {
        let mut store = Store::open_in_memory().unwrap();
        for (i, t) in texts.iter().enumerate() {
            store
                .ingest(Capture {
                    reps: vec![Rep { uti: "public.utf8-plain-text".into(), data: t.as_bytes().to_vec() }],
                    copied_at: i as i64,
                    ..Default::default()
                })
                .unwrap();
        }
        store
    }

    #[test]
    fn exact_search_finds_text_beyond_the_title() {
        let tail = format!("{}needle-here", "x ".repeat(2_000));
        let mut store = store_with(&["alpha", &tail, "한국어 클립보드 검색"]);
        let hits = store.search("needle-here", SearchMode::Exact, &Filter::default(), 10).unwrap();
        assert_eq!(hits.len(), 1);
        let hits = store.search("클립보드", SearchMode::Exact, &Filter::default(), 10).unwrap();
        assert_eq!(hits.len(), 1);
        let hits = store.search("al", SearchMode::Exact, &Filter::default(), 10).unwrap();
        assert_eq!(hits.len(), 1);
    }

    #[test]
    fn fuzzy_ranks_and_reports_indices() {
        let mut store = store_with(&["git commit --amend", "grep -r foo", "cargo build"]);
        let hits = store.search("gca", SearchMode::Fuzzy, &Filter::default(), 10).unwrap();
        let top = store.summaries(&[hits[0].id]).unwrap().remove(0);
        assert_eq!(top.title, "git commit --amend");
        assert!(!hits[0].title_indices.is_empty());
    }

    #[test]
    fn deleted_items_leave_both_indexes() {
        let mut store = store_with(&["remove me please"]);
        let id = store.list(0, 1).unwrap()[0].id;
        store.delete(id).unwrap();
        assert!(store.search("remove", SearchMode::Exact, &Filter::default(), 10).unwrap().is_empty());
        assert!(store.search("rmp", SearchMode::Fuzzy, &Filter::default(), 10).unwrap().is_empty());
    }

    #[test]
    fn kind_filter_applies_to_every_path() {
        let mut store = store_with(&["https://example.com/docs", "docs folder notes", "another link https://x.y"]);
        let links = Filter { kinds: vec!["link".into()], apps: vec![] };
        let only = |hits: Vec<SearchHit>| hits.len();
        assert_eq!(only(store.search("", SearchMode::Exact, &links, 10).unwrap()), 1);
        assert_eq!(only(store.search("docs", SearchMode::Exact, &links, 10).unwrap()), 1);
        assert_eq!(only(store.search("docs", SearchMode::Exact, &Filter::default(), 10).unwrap()), 2);
        assert_eq!(only(store.search("dcs", SearchMode::Fuzzy, &links, 10).unwrap()), 1);
        assert_eq!(only(store.search("do", SearchMode::Exact, &links, 10).unwrap()), 1);
        assert!(store.search("", SearchMode::Fuzzy, &Filter::default(), 10).unwrap().is_empty());
    }

    #[test]
    fn app_filter_follows_the_latest_source_app() {
        let mut store = Store::open_in_memory().unwrap();
        let capture = |text: &str, app: &str, at| Capture {
            reps: vec![Rep { uti: "public.utf8-plain-text".into(), data: text.as_bytes().to_vec() }],
            app: Some(app.into()),
            copied_at: at,
            ..Default::default()
        };
        store.ingest(capture("deploy notes", "com.tinyspeck.slackmacgap", 1)).unwrap();
        store.ingest(capture("deploy script", "com.apple.Terminal", 2)).unwrap();
        let slack = Filter { kinds: vec![], apps: vec!["com.tinyspeck.slackmacgap".into()] };
        let ids = |hits: Vec<SearchHit>| hits.into_iter().map(|h| h.id).collect::<Vec<_>>();
        assert_eq!(ids(store.search("", SearchMode::Exact, &slack, 10).unwrap()), [1]);
        assert_eq!(ids(store.search("deploy", SearchMode::Exact, &slack, 10).unwrap()), [1]);
        assert_eq!(ids(store.search("dpl", SearchMode::Fuzzy, &slack, 10).unwrap()), [1]);
        // Copying it again from Terminal moves it to Terminal.
        store.ingest(capture("deploy notes", "com.apple.Terminal", 3)).unwrap();
        assert!(store.search("", SearchMode::Exact, &slack, 10).unwrap().is_empty());
    }
}
