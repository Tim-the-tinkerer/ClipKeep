import AppKit

/// Save and open panels for a local history file. The file is never uploaded.
@MainActor
enum HistoryTransfer {
    static func exportHistory(store: HistoryStore) {
        let panel = NSSavePanel()
        panel.title = "Export History"
        panel.prompt = "Export"
        panel.message = "Saves every clip to a file on this Mac. Settings are not included."
        panel.nameFieldStringValue = HistoryArchive.suggestedFileName()
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.allowedContentTypes = [HistoryArchive.fileType]
        panel.allowsOtherFileTypes = false
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let archive = try store.exportHistory(to: url)
            let images = archive.payloads.count
            let imageText = images == 1 ? "1 image file" : "\(images) image files"
            inform(
                title: "Exported \(clips(archive.items.count))",
                body: "Saved \(url.lastPathComponent). \(archive.pinnedCount) pinned. \(imageText). The file stays on this Mac."
            )
        } catch {
            warn("Could Not Export History", error.localizedDescription)
        }
    }

    static func importHistory(store: HistoryStore, fileURL: URL? = nil) {
        let url: URL
        if let fileURL {
            url = fileURL
        } else {
            let panel = NSOpenPanel()
            panel.title = "Import History"
            panel.prompt = "Import"
            panel.message = "Choose a ClipKeep history file (.clipkeep) on this Mac."
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            panel.allowsMultipleSelection = false
            panel.allowedContentTypes = [HistoryArchive.fileType]
            panel.allowsOtherFileTypes = true
            NSApp.activate(ignoringOtherApps: true)
            guard panel.runModal() == .OK, let picked = panel.url else { return }
            url = picked
        }

        let archive: HistoryArchive
        do {
            archive = try HistoryArchive.read(from: url)
        } catch {
            warn("Could Not Import History", error.localizedDescription)
            return
        }

        guard let mode = confirmImport(archive, filename: url.lastPathComponent) else { return }
        do {
            let result = try store.importHistory(archive, mode: mode)
            let title = mode == .replace ? "Replaced History" : "Merged History"
            inform(title: title, body: result.summary)
        } catch {
            warn("Could Not Import History", error.localizedDescription)
        }
    }

    private static func confirmImport(_ archive: HistoryArchive, filename: String) -> HistoryImportMode? {
        let alert = NSAlert()
        alert.messageText = "Import \(clips(archive.items.count))?"
        let when = archive.manifest.exportedAt.formatted(date: .abbreviated, time: .shortened)
        let pinned = archive.pinnedCount == 1 ? "1 pinned" : "\(archive.pinnedCount) pinned"
        alert.informativeText = """
        \(filename) holds \(clips(archive.items.count)) (\(pinned)), saved \(when) by ClipKeep \(archive.manifest.appVersion).

        Merge adds clips that are not already in history. Pins and dates from the file are kept for those clips.

        Replace makes history match this file. The clips currently in history are removed.

        Settings on this Mac stay as they are. The file is read from this Mac.
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Merge")
        alert.addButton(withTitle: "Replace")
        alert.addButton(withTitle: "Cancel")
        if alert.buttons.count > 1 {
            alert.buttons[1].hasDestructiveAction = true
        }
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return .merge
        case .alertSecondButtonReturn:
            return .replace
        default:
            return nil
        }
    }

    private static func inform(title: String, body: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = body
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private static func warn(_ title: String, _ body: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = body
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private static func clips(_ count: Int) -> String {
        count == 1 ? "1 clip" : "\(count) clips"
    }
}
