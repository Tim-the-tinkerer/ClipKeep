# ClipKeep

A native macOS menu bar app that keeps a local clipboard history — with privacy exclusions for password managers and other sensitive apps.

## Features

- **Menu bar only** — no Dock icon (`LSUIElement`)
- **History** for text, rich text (as plain), images, and file lists
- **Search**, pin, delete, and one-click re-copy
- **Password-manager safe by default**:
  1. Honors `org.nspasteboard.ConcealedType` / `TransientType` (the standard signal from 1Password, Bitwarden, and others)
  2. Skips capture when a known password manager (or any app you add) is frontmost
- **Local only** — history stored under `~/Library/Application Support/ClipKeep/`
- Pause capture, clear unpinned/all, and configure max history size

## Requirements

- macOS 13 or later
- Xcode / Swift 5.9+ toolchain

## Build & run

```bash
cd ClipKeep
chmod +x build-app.sh
./build-app.sh
```

Use `./build-app.sh --no-launch` to build without opening the app.

Or build the binary only:

```bash
swift build -c release
```

## Usage

| Action | How |
|--------|-----|
| Open history | Click the clipboard icon in the menu bar |
| Copy an item | Click a row (or use the context menu) |
| Quick menu | Right-click the menu bar icon |
| Settings | Gear in the panel, or **⌘,** |
| Pause / resume | Footer button or right-click menu |
| Quit | Power icon, or **⌘Q** when the panel is focused |

## Privacy model

ClipKeep is designed so secrets from password managers are not written to disk:

1. **Concealed pasteboard** — If the system pasteboard is marked concealed/transient/auto-generated (NSPASTEBOARD conventions), the entry is ignored.
2. **Source app exclusions** — While an excluded app is frontmost, copies are ignored. Defaults include 1Password, Bitwarden, LastPass, KeePassXC, Dashlane, Enpass, Proton Pass, NordPass, Keeper, Keychain Access, and macOS Passwords.
3. You can add any bundle ID (or “Add frontmost app”) in Settings.

**Note:** Exclusion by source app uses the *frontmost* app when the pasteboard changes. Most password managers mark the pasteboard as concealed as well, so both layers protect you.

## Settings

- Max history items (default 100)
- Capture toggles: text, rich text, images, files
- Respect concealed pasteboard
- Exclude by source app + custom list
- Show item count next to the menu bar icon

## Project layout

```
ClipKeep/
  Package.swift
  AppInfo.plist
  build-app.sh
  Sources/ClipKeep/
    MainEntry.swift          # Menu bar status item + popover
    Models/                  # ClipboardItem, AppSettings
    Services/                # Monitor, store, exclusions
    Views/                   # History panel + settings
  Scripts/GenerateAppIcon.swift
```

## License

Use and modify freely for personal or commercial projects.
