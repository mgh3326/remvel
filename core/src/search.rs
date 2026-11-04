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

/// Titles kept in memory, newest first, so fuzzy search never hits SQLite.
#[derive(Default)]
pub(crate) struct TitleIndex {
    entries: Vec<(i64, Utf32String)>,
}

impl TitleIndex {
    pub fn from_rows(rows: Vec<(i64, String)>) -> Self {
        TitleIndex { entries: rows.into_iter().map(|(id, t)| (id, Utf32String::from(t))).collect() }
    }

    pub fn push_front(&mut self, id: i64, title: String) {
        self.entries.insert(0, (id, Utf32String::from(title)));
    }

    pub fn touch(&mut self, id: i64) {
        if let Some(pos) = self.entries.iter().position(|(e, _)| *e == id) {
            let entry = self.entries.remove(pos);
            self.entries.insert(0, entry);
        }
    }

    pub fn remove(&mut self, id: i64) {
        self.entries.retain(|(e, _)| *e != id);
    }

    pub fn len(&self) -> usize {
        self.entries.len()
    }
}

impl Store {
    pub fn search(&mut self, query: &str, mode: SearchMode, limit: usize) -> Result<Vec<SearchHit>> {
        if query.is_empty() {
            return Ok(Vec::new());
        }
        match mode {
            SearchMode::Fuzzy => Ok(self.fuzzy(query, limit)),
            SearchMode::Exact if query.chars().count() >= TRIGRAM_MIN_CHARS => self.full_text(query, limit),
            SearchMode::Exact => Ok(self.title_substring(query, limit)),
        }
    }

    fn fuzzy(&mut self, query: &str, limit: usize) -> Vec<SearchHit> {
        let pattern = Pattern::parse(query, CaseMatching::Smart, Normalization::Smart);
        let mut matcher = Matcher::new(Config::DEFAULT);
        let mut hits: Vec<SearchHit> = self
            .titles_mut()
            .entries
            .iter()
            .filter_map(|(id, title)| {
                let mut indices = Vec::new();
                let score = pattern.indices(title.slice(..), &mut matcher, &mut indices)?;
                indices.sort_unstable();
                indices.dedup();
                Some(SearchHit { id: *id, score, title_indices: indices })
            })
            .collect();
        // Stable sort keeps recency order among equal scores.
        hits.sort_by(|a, b| b.score.cmp(&a.score));
        hits.truncate(limit);
        hits
    }

    fn full_text(&self, query: &str, limit: usize) -> Result<Vec<SearchHit>> {
        let phrase = format!("\"{}\"", query.replace('"', "\"\""));
        let mut stmt = self.conn().prepare_cached(
            "SELECT items.id FROM item_fts JOIN items ON items.id = item_fts.rowid
             WHERE item_fts MATCH ?1 ORDER BY items.last_copied_at DESC LIMIT ?2",
        )?;
        let rows = stmt.query_map(params![phrase, limit as i64], |r| r.get(0))?;
        rows.map(|id| Ok(SearchHit { id: id?, score: 0, title_indices: Vec::new() })).collect()
    }

    fn title_substring(&mut self, query: &str, limit: usize) -> Vec<SearchHit> {
        let needle = query.to_lowercase();
        self.titles_mut()
            .entries
            .iter()
            .filter(|(_, t)| t.to_string().to_lowercase().contains(&needle))
            .take(limit)
            .map(|(id, _)| SearchHit { id: *id, score: 0, title_indices: Vec::new() })
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
        let hits = store.search("needle-here", SearchMode::Exact, 10).unwrap();
        assert_eq!(hits.len(), 1);
        let hits = store.search("클립보드", SearchMode::Exact, 10).unwrap();
        assert_eq!(hits.len(), 1);
        let hits = store.search("al", SearchMode::Exact, 10).unwrap();
        assert_eq!(hits.len(), 1);
    }

    #[test]
    fn fuzzy_ranks_and_reports_indices() {
        let mut store = store_with(&["git commit --amend", "grep -r foo", "cargo build"]);
        let hits = store.search("gca", SearchMode::Fuzzy, 10).unwrap();
        let top = store.summaries(&[hits[0].id]).unwrap().remove(0);
        assert_eq!(top.title, "git commit --amend");
        assert!(!hits[0].title_indices.is_empty());
    }

    #[test]
    fn deleted_items_leave_both_indexes() {
        let mut store = store_with(&["remove me please"]);
        let id = store.list(0, 1).unwrap()[0].id;
        store.delete(id).unwrap();
        assert!(store.search("remove", SearchMode::Exact, 10).unwrap().is_empty());
        assert!(store.search("rmp", SearchMode::Fuzzy, 10).unwrap().is_empty());
    }
}
