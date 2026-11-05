# Changelog

Each version's section becomes its GitHub release notes and is shown in Remvel's update prompt.

## 0.4.0

- An image's preview shows the text read from it below the picture, selectable and scrolling. Words of the search are marked in it.
- A link whose page shows no picture (a sign-in wall, a bot check, a private link) shows its full address large under the card, host in bold.
- Link rows drop `https://` and `www.` and cut the middle of a long address, so links to one site show where they differ.
- ⌘K opens the selected item's actions in a list inside the popup (type to filter, ↑↓, ⏎, Esc): paste, copy, pin, delete, and paste it changed — UPPERCASE, lowercase, Title Case, camelCase, snake_case, kebab-case, trimmed, joined, sorted or de-duplicated lines, formatted or minified JSON, URL and Base64 encoded or decoded. Right-click a row opens the same list.
- Links show the page's title, site and image. The page is loaded only when you select the link, never for links that look like sign-in, reset or token links, and Settings → Privacy turns it off.
- The popup opens small, as a list (520 × 480), so it covers less of the screen. ⌘Y adds the preview, then shows it across the popup, then goes back to the list; → at the end of the search text also shows the preview. Settings → Open with: list only, list and preview, or as you last left it. Link pages are not loaded while the preview is hidden.
- Deleted rows fade out.
- A copy of several files shows every file as a tile and is titled "3 files: …". Click a tile, or pick it under ⌘K → Paste One File, to paste that file alone. Files that were moved or deleted are greyed out.
- Runs on Intel Macs too (universal build).
- `@safari` and the like in the search field filter by source app.
- The sidebar (⌥⌘S) lists every app you copied from, not just the top 12.
- Settings → Privacy can hide the popup from screen sharing, recordings and screenshots.
- Pin items with ⌥P: pinned items stay at the top of the history and are never trimmed.
- Delete an item with ⌥⌫.
- Text in copied images is recognized on your Mac (Apple Vision), so searches find the words in screenshots. ⇧⏎ on an image pastes its text. Settings → Search turns this off.
- Two-letter searches, like most Korean words, also find text in images.
- ⌘K, ⌘Y, ⌘A, ⌘C and the other shortcuts work while typing Korean or another non-Latin script.
- Shortcuts, Spotlight and Siri actions: Search Clipboard History, Get Recent Clipboard Items, Get Text of Clipboard Item, Copy Clipboard Item, Open Remvel.
- ⌘A, ⌘C, ⌘X, ⌘V and ⌘Z work in the search field. ⌘C with nothing selected there copies the selected item.
- The popup and Shortcuts show search results in the same order.
- Filtered lists (a kind, an app, or a `#tag` with no search text) show pinned items first, like the full history. Search results rank by match and ignore pins; pinned items keep their badge.
- Items copied or pasted at the same moment keep one order in the list, filters, search, and after relaunch.

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
