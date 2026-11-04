//! Clipboard history core: storage, ingest-time preprocessing, search.
//!
//! The UI never touches raw pasteboard blobs except to paste them back.
//! Everything a list row or search needs is computed once at ingest time.

mod ffi;
mod schema;
mod search;
mod store;

pub use ffi::Remvel;
pub use search::{Filter, SearchHit, SearchMode};
pub use store::{Capture, Facet, Facets, IngestResult, ItemSummary, Rep, Store};

#[derive(Debug, thiserror::Error, uniffi::Error)]
#[uniffi(flat_error)]
pub enum Error {
    #[error("sqlite: {0}")]
    Sqlite(#[from] rusqlite::Error),
    #[error("item {0} not found")]
    NotFound(i64),
}

pub type Result<T> = std::result::Result<T, Error>;

uniffi::setup_scaffolding!();
