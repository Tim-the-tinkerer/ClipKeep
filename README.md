# ClipKeep

**Version 1.2.3** (build 10) — a native macOS menu bar app that keeps a local clipboard history, with privacy exclusions for password managers and other sensitive apps.

**Source & updates:** [github.com/Tim-the-tinkerer/ClipKeep](https://github.com/Tim-the-tinkerer/ClipKeep)

See [CHANGELOG.md](CHANGELOG.md) for release notes.

## Features

- **Menu bar only** — no Dock icon (`LSUIElement`)
- **History** for text, rich text (detected as RTF, **stored as plain text**), images, and file lists
- **Search**, pin, delete, and one-click re-copy
- **Pinned clips survive clears** — **Clear Unpinned** removes everything else; pinned items stay (and are never trimmed by the max-history or image-storage limits)
- **Image payloads on disk** — PNGs under `Payloads/`; `history.json` stays lean (metadata + filenames). A copied image file is snapshotted there too, and the original path is kept.
- **Configurable image storage budget** (default 200 MB)
- **File clips with security-scoped bookmarks** when the system provides resolvable URLs
- **Keyboard-friendly** — ↑/↓, Return, Delete in the panel; global hotkey (default **⌘⇧V**)
- **Check for Updates** — compares the app version to the latest GitHub release and opens the project page (no silent auto-install)
- **Password-manager aware by default** (best-effort; see [Privacy model](#privacy-model)):
  1. Honors `org.nspasteboard.ConcealedType` / `TransientType` (the standard signal from 1Password, Bitwarden, and others)
  2. Skips capture when a known password manager (or any app you add) is detected as frontmost
- **Local only** — history under `~/Library/Application Support/ClipKeep/`
- **Export / Import history** — a `.clipkeep` file of every clip (text, images, pins, file references). Merge adds clips that are not already here, or replace the current history with the file. Settings stay on this Mac. The file is not uploaded.
- Pause capture, clear unpinned or all, launch at login, and configurable max history size

## Requirements

- macOS 13 or later
- Xcode / Swift 5.9+ toolchain

## Build & run

```bash
cd ClipKeep
chmod +x build-app.sh
./build-app.sh
```

This builds a release binary, packages `ClipKeep.app` with `AppInfo.plist` (version metadata), ad-hoc signs, and launches the app.

Use `./build-app.sh --no-launch` to build without opening the app.

Or build the binary only (no app bundle / Info.plist packaging):

```bash
swift build -c release
```

> **Note:** After changing the version in `AppInfo.plist`, re-run `./build-app.sh` so `ClipKeep.app` picks up the new version. Settings and About read the version from the app bundle.

### App icon

```bash
swift Scripts/GenerateAppIcon.swift
```

Writes `Assets/AppIcon.iconset/` (Apple `iconutil` names: `icon_<size>.png` and retina `icon_<size>@2x.png` — `@2x` is a scale factor, not an email), `Assets/AppIcon.icns`, and `Assets/AppIcon-1024.png`. The build script uses the `.icns` if present.

## Usage

| Action | How |
|--------|-----|
| Open history | Click the clipboard icon, or global hotkey (default **⌘⇧V**) |
| Copy an item | Click a row, or select + **Return** |
| Move selection | **↑** / **↓** |
| Delete selection | **Delete** |
| Pin / unpin | Right-click → **Pin**, or **⌘P** when selected |
| Clear unpinned | Footer **Clear** → **Clear Unpinned…** (keeps pinned); or right-click menu bar icon |
| Clear all | Footer **Clear** → **Clear All…**; or Settings → Danger zone |
| Quick menu | Right-click the menu bar icon |
| Settings | Gear in the panel, or **⌘,** |
| Export history | Settings → **Export History…**, or the app menu / menu bar menu |
| Import history | Settings → **Import History…**, or the app menu / menu bar menu, or open a `.clipkeep` file |
| Check for updates | Settings → Updates, or right-click menu / app menu → **Check for Updates…** |
| Open GitHub | Settings → **Open GitHub**, or **View on GitHub** in menus |
| Pause / resume | Footer button or right-click menu |
| Quit | Power icon, or **⌘Q** when the panel is focused |

Pinned items show an orange pin icon and a pin count in the panel footer when any exist.

## Privacy model

ClipKeep **avoids storing secrets marked as concealed or copied while an excluded application is detected.** That is a strong practical defense, not a cryptographic guarantee that macOS itself does not provide.

1. **Concealed pasteboard** — If the system pasteboard is marked concealed/transient/auto-generated (NSPASTEBOARD conventions), the entry is ignored. This is the strongest layer.
2. **Source app exclusions** — While an excluded app is frontmost at poll time, copies are ignored. Defaults include 1Password, Bitwarden, LastPass, KeePassXC, Dashlane, Enpass, Proton Pass, NordPass, Keeper, Keychain Access, and macOS Passwords.
3. You can add any bundle ID (or “Add frontmost app”) in Settings.

**Limits of source-app exclusion:** ClipKeep polls the pasteboard (default every 0.4s) and sees the *currently frontmost* app, not necessarily the app that wrote the clipboard. If a password manager neither marks the pasteboard as concealed nor remains frontmost until the next poll, exclusion can miss that copy. Prefer managers that set concealed/transient types; both layers work together when they do.

**Local data layout:**

```text
~/Library/Application Support/ClipKeep/
├── history.json          # metadata, text, file paths/bookmarks (no large image Base64)
└── Payloads/
    └── <UUID>.png        # image bytes
```

File clips still record display paths (which may include usernames or folder names) plus security-scoped bookmarks when creation succeeds. A copied image file is also written into `Payloads/` as a PNG, so the picture remains if the original file moves. A copy that mixes images with other files stays a file list.

### History file

**Export History…** writes one `.clipkeep` file wherever you choose. **Import History…** reads one back. ClipKeep asks whether to merge or replace:

- **Merge** adds clips whose content is not already in history. Pins and dates from the file are kept for those clips. Clips already here stay as they are.
- **Replace** makes history match the file. The current clips are removed.

The file stays on this Mac. Settings (hotkey, exclusions, limits, launch at login) are not in the file. After import, the current item limit and image budget still apply, so a larger file can be trimmed.

Opening a `.clipkeep` file launches ClipKeep and asks the same question.

Format **CLIPKEEP/1** is a single file with magic `CKH1` (little-endian). It contains `manifest.json`, `history.json` (the same clip records as the live store), and `payloads/<uuid>.png`. Images are PNG. A path that leaves the file, or a payload that is not a PNG, is refused and the current history is left unchanged.

## Settings

- Max history items (default 100; **unpinned** only)
- Image storage budget in MB (default 200; 0 = unlimited; **unpinned** images trimmed first)
- Capture toggles: text; rich text (stored as plain); images; files
- Global hotkey enable + record shortcut (default ⌘⇧V)
- Respect concealed pasteboard
- Exclude by source app + custom list
- Launch at login
- Show count next to the menu bar icon
- Clear unpinned (keep pinned) / clear all history
- Export the whole history to a `.clipkeep` file, or import one (merge or replace)

## Project layout

```
ClipKeep/
  Package.swift
  AppInfo.plist              # Bundle ID + version (1.2.3 / build 10)
  build-app.sh               # Release build → ClipKeep.app
  CHANGELOG.md
  Assets/
    AppIcon.icns
    AppIcon.iconset/         # iconutil PNGs (1× and @2x)
  Sources/ClipKeep/
    MainEntry.swift          # Menu bar status item + popover + hotkey
    Models/                  # ClipboardItem, AppSettings, AppVersion
    Services/                # Monitor, store, history file, exclusions, launch-at-login, hotkey
    Views/                   # History panel + settings + history file panels + keyboard session
  Scripts/GenerateAppIcon.swift
```

## Versioning

| Field | Location | Current |
|-------|----------|---------|
| Marketing version | `CFBundleShortVersionString` in `AppInfo.plist` | **1.2.3** |
| Build number | `CFBundleVersion` in `AppInfo.plist` | **10** |
| UI display | `AppVersion` (reads packaged Info.plist) | e.g. `1.2.3 (10)` |

Release history: [CHANGELOG.md](CHANGELOG.md).

When shipping a release:

1. Bump both version fields in `AppInfo.plist` (and the fallbacks in `AppVersion.swift`).
2. Update [CHANGELOG.md](CHANGELOG.md) (move items out of Unreleased).
3. Align this README’s version line and layout note.
4. Run `./build-app.sh --no-launch` and confirm Settings / About show the new version.

## License

Use and modify freely for personal or commercial projects.
