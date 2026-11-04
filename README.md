# Remvel

A fast clipboard history manager for macOS that stays fast with a very large history.

Remvel (*rem*ember + *vel*ocity) keeps tens of thousands of clips and still opens, searches, and previews them instantly.
The UI is native AppKit. Storage and search are a Rust core (SQLite FTS5 + [nucleo](https://github.com/helix-editor/nucleo)) behind [UniFFI](https://github.com/mozilla/uniffi-rs).

> Status: early prototype. Expect breaking changes.

## Why

Clipboard managers usually slow down as history grows, because they load and prepare every item when the popup opens.
Remvel does the expensive work once, in the background, when you copy:

- The list reads only metadata, one page at a time.
- Search runs off the main thread: fuzzy over titles, substring over full text (CJK included).
- Previews read 64 KB at a time, and images are downsampled before decoding.

On 100,000 items, a list page takes 0.03 ms, fuzzy search about 19 ms, and full-text search about 20 ms (Apple M1 Pro, synthetic data). See [DESIGN.md](DESIGN.md).

## Build

Requirements: macOS 14+, Xcode, Rust (stable), [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
make run     # build core + app and launch
make test    # core tests
```

Press **⌥⌘V** to open the history. **Enter** pastes the selected item. Pasting needs Accessibility permission; without it, Remvel only copies the item.

## Layout

```
core/   Rust: storage, ingest, search, preview (UniFFI)
app/    Swift/AppKit menu bar app (XcodeGen project.yml)
docs/   references and notes
```
