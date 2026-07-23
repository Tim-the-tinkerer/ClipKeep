import AppKit
import CryptoKit
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
    func copyToPasteboard(_ item: ClipboardItem) {
        let pb = NSPasteboard.general
        pb.clearContents()

        var wrote = false
        switch item.kind {
        case .text, .richText:
            if let text = item.text {
                pb.setString(text, forType: .string)
                wrote = true
            }
        case .image:
            if let data = item.imagePNGData, let image = NSImage(data: data) {
                pb.writeObjects([image])
                wrote = true
            }
        case .files:
            let urls = item.filePaths.map { URL(fileURLWithPath: $0) }.filter {
                FileManager.default.fileExists(atPath: $0.path)
            }
            if !urls.isEmpty {
                pb.writeObjects(urls as [NSURL])
                wrote = true
            }
        case .unknown:
            if let text = item.text {
                pb.setString(text, forType: .string)
                wrote = true
            }
        }

        if wrote {
            ignoreNextChangeCount = pb.changeCount
            ignoreContentHash = item.contentHash
            // Promote to top of history
            store?.add(item)
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

        guard let item = makeItem(from: pb, frontmost: front, settings: store.settings) else {
            return
        }

        if let ignoreHash = ignoreContentHash, ignoreHash == item.contentHash {
            ignoreContentHash = nil
            return
        }
        ignoreContentHash = nil

        store.add(item)
        lastCapturedAt = Date()
        lastSkipReason = nil
    }

    private func makeItem(
        from pb: NSPasteboard,
        frontmost: NSRunningApplication?,
        settings: AppSettings
    ) -> ClipboardItem? {
        let bundleID = frontmost?.bundleIdentifier
        let appName = frontmost?.localizedName

        // Prefer files if present
        if settings.captureFiles,
           let urls = pb.readObjects(forClasses: [NSURL.self], options: [
               .urlReadingFileURLsOnly: true
           ]) as? [URL],
           !urls.isEmpty {
            let paths = urls.map(\.path)
            let preview = paths.map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")
            let hash = hashString("files:" + paths.joined(separator: "\n"))
            return ClipboardItem(
                kind: .files,
                preview: preview.isEmpty ? "\(paths.count) file(s)" : preview,
                sourceBundleID: bundleID,
                sourceAppName: appName,
                filePaths: paths,
                contentHash: hash
            )
        }

        // Images
        if settings.captureImages,
           let image = pb.readObjects(forClasses: [NSImage.self], options: nil)?.first as? NSImage,
           let tiff = image.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            // Avoid treating pure-text pasteboards that also advertise image as images
            let hasString = pb.string(forType: .string) != nil
            let types = pb.types ?? []
            let looksLikeImage = types.contains(.png)
                || types.contains(.tiff)
                || types.contains(NSPasteboard.PasteboardType("public.png"))
                || types.contains(NSPasteboard.PasteboardType("public.tiff"))
            if looksLikeImage && !(hasString && !types.contains(.png) && !types.contains(.tiff)) {
                let hash = hashData(png)
                let sizeLabel = "\(Int(image.size.width))×\(Int(image.size.height))"
                return ClipboardItem(
                    kind: .image,
                    preview: "Image \(sizeLabel)",
                    sourceBundleID: bundleID,
                    sourceAppName: appName,
                    imagePNGData: png,
                    contentHash: hash
                )
            }
        }

        // Plain text
        if settings.captureText, let string = pb.string(forType: .string), !string.isEmpty {
            let preview = String(string.prefix(500))
            return ClipboardItem(
                kind: .text,
                preview: preview,
                sourceBundleID: bundleID,
                sourceAppName: appName,
                text: string,
                contentHash: hashString("text:" + string)
            )
        }

        // RTF → plain
        if settings.captureRichText,
           let rtfData = pb.data(forType: .rtf),
           let attr = try? NSAttributedString(
               data: rtfData,
               options: [.documentType: NSAttributedString.DocumentType.rtf],
               documentAttributes: nil
           ) {
            let string = attr.string
            guard !string.isEmpty else { return nil }
            return ClipboardItem(
                kind: .richText,
                preview: String(string.prefix(500)),
                sourceBundleID: bundleID,
                sourceAppName: appName,
                text: string,
                contentHash: hashString("rtf:" + string)
            )
        }

        return nil
    }

    private func hashString(_ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func hashData(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
