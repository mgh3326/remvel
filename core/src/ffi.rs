//! The surface Swift sees. One `Remvel` per database; calls are serialized by a mutex,
//! so the Swift side should call from a background queue, never the main thread.

use std::path::Path;
use std::sync::{Arc, Mutex, MutexGuard};

use crate::{Capture, IngestResult, ItemSummary, Rep, Result, SearchHit, SearchMode, Store};

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

    pub fn count(&self) -> u64 {
        self.store().len() as u64
    }

    pub fn list(&self, offset: i64, limit: i64) -> Result<Vec<ItemSummary>> {
        self.store().list(offset, limit)
    }

    pub fn summaries(&self, ids: Vec<i64>) -> Result<Vec<ItemSummary>> {
        self.store().summaries(&ids)
    }

    /// `kinds` limits results to those item kinds; empty means all.
    pub fn search(&self, query: String, mode: SearchMode, kinds: Vec<String>, limit: u32) -> Result<Vec<SearchHit>> {
        self.store().search(&query, mode, &kinds, limit as usize)
    }

    pub fn touch(&self, id: i64, at: i64) -> Result<()> {
        self.store().touch(id, at)
    }

    pub fn preview_text(&self, id: i64, byte_offset: i64, max_bytes: i64) -> Result<String> {
        self.store().preview_text(id, byte_offset, max_bytes)
    }

    pub fn thumbnail(&self, id: i64) -> Result<Option<Vec<u8>>> {
        self.store().thumbnail(id)
    }

    pub fn reps(&self, id: i64) -> Result<Vec<Rep>> {
        self.store().reps(id)
    }

    pub fn set_pin(&self, id: i64, pin: Option<String>) -> Result<()> {
        self.store().set_pin(id, pin.as_deref())
    }

    pub fn delete(&self, id: i64) -> Result<()> {
        self.store().delete(id)
    }

    pub fn trim(&self, max_items: i64) -> Result<u64> {
        Ok(self.store().trim(max_items)? as u64)
    }
}
