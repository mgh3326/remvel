//! Clipboard history core: storage, ingest-time preprocessing, search.
//!
//! The UI never touches raw pasteboard blobs except to paste them back.
//! Everything a list row or search needs is computed once at ingest time.

mod ffi;
mod kind;
mod schema;
mod search;
mod store;
mod tabs;

pub use ffi::{Remvel, file_paths_uti};
pub use kind::Kind;
pub use search::{Filter, SearchHit, SearchMode};
pub use store::{Capture, Facet, Facets, IngestResult, ItemSummary, KindFacet, Rep, Store, UTI_FILE_PATHS, pin_value};
pub use tabs::{ClosedTab, TabSeen};

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
