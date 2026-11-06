//! The surface Swift sees. One `Remvel` per database; calls are serialized by a mutex,
//! so the Swift side should call from a background queue, never the main thread.
//!
//! Every integer here is `i64` (Swift `Int64`): ids, Unix-millisecond times, byte offsets,
//! counts and limits. Negative counts and limits read as 0. Only fuzzy scores and title
//! indices, which come from nucleo, are `u32`.

use std::path::Path;
use std::sync::{Arc, Mutex, MutexGuard};

use crate::{
    Capture, ClosedTab, Facets, Filter, IngestResult, ItemSummary, Rep, Result, SearchHit, Store, TabKey, TabSeen,
    UTI_FILE_PATHS, Visit,
};

/// The pasteboard type of Remvel's own rep for file copies: every copied path, one per line.
#[uniffi::export]
pub fn file_paths_uti() -> String {
    UTI_FILE_PATHS.to_owned()
}

fn usize_from(n: i64) -> usize {
    n.max(0) as usize
}

#[derive(uniffi::Object)]
pub struct Remvel {
    store: Mutex<Store>,
}

impl Remvel {
    fn store(&self) -> MutexGuard<'_, Store> {
        // A panic inside a call leaves the store usable; SQLite rolled the transaction back.
        self.store.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
    }
}

#[uniffi::export]
impl Remvel {
    #[uniffi::constructor]
    pub fn open(path: String) -> Result<Arc<Self>> {
        Ok(Arc::new(Remvel { store: Mutex::new(Store::open(Path::new(&path))?) }))
    }

    #[uniffi::constructor]
    pub fn open_in_memory() -> Result<Arc<Self>> {
        Ok(Arc::new(Remvel { store: Mutex::new(Store::open_in_memory()?) }))
    }

    pub fn ingest(&self, capture: Capture) -> Result<IngestResult> {
        self.store().ingest(capture)
    }

    pub fn count(&self) -> i64 {
        self.store().len() as i64
    }

    pub fn list(&self, offset: i64, limit: i64) -> Result<Vec<ItemSummary>> {
        self.store().list(offset, limit)
    }

    pub fn summaries(&self, ids: Vec<i64>) -> Result<Vec<ItemSummary>> {
        self.store().summaries(&ids)
    }

    /// What a history view shows, for the popup and Shortcuts alike. A blank query browses
    /// (pinned first, then newest); search text ranks by relevance and ignores pins.
    pub fn search(&self, query: String, filter: Filter, limit: i64) -> Result<Vec<SearchHit>> {
        self.store().search(&query, &filter, usize_from(limit))
    }

    pub fn facets(&self, max_apps: i64) -> Result<Facets> {
        self.store().facets(max_apps.max(0))
    }

    pub fn touch(&self, id: i64, at: i64) -> Result<()> {
        self.store().touch(id, at)
    }

    pub fn preview_text(&self, id: i64, byte_offset: i64, max_bytes: i64) -> Result<String> {
        self.store().preview_text(id, byte_offset, max_bytes)
    }

    pub fn set_thumbnail(&self, id: i64, png: Vec<u8>) -> Result<()> {
        self.store().set_thumbnail(id, &png)
    }

    pub fn thumbnail(&self, id: i64) -> Result<Option<Vec<u8>>> {
        self.store().thumbnail(id)
    }

    pub fn reps(&self, id: i64) -> Result<Vec<Rep>> {
        self.store().reps(id)
    }

    /// Pinning at `at` (Unix ms) puts the item after every earlier pin.
    pub fn set_pinned(&self, id: i64, pinned: bool, at: i64) -> Result<()> {
        self.store().set_pinned(id, pinned, at)
    }

    pub fn set_recognized_text(&self, id: i64, text: String) -> Result<()> {
        self.store().set_recognized_text(id, &text)
    }

    /// The item's text, or the text recognized in an image; empty when there is neither.
    pub fn full_text(&self, id: i64) -> Result<String> {
        self.store().full_text(id)
    }

    pub fn recognized_text(&self, id: i64) -> Result<Option<String>> {
        self.store().recognized_text(id)
    }

    pub fn unrecognized_images(&self, limit: i64) -> Result<Vec<i64>> {
        self.store().unrecognized_images(limit.max(0))
    }

    pub fn delete(&self, id: i64) -> Result<()> {
        self.store().delete(id)
    }

    /// Every tab `browser` (a bundle id) has open now; tabs of it missing since the last call are closed at `at`.
    pub fn record_tabs(&self, browser: String, tabs: Vec<TabSeen>, at: i64) -> Result<()> {
        self.store().record_tabs(&browser, &tabs, at)
    }

    pub fn tab_closed(&self, browser: String, url: String, at: i64) -> Result<()> {
        self.store().tab_closed(&browser, &url, at)
    }

    pub fn forget_tab(&self, browser: String, url: String) -> Result<()> {
        self.store().forget_tab(&browser, &url)
    }

    pub fn set_tab_text(&self, browser: String, url: String, text: String) -> Result<()> {
        self.store().set_tab_text(&browser, &url, &text)
    }

    pub fn tab_text(&self, browser: String, url: String) -> Result<Option<String>> {
        self.store().tab_text(&browser, &url)
    }

    /// Visits read from a browser's history; a year's worth is kept, at most 100,000.
    pub fn import_visits(&self, visits: Vec<Visit>, now: i64) -> Result<()> {
        self.store().import_visits(&visits, now)
    }

    /// The latest visit stored for `browser`, Unix ms, or 0: where the next import starts.
    pub fn last_visit(&self, browser: String) -> Result<i64> {
        self.store().last_visit(&browser)
    }

    pub fn search_visits(&self, query: String, limit: i64) -> Result<Vec<Visit>> {
        self.store().search_visits(&query, limit)
    }

    pub fn forget_visit(&self, browser: String, url: String) -> Result<()> {
        self.store().forget_visit(&browser, &url)
    }

    /// Open tabs whose kept page text holds every word of `query`.
    pub fn open_tabs_with_text(&self, query: String, limit: i64) -> Result<Vec<TabKey>> {
        self.store().open_tabs_with_text(&query, limit)
    }

    /// Closed tabs matching every word of `query` in title, address or page text, newest closed first.
    pub fn closed_tabs(&self, query: String, limit: i64) -> Result<Vec<ClosedTab>> {
        self.store().closed_tabs(&query, limit)
    }

    /// Returns how many items were removed.
    pub fn trim(&self, max_items: i64) -> Result<i64> {
        Ok(self.store().trim(max_items.max(0))? as i64)
    }
}
