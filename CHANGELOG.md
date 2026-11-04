# Changelog

Each version's section becomes its GitHub release notes and is shown in Remvel's update prompt.

## Unreleased

- The popup and Shortcuts show search results in the same order.
- Filtered lists (a kind, an app, or a `#tag` with no search text) show pinned items first, like the full history. Search results rank by match and ignore pins; pinned items keep their badge.
- Items copied or pasted at the same moment keep one order in the list, filters, search, and after relaunch.

## 0.4.0

- Pin items with ⌥P: pinned items stay at the top of the history and are never trimmed.
- Delete an item with ⌥⌫.
- Right-click a row for Paste, Paste as Plain Text, Copy, Pin and Delete.
- Text in copied images is recognized on your Mac (Apple Vision), so searches find the words in screenshots. ⇧⏎ on an image pastes its text. Settings → Search turns this off.
- Shortcuts, Spotlight and Siri actions: Search Clipboard History, Get Recent Clipboard Items, Get Text of Clipboard Item, Copy Clipboard Item, Open Remvel.
- ⌘A, ⌘C, ⌘X, ⌘V and ⌘Z work in the search field. ⌘C with nothing selected there copies the selected item.

## 0.3.0

- The default shortcut is now ⇧⌘C, as in Maccy. Remvel warns when another app already holds the shortcut.
- Redesigned popup with a fixed size (960 × 600): a counted history list, a preview card with the app, first and last copy time, counts, and copy count pinned below it, and a footer that shows what ⏎ does right now.
- A large image no longer makes the popup grow.
- Filter by kind or source app from the filter button, with removable chips.
- Sidebar (⌥⌘S or the sidebar button) to browse by kind and app with counts.
- Colours (#hex, rgb(), hsl()) are a kind of their own, with a swatch.
- Images are titled with their size.
- The ⌘-click queue keeps its order while you search or filter; Esc clears it first.
- ⏎ while composing Korean (or any input method) finishes the character instead of pasting.

## 0.2.0

- Settings window: shortcut, popup position, history limit, launch at login, Show in Dock, ignored apps.
- Paste as plain text (⇧⏎), copy only (⌥⏎), quick paste (⌘1–9), and pasting several items in order (⌘-click, then ⏎).
- Filter by kind with `#link`, `#image`, `#file`, `#text`, `#rich`.
- Copied files keep every path and show a Quick Look thumbnail and preview.
- Rows show the source app's icon; the preview shows character, line, and file counts.
- Pause recording; skip ignored apps and, optionally, Universal Clipboard copies.
- Polling speeds up after a copy and slows down when idle.
- New app and menu bar icons.
- Updates from GitHub Releases, with an option to include nightly builds.

## 0.1.0

- First prototype: Rust core with SQLite full-text and fuzzy search, AppKit popup with paged list and chunked preview.
