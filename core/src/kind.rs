use std::fmt;

use rusqlite::types::{FromSql, FromSqlResult, ToSql, ToSqlOutput, ValueRef};

/// What an item is, decided once at ingest (`store::classify`). Stored as its `as_str` name.
/// Swift switches over this enum, so a new kind fails the app build until the UI handles it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum Kind {
    Text,
    /// A single web URL and nothing else.
    Link,
    /// HTML or RTF without a more specific kind.
    Rich,
    Image,
    Files,
    /// A CSS-style colour and nothing else.
    Color,
    /// Written or edited in Remvel's note editor rather than copied (notes.rs). Kept when the history is trimmed.
    Note,
}

impl Kind {
    pub const ALL: [Kind; 7] = [Kind::Text, Kind::Link, Kind::Rich, Kind::Image, Kind::Files, Kind::Color, Kind::Note];

    pub fn as_str(self) -> &'static str {
        match self {
            Kind::Text => "text",
            Kind::Link => "link",
            Kind::Rich => "rich",
            Kind::Image => "image",
            Kind::Files => "files",
            Kind::Color => "color",
            Kind::Note => "note",
        }
    }

    /// Unknown names, from a newer version's database, read as text.
    pub fn from_name(name: &str) -> Kind {
        Kind::ALL.into_iter().find(|k| k.as_str() == name).unwrap_or(Kind::Text)
    }
}

impl fmt::Display for Kind {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

impl ToSql for Kind {
    fn to_sql(&self) -> rusqlite::Result<ToSqlOutput<'_>> {
        Ok(ToSqlOutput::from(self.as_str()))
    }
}

impl FromSql for Kind {
    fn column_result(value: ValueRef<'_>) -> FromSqlResult<Self> {
        value.as_str().map(Kind::from_name)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn names_round_trip_and_unknown_reads_as_text() {
        for kind in Kind::ALL {
            assert_eq!(Kind::from_name(kind.as_str()), kind);
        }
        assert_eq!(Kind::from_name("hologram"), Kind::Text);
    }
}
