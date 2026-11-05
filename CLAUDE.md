# Remvel: working notes

macOS clipboard history manager. Rust core (`core/`, SQLite + nucleo, exposed via UniFFI) and an AppKit app (`app/Remvel/`).
Design and measurements: [DESIGN.md](DESIGN.md). User-facing behaviour: [README.md](README.md).

## Checks

- `make check` runs `cargo fmt --check`, clippy with warnings as errors, and the core tests. CI runs the same, then builds the app.
- `make fmt` formats the core (`core/rustfmt.toml`).
- The app only builds on macOS with Xcode (`make app`). Linux can check the core only; Swift changes are verified by CI.

## Rules that keep results consistent

- **The core owns ordering.** Browse and search order live in `core/src/search.rs` (see its module docs):
  browsing (no search text, any filter) shows pins first, then newest; search text ranks by relevance and ignores pins.
  The popup (`HistoryModel`) and Shortcuts (`Intents.swift`) call `Remvel.search` and never sort, merge or re-rank hits themselves.
- **"Newest first" is `last_copied_at DESC, id DESC`** everywhere: SQL queries, the in-memory `TitleIndex`, and `trim`.
  A new query that orders items must use the same key.
- **`items` columns mirrored in `TitleIndex`** (title, kind, app, last_copied_at, pin) change in both places in the same `Store` method.
- **Equal counts** (facets) break by name, so the sidebar and filter menu keep one order.
- **Missing ids** in single-item calls return `Error::NotFound`; `summaries` skips them instead.
- **Pin values** come from the core (`setPinned(id:pinned:at:)`, `pin_value`); Swift never formats them.
- **Item text** for pasting or Shortcuts comes from `Remvel.fullText`, not from stitching `previewText` and `recognizedText`.
- **Schema changes** append a step to `MIGRATIONS` in `core/src/schema.rs`. Never edit or reorder a shipped step.
  `SCHEMA` holds the baseline with `IF NOT EXISTS` and may be updated to match the migrations.

## Conventions

- Times are Unix milliseconds (`Int64` in Swift, `i64` in Rust). In Swift use `Date().unixMillis` and `Date(unixMillis:)`.
- Every integer in the FFI is `i64` / `Int64` (ids, times, byte offsets, counts, limits); only nucleo's scores and title indices are `u32`.
- Item kinds are the `Kind` enum (`core/src/kind.rs`), stored as its name. Swift compares with `.image`, never a string;
  `Kinds.info` switches exhaustively, so a new kind fails the app build until it has a name and symbol.
- Constants both sides need live in the core and are exported (e.g. `filePathsUti()`), not copied into Swift.
- Core calls from Swift go through `Core.shared.run` (one serial background queue). Never call the store on the main thread.
  Writes whose result nobody reads use `Core.shared.perform("what", …)`, which logs failures; never drop a result with `{ _ in }`.
- Add a test in the core for any behaviour change there, especially ordering.
- User-visible changes get a line in `CHANGELOG.md` under the next version (or `Unreleased`).
- Comments say why, not what. Code, comments and commits are in English; DESIGN.md and docs/ are in Korean.
