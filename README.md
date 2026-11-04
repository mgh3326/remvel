# Remvel

[![Build](https://github.com/mgh3326/remvel/actions/workflows/build.yml/badge.svg)](https://github.com/mgh3326/remvel/actions/workflows/build.yml)

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

macOS 26 added a clipboard history to Spotlight. Remvel is for when that is not enough: unlimited history, full-text search that finds Korean and other CJK text anywhere in a clip, and no telemetry. Everything stays in one local SQLite file.

## Build

Requirements: macOS 14+, Xcode, Rust (stable), [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
make run     # build core + app and launch
make test    # core tests
```

CI builds every push to `main`; the app is attached to each run as `Remvel.zip`. It is ad-hoc signed, so on first launch right-click it and choose **Open**.

## Use

Press **⌥⌘V** (changeable in Settings) to open the history.

| Key | Action |
|---|---|
| ⏎ | Paste the selected item |
| ⇧⏎ | Paste as plain text |
| ⌥⏎ | Copy only, without pasting |
| ⌘1–⌘9 | Paste the item with that number |
| ⌘-click, then ⏎ | Paste several items in the order you picked them |
| `#link` `#image` `#file` `#text` `#rich` | Filter by kind; combine with search text |
| ⌘, | Settings |

Pasting needs Accessibility permission; Remvel asks on first launch. Without it, Remvel only copies the item.

The menu bar menu can pause recording. Settings has the shortcut, popup position, history limit, launch at login, ignored apps, and whether to record copies from other devices (Universal Clipboard). Passwords that apps mark as concealed are never recorded.

## Layout

```
core/   Rust: storage, ingest, search, preview (UniFFI)
app/    Swift/AppKit menu bar app (XcodeGen project.yml)
docs/   references and notes
```

## License

Remvel is licensed under the [GNU General Public License v3.0](LICENSE).

The name "Remvel" and its icon are not covered by the license. Forks must use a different name and icon.

Contributions require agreeing that the maintainer may also distribute them under other terms (for example, through the Mac App Store). This will be formalized as a CLA before the first outside contribution is merged.
