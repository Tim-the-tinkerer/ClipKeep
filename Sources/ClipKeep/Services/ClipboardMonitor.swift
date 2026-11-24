import AppKit
import Foundation

/// Polls the general pasteboard and records new content into HistoryStore.
@MainActor
final class ClipboardMonitor: ObservableObject {
    @Published private(set) var isPaused = false
    @Published private(set) var lastSkipReason: String?
    @Published private(set) var lastCapturedAt: Date?

    private weak var store: HistoryStore?
    private var timer: Timer?
    private var lastChangeCount: Int = -1
    /// When we write the pasteboard ourselves, ignore the next matching change.
    private var ignoreNextChangeCount: Int?
    private var ignoreContentHash: String?

    func start(store: HistoryStore) {
        self.store = store
        lastChangeCount = NSPasteboard.general.changeCount
        restartTimer()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func setPaused(_ paused: Bool) {
        isPaused = paused
        if !paused {
            // Resync so we don't flood with everything that happened while paused
            lastChangeCount = NSPasteboard.general.changeCount
        }
    }

    func restartTimer() {
        timer?.invalidate()
        guard let store else { return }
        let interval = max(0.2, store.settings.pollInterval)
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.poll()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Copy a history item back to the pasteboard without re-recording as new if identical.
    /// The clipboard is left unchanged when the clip has nothing left to paste.
    func copyToPasteboard(_ item: ClipboardItem) {
        let pb = NSPasteboard.general
        guard write(item, to: pb) else { return }
        ignoreNextChangeCount = pb.changeCount
        ignoreContentHash = item.contentHash
        // Promote to top of history
        store?.add(item)
    }

    /// Place `item` on `pasteboard`. Returns false without clearing when the clip has no pasteable content.
    @discardableResult
    func write(_ item: ClipboardItem, to pasteboard: NSPasteboard) -> Bool {
        switch item.kind {
        case .text, .richText, .unknown:
            guard let text = item.text, !text.isEmpty else { return false }
            pasteboard.clearContents()
            return pasteboard.setString(text, forType: .string)
        case .image:
            let resolved = item.resolveFiles()
            defer { resolved.endAccess() }
            let data = store?.imageData(for: item) ?? item.imagePNGData
            let hasPNG = data?.isEmpty == false
            if resolved.urls.isEmpty && !hasPNG { return false }
            pasteboard.clearContents()
            var wrote = false
            if !resolved.urls.isEmpty {
                wrote = pasteboard.writeObjects(resolved.urls as [NSURL])
            }
            if let data, !data.isEmpty, pasteboard.setData(data, forType: .png) {
                wrote = true
            }
            return wrote
        case .files:
            let resolved = item.resolveFiles()
            defer { resolved.endAccess() }
            guard !resolved.urls.isEmpty else { return false }
            pasteboard.clearContents()
            return pasteboard.writeObjects(resolved.urls as [NSURL])
        }
    }

    // MARK: - Polling

    private func poll() {
        guard !isPaused, let store else { return }
        let pb = NSPasteboard.general
        let change = pb.changeCount
        guard change != lastChangeCount else { return }
        lastChangeCount = change

        if let ignore = ignoreNextChangeCount, ignore == change {
            ignoreNextChangeCount = nil
            return
        }

        let front = NSWorkspace.shared.frontmostApplication
        let evaluation = ExclusionService.evaluate(
            pasteboard: pb,
            settings: store.settings,
            frontmostApp: front
        )
        if evaluation.shouldSkip {
            lastSkipReason = evaluation.reason
            return
        }

        let items = makeItems(from: pb, frontmost: front, settings: store.settings)
        let fresh = items.filter { $0.contentHash != ignoreContentHash }
        ignoreContentHash = nil
        guard !fresh.isEmpty else { return }

        // Insert so the first clip ends up at the top.
        for item in fresh.reversed() {
            store.add(item)
        }
        lastCapturedAt = Date()
        lastSkipReason = nil
    }

    private func makeItems(
        from pb: NSPasteboard,
        frontmost: NSRunningApplication?,
        settings: AppSettings
    ) -> [ClipboardItem] {
        let bundleID = frontmost?.bundleIdentifier
        let appName = frontmost?.localizedName

        let fileURLs = pb.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true
        ]) as? [URL] ?? []
        let imagesOnly = !fileURLs.isEmpty && fileURLs.allSatisfy(ImageCapture.isImageFile)
        let inlineImage: Data? = settings.captureImages && (fileURLs.isEmpty || imagesOnly)
            ? ImageCapture.inlineData(from: pb)
            : nil
        let captured = ImageCapture.makeItems(
            fileURLs: fileURLs,
            inlineImage: inlineImage,
            captureImages: settings.captureImages,
            captureFiles: settings.captureFiles,
            sourceBundleID: bundleID,
            sourceAppName: appName
        )
        if !captured.isEmpty {
            return captured
        }

        // Prefer RTF before plain string. Most rich-text pasteboards also publish
        // public.utf8-plain-text; checking string first would always win as Text.
        // Content is still stored as plain text (no formatting preserved).
        if settings.captureRichText,
           let rtfData = pb.data(forType: .rtf),
           let attr = try? NSAttributedString(
               data: rtfData,
               options: [.documentType: NSAttributedString.DocumentType.rtf],
               documentAttributes: nil
           ) {
            let string = attr.string
            if !string.isEmpty {
                return [
                    ClipboardItem(
                        kind: .richText,
                        preview: String(string.prefix(500)),
                        sourceBundleID: bundleID,
                        sourceAppName: appName,
                        text: string,
                        contentHash: hashString("rtf:" + string)
                    )
                ]
            }
        }

        if settings.captureText, let string = pb.string(forType: .string), !string.isEmpty {
            let preview = String(string.prefix(500))
            return [
                ClipboardItem(
                    kind: .text,
                    preview: preview,
                    sourceBundleID: bundleID,
                    sourceAppName: appName,
                    text: string,
                    contentHash: hashString("text:" + string)
                )
            ]
        }

        return []
    }

    private func hashString(_ value: String) -> String {
        ImageCapture.digest(Data(value.utf8))
    }
}
