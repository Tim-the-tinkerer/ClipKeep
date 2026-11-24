# Changelog

All notable changes to ClipKeep are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.2.3] — 2026-11-23

### Fixed
- **Shared images** — Deleting or clearing one clip keeps the PNG when another clip still uses it. A repeated copy keeps the picture when the payload file could not be saved.
- **Copy** — Copying a clip that no longer has its file or its image leaves the clipboard as it was.
- **Payload paths** — A history entry can only name a UUID file inside Payloads. ClipKeep does not follow a name that points somewhere else.
- **Menu bar menu** — Quit works. Clear Unpinned asks before removing clips.
- **Shortcut recording** — The current global hotkey is suspended while a new shortcut is recorded, then restored.
- **Launch at login** — The Settings switch matches the login item when Settings opens.

## [1.2.2] — 2026-11-23

### Fixed
- **Import image budget** — Replace measures the image storage limit from the payloads the incoming history names. Images that fit are kept. PNGs from the previous history are removed only after the new history is saved.
- **Import save failure** — If `history.json` cannot be saved, import reports the error and leaves the previous history and its images in place.
- **Identical image files** — Two copied files with the same pixels and different paths stay separate clips, including image files upgraded from older history. Copying the same path again still updates that clip.

## [1.2.1] — 2026-11-23

### Fixed
- **Image payloads** — Copying an image file, such as a JPEG from Finder, now writes a PNG under `Application Support/ClipKeep/Payloads/`. The original path is kept, so the file can still be pasted. Screenshots and other copied pictures are saved from the pasteboard image data. On launch, a history entry that is a single image file is snapshotted into Payloads when that file is still readable.

## [1.2.0] — 2026-11-23

### Added
- **Export History** and **Import History** — a `.clipkeep` file (CLIPKEEP/1) holds every clip: text, images, pins, and file references. Export writes that file where you choose. Import can merge clips that are not already here, or replace the current history with the file. Settings stay on this Mac. The file is not uploaded. Available from Settings, the app menu, the menu bar menu, and by opening a `.clipkeep` file.

## [1.1.2] — 2026-08-09

### Added
- **Check for Updates** — queries the latest [GitHub release](https://github.com/Tim-the-tinkerer/ClipKeep/releases) for [Tim-the-tinkerer/ClipKeep](https://github.com/Tim-the-tinkerer/ClipKeep), compares the tag to the running version, and offers to open the release or repository. Available from Settings → Updates, the app menu, and the menu bar right-click menu (**View on GitHub** opens the repo). Does not auto-download or install.

## [1.1.1] — 2026-08-09

### Fixed
- **Persist after trim** — Changing max-item or image-storage limits (or trimming on load) rewrites `history.json`, so removed items and deleted PNG payloads do not reappear after relaunch.
- **Image budget no longer deletes text clips** — Size trim only removes unpinned items that free payload bytes. If pinned images alone exceed the budget, text history is retained and Settings reports the over-budget state.
- **Security-scoped file access pairing** — `resolveFiles()` / `endAccess()` so re-copy starts and stops scoped access for each use.
- **List image previews** — Rows use a cached 72px thumbnail instead of decoding full PNG payloads while scrolling.

## [1.1.0] — 2026-08-09

### Added
- **External image payloads** — PNG data is stored as files under `Application Support/ClipKeep/Payloads/<UUID>.png`. `history.json` keeps metadata and filenames only (no Base64 image bloat). Legacy inline images migrate on load.
- **Configurable image storage budget** — Settings → History → image storage (MB, default 200; 0 = unlimited). Oldest **unpinned** items are trimmed when over budget; pinned clips are never removed by size trim.
- **Security-scoped bookmarks for file clips** — File lists save bookmark data alongside display paths so moved files can still resolve when the OS allows; re-copy uses resolved URLs.
- **Keyboard navigation** in the history panel: **↑/↓** select, **Return** copy, **Delete** remove, **⌘P** pin/unpin, **Esc** leaves the search field.
- **Global hotkey** (default **⌘⇧V**) to open/close the history panel; configurable or disabled in Settings → Keyboard.

### Changed
- Clear all / remove image items also deletes associated payload files; orphan payloads are pruned.
- Settings window height increased to fit storage and keyboard options.

## [1.0.2] — 2026-08-09

### Fixed
- **Rich text capture order** — RTF is preferred before plain `public.utf8-plain-text`, so formatted pasteboards are classified as rich text instead of always winning as plain text.
- **AppSettings migration** — missing keys decode to defaults so adding new settings fields no longer resets all preferences.
- **App icon set** — complete 1× / 2× PNG set for `iconutil` (`icon_<size>.png` and `icon_<size>@2x.png` retina scale names); generator builds `@2x` names explicitly.

### Changed
- Honest privacy wording: ClipKeep *avoids* storing concealed/excluded copies; it does not claim absolute certainty.
- Settings label: “Capture rich text (stored as plain)”; list kind label: “Rich Text (plain)”.
- Model comment clarifies file clips use absolute paths, not security-scoped bookmarks.
- Version display reads from the app bundle (`AppVersion`); `build-app.sh` prints version/build from `AppInfo.plist`.
- README documents privacy limits, rich-text storage behavior, and local-data notes (paths, image JSON size).

## [1.0.1] — 2026-08-09

### Improved
- **Clear keeps pinned clips** — Clearing history removes only unpinned items by default. Pinned clips stay in history and remain pinned.
- **Clear menu** in the history panel footer: **Clear Unpinned…** and **Clear All…**, each with a confirmation that explains what is kept or removed.
- Confirmation and captions in **Settings → Danger zone** for clear unpinned vs clear all.
- Menu bar quick menu label: **Clear Unpinned (Keep Pinned)** (disabled when nothing unpinned remains).
- Footer shows a pinned-item count when any clips are pinned.
- History store updates reassign arrays so pin and clear changes refresh the UI reliably.
- Max-history trimming never drops pinned items.

## [1.0.0] — 2026-07-23

### Added
- Native macOS menu bar clipboard history app (no Dock icon).
- Capture for text, rich text (stored as plain), images, and file lists.
- Search, pin, delete, and one-click re-copy.
- Privacy exclusions: concealed/transient pasteboard types and default password-manager app list.
- Local-only history under Application Support.
- Pause capture, settings (max size, capture toggles, launch at login, menu bar count).
- App bundle packaging via `build-app.sh`.

[1.2.3]: https://github.com/Tim-the-tinkerer/ClipKeep/compare/v1.2.2...v1.2.3
[1.2.2]: https://github.com/Tim-the-tinkerer/ClipKeep/compare/v1.2.1...v1.2.2
[1.2.1]: https://github.com/Tim-the-tinkerer/ClipKeep/compare/v1.2.0...v1.2.1
[1.2.0]: https://github.com/Tim-the-tinkerer/ClipKeep/compare/v1.1.2...v1.2.0
[1.1.2]: https://github.com/Tim-the-tinkerer/ClipKeep/compare/v1.1.1...v1.1.2
[1.1.1]: https://github.com/Tim-the-tinkerer/ClipKeep/compare/v1.1.0...v1.1.1
[1.1.0]: https://github.com/Tim-the-tinkerer/ClipKeep/compare/v1.0.2...v1.1.0
[1.0.2]: https://github.com/Tim-the-tinkerer/ClipKeep/compare/v1.0.1...v1.0.2
[1.0.1]: https://github.com/Tim-the-tinkerer/ClipKeep/compare/v1.0.0...v1.0.1
[1.0.0]: https://github.com/Tim-the-tinkerer/ClipKeep/releases/tag/v1.0.0
