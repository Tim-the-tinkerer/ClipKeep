import AppKit
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Turns pasteboard image bytes and copied image files into PNG payloads.
enum ImageCapture {
    /// One payload larger than this stays a file reference. Matches the history-file entry cap.
    static let maxPayloadBytes = 128 * 1024 * 1024

    private static let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
    private static let extensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "tif", "tiff", "heic", "heif", "webp", "bmp", "ico", "jp2",
    ]

    static func isImageFile(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        guard !ext.isEmpty else { return false }
        if let type = UTType(filenameExtension: ext), type.conforms(to: .image) {
            return true
        }
        return extensions.contains(ext)
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Path-less images hash the PNG so two screenshots of the same pixels collapse.
    /// A clip that keeps a Finder path also hashes that path, so two identical files stay distinct.
    /// The `file:` prefix marks a path hash so an older pixel-only hash can be upgraded on load.
    static func contentHash(png: Data, filePaths: [String]) -> String {
        let pixels = digest(png)
        guard !filePaths.isEmpty else { return pixels }
        let identity = filePaths.joined(separator: "\n")
        return "file:" + digest(Data((pixels + "\n" + identity).utf8))
    }

    /// Clips for one paste. Image files and raw image bytes become PNG payloads.
    /// A non-image file stays a file list. Text is left for the caller.
    static func makeItems(
        fileURLs: [URL],
        inlineImage: Data?,
        captureImages: Bool,
        captureFiles: Bool,
        sourceBundleID: String?,
        sourceAppName: String?
    ) -> [ClipboardItem] {
        let imagesOnly = !fileURLs.isEmpty && fileURLs.allSatisfy(isImageFile)

        if captureImages, imagesOnly {
            let snapshotted = fileURLs.compactMap {
                imageItem(
                    fromFile: $0,
                    sourceBundleID: sourceBundleID,
                    sourceAppName: sourceAppName
                )
            }
            if snapshotted.count == fileURLs.count {
                return snapshotted
            }
            if fileURLs.count == 1,
               let inlineImage,
               let item = imageItem(
                   fromInline: inlineImage,
                   fileURL: fileURLs[0],
                   sourceBundleID: sourceBundleID,
                   sourceAppName: sourceAppName
               ) {
                return [item]
            }
        }

        if captureFiles, !fileURLs.isEmpty {
            return [
                fileItem(
                    urls: fileURLs,
                    sourceBundleID: sourceBundleID,
                    sourceAppName: sourceAppName
                )
            ]
        }

        if captureImages, fileURLs.isEmpty, let inlineImage,
           let item = imageItem(
               fromInline: inlineImage,
               fileURL: nil,
               sourceBundleID: sourceBundleID,
               sourceAppName: sourceAppName
           ) {
            return [item]
        }

        return []
    }

    /// First image bytes on the pasteboard, in the order screenshots and browsers publish them.
    static func inlineData(from pasteboard: NSPasteboard) -> Data? {
        let types: [NSPasteboard.PasteboardType] = [
            .png,
            NSPasteboard.PasteboardType("public.jpeg"),
            .tiff,
            NSPasteboard.PasteboardType("public.heic"),
            NSPasteboard.PasteboardType("public.heif"),
            NSPasteboard.PasteboardType("com.compuserve.gif"),
            NSPasteboard.PasteboardType("org.webmproject.webp"),
            NSPasteboard.PasteboardType("public.webp"),
        ]
        for type in types {
            if let data = pasteboard.data(forType: type), !data.isEmpty, data.count <= maxPayloadBytes {
                return data
            }
        }
        if let image = pasteboard.readObjects(forClasses: [NSImage.self], options: nil)?.first as? NSImage,
           let tiff = image.tiffRepresentation,
           !tiff.isEmpty,
           tiff.count <= maxPayloadBytes {
            return tiff
        }
        return nil
    }

    static func pngData(contentsOf url: URL) -> Data? {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        if values?.isRegularFile == false { return nil }
        if let size = values?.fileSize, size == 0 || size > maxPayloadBytes { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return pngData(from: data)
    }

    /// Returns PNG bytes. A PNG is kept as-is. JPEG, TIFF, HEIC, GIF, and WebP are re-encoded.
    static func pngData(from data: Data) -> Data? {
        guard !data.isEmpty, data.count <= maxPayloadBytes else { return nil }
        if isPNG(data) { return data }
        let options: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithData(data as CFData, options as CFDictionary),
              CGImageSourceGetCount(source) > 0,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            out,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest), out.length > 0, out.length <= maxPayloadBytes else {
            return nil
        }
        return out as Data
    }

    static func pixelSize(of data: Data) -> (Int, Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return nil }
        let width = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue
        let height = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue
        guard let width, let height, width > 0, height > 0 else { return nil }
        return (width, height)
    }

    private static func imageItem(
        fromFile url: URL,
        sourceBundleID: String?,
        sourceAppName: String?
    ) -> ClipboardItem? {
        guard let png = pngData(contentsOf: url) else { return nil }
        return imageItem(
            png: png,
            preview: url.lastPathComponent,
            fileURL: url,
            sourceBundleID: sourceBundleID,
            sourceAppName: sourceAppName
        )
    }

    private static func imageItem(
        fromInline data: Data,
        fileURL: URL?,
        sourceBundleID: String?,
        sourceAppName: String?
    ) -> ClipboardItem? {
        guard let png = pngData(from: data) else { return nil }
        let preview: String
        if let fileURL {
            preview = fileURL.lastPathComponent
        } else if let size = pixelSize(of: png) {
            preview = "Image \(size.0)×\(size.1)"
        } else {
            preview = "Image"
        }
        return imageItem(
            png: png,
            preview: preview,
            fileURL: fileURL,
            sourceBundleID: sourceBundleID,
            sourceAppName: sourceAppName
        )
    }

    private static func imageItem(
        png: Data,
        preview: String,
        fileURL: URL?,
        sourceBundleID: String?,
        sourceAppName: String?
    ) -> ClipboardItem {
        let paths = fileURL.map { [$0.path] } ?? []
        let bookmarks = fileURL.map { ClipboardItem.bookmarks(for: [$0]) } ?? []
        return ClipboardItem(
            kind: .image,
            preview: preview,
            sourceBundleID: sourceBundleID,
            sourceAppName: sourceAppName,
            imagePNGData: png,
            filePaths: paths,
            fileBookmarks: bookmarks,
            contentHash: contentHash(png: png, filePaths: paths)
        )
    }

    private static func fileItem(
        urls: [URL],
        sourceBundleID: String?,
        sourceAppName: String?
    ) -> ClipboardItem {
        let paths = urls.map(\.path)
        let preview = paths.map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")
        return ClipboardItem(
            kind: .files,
            preview: preview.isEmpty ? "\(paths.count) file(s)" : preview,
            sourceBundleID: sourceBundleID,
            sourceAppName: sourceAppName,
            filePaths: paths,
            fileBookmarks: ClipboardItem.bookmarks(for: urls),
            contentHash: digest(Data(("files:" + paths.joined(separator: "\n")).utf8))
        )
    }

    private static func isPNG(_ data: Data) -> Bool {
        data.count >= pngSignature.count && data.prefix(pngSignature.count).elementsEqual(pngSignature)
    }
}

@MainActor
enum ImageCaptureSelfTest {
    private static let png = Data(
        base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFBQIAX8jx0gAAAABJRU5ErkJggg=="
    )!
    /// 1×1 black PNG, distinct from `png`.
    private static let pngBlack = Data(
        base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
    )!

    static func run() -> String? {
        if let failure = inlinePNGBecomesImage() { return failure }
        if let failure = jpegBecomesPNG() { return failure }
        if let failure = imageFileIsWrittenToPayloads() { return failure }
        if let failure = textFileStaysAFile() { return failure }
        if let failure = legacyImageFileMigrates() { return failure }
        if let failure = identicalImageFilesStayDistinct() { return failure }
        if let failure = upgradedFinderImageKeepsItsPath() { return failure }
        if let failure = replaceBudgetsIncomingPayloads() { return failure }
        if let failure = failedHistorySaveKeepsPreviousPayloads() { return failure }
        return nil
    }

    private static func inlinePNGBecomesImage() -> String? {
        let items = ImageCapture.makeItems(
            fileURLs: [],
            inlineImage: png,
            captureImages: true,
            captureFiles: true,
            sourceBundleID: "com.example.shot",
            sourceAppName: "Shot"
        )
        guard items.count == 1, items[0].kind == .image else { return "inline image was not captured" }
        guard items[0].imagePNGData == png else { return "inline PNG bytes changed" }
        guard items[0].filePaths.isEmpty else { return "inline image invented a file path" }
        guard items[0].contentHash == ImageCapture.digest(png) else { return "inline image hash changed" }
        guard items[0].sourceAppName == "Shot" else { return "inline image dropped the source app" }
        return nil
    }

    private static func jpegBecomesPNG() -> String? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 1,
            pixelsHigh: 1,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return "could not make a bitmap" }
        guard let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9]) else {
            return "could not make a JPEG"
        }
        guard let converted = ImageCapture.pngData(from: jpeg) else { return "JPEG did not become a PNG" }
        guard converted.prefix(8).elementsEqual([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) else {
            return "converted image is not a PNG"
        }
        let items = ImageCapture.makeItems(
            fileURLs: [],
            inlineImage: jpeg,
            captureImages: true,
            captureFiles: true,
            sourceBundleID: nil,
            sourceAppName: nil
        )
        guard items.count == 1, items[0].kind == .image, items[0].imagePNGData == converted else {
            return "JPEG paste was not stored as a PNG"
        }
        return nil
    }

    private static func imageFileIsWrittenToPayloads() -> String? {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipkeep-image-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let picture = root.appendingPathComponent("photo.jpg")
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            guard let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: 2,
                pixelsHigh: 2,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            ), let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else {
                return "could not make a JPEG file"
            }
            try jpeg.write(to: picture)
        } catch {
            return "could not write a JPEG file: \(error.localizedDescription)"
        }

        let items = ImageCapture.makeItems(
            fileURLs: [picture],
            inlineImage: nil,
            captureImages: true,
            captureFiles: true,
            sourceBundleID: nil,
            sourceAppName: "Finder"
        )
        guard items.count == 1, items[0].kind == .image else { return "image file was stored as a file path only" }
        guard items[0].preview == "photo.jpg" else { return "image file preview changed" }
        guard items[0].filePaths == [picture.path] else { return "image file path was dropped" }
        guard let png = items[0].imagePNGData, png.prefix(8).elementsEqual([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) else {
            return "image file did not produce a PNG"
        }

        let store = HistoryStore(storageDirectory: root.appendingPathComponent("store"), settings: .default)
        store.add(items[0])
        guard let name = store.items.first?.imagePayloadName else { return "store did not name the payload" }
        let saved = store.payloadsDir.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: saved.path) else { return "payload file was not written" }
        guard (try? Data(contentsOf: saved)) == png else { return "payload bytes do not match the PNG" }
        guard store.items.first?.filePaths == [picture.path] else { return "store dropped the original path" }
        return nil
    }

    private static func textFileStaysAFile() -> String? {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipkeep-text-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let note = root.appendingPathComponent("note.txt")
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try Data("hello".utf8).write(to: note)
        } catch {
            return "could not write a text file: \(error.localizedDescription)"
        }
        let items = ImageCapture.makeItems(
            fileURLs: [note],
            inlineImage: nil,
            captureImages: true,
            captureFiles: true,
            sourceBundleID: nil,
            sourceAppName: nil
        )
        guard items.count == 1, items[0].kind == .files else { return "text file was stored as an image" }
        guard items[0].imagePNGData == nil, items[0].imagePayloadName == nil else {
            return "text file produced a payload"
        }
        guard items[0].filePaths == [note.path] else { return "text file path changed" }
        return nil
    }

    private static func legacyImageFileMigrates() -> String? {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipkeep-migrate-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let picture = root.appendingPathComponent("kept.png")
        let history = root.appendingPathComponent("history.json")
        let id = UUID(uuidString: "12121212-3434-5656-7878-909090909090")!
        let legacy = ClipboardItem(
            id: id,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            isPinned: true,
            kind: .files,
            preview: "kept.png",
            filePaths: [picture.path],
            fileBookmarks: [],
            contentHash: "legacy-path-only"
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try png.write(to: picture)
            try encoder.encode([legacy]).write(to: history)
        } catch {
            return "could not plant a legacy image file: \(error.localizedDescription)"
        }

        let store = HistoryStore(storageDirectory: root, settings: .default)
        guard store.items.count == 1 else { return "migration changed the clip count" }
        guard let item = store.items.first, item.kind == .image, item.isPinned, item.id == id else {
            return "legacy image file was not snapshotted"
        }
        guard item.filePaths == [picture.path] else { return "migration dropped the file path" }
        guard item.imagePayloadName == "\(id.uuidString).png" else { return "migration used an unexpected payload name" }
        let saved = store.payloadsDir.appendingPathComponent(item.imagePayloadName!)
        guard (try? Data(contentsOf: saved)) == png else { return "migration wrote the wrong payload" }
        guard item.contentHash == ImageCapture.contentHash(png: png, filePaths: [picture.path]) else {
            return "migration hash ignored the file path"
        }
        return nil
    }

    private static func identicalImageFilesStayDistinct() -> String? {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipkeep-dup-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fileA = root.appendingPathComponent("A.png")
        let fileB = root.appendingPathComponent("B.png")
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try png.write(to: fileA)
            try png.write(to: fileB)
        } catch {
            return "could not write duplicate image files: \(error.localizedDescription)"
        }

        guard let first = capturedImage(fileA), let second = capturedImage(fileB) else {
            return "duplicate image files were not captured"
        }
        guard first.contentHash.hasPrefix("file:"), second.contentHash.hasPrefix("file:") else {
            return "finder image hash ignored the file path"
        }
        guard first.contentHash != second.contentHash else { return "identical files shared one hash" }

        let store = HistoryStore(storageDirectory: root.appendingPathComponent("store"), settings: .default)
        store.add(first)
        store.add(second)
        guard store.items.count == 2 else { return "duplicate files collapsed to \(store.items.count)" }
        guard store.items[0].filePaths == [fileB.path] else { return "latest clip restored \(store.items[0].filePaths)" }
        guard store.items[1].filePaths == [fileA.path] else { return "older clip restored \(store.items[1].filePaths)" }

        guard let again = capturedImage(fileA) else { return "could not capture A.png again" }
        store.add(again)
        guard store.items.count == 2 else { return "copying A.png again created a third clip" }
        guard store.items[0].filePaths == [fileA.path] else { return "copying A.png again restored \(store.items[0].filePaths)" }
        guard store.items[1].filePaths == [fileB.path] else { return "B.png moved when A.png was copied again" }

        let oldStyle = [
            finderItem(path: fileA.path, hash: ImageCapture.digest(png)),
            finderItem(path: fileB.path, hash: ImageCapture.digest(png)),
        ]
        let restored = HistoryStore(storageDirectory: root.appendingPathComponent("restored"), settings: .default)
        do {
            let archive = try HistoryArchive.build(
                items: oldStyle,
                loadPayload: { _ in nil },
                exportedAt: Date(timeIntervalSince1970: 1_700_000_000),
                appVersion: "1.2.2"
            )
            _ = try restored.importHistory(archive, mode: .replace)
        } catch {
            return "import of identical files failed: \(error.localizedDescription)"
        }
        guard restored.items.count == 2 else { return "import collapsed identical files to \(restored.items.count)" }
        guard Set(restored.items.map(\.filePaths)) == [[fileA.path], [fileB.path]] else {
            return "import restored \(restored.items.map(\.filePaths))"
        }
        guard Set(restored.items.map(\.contentHash)).count == 2,
              restored.items.allSatisfy({ $0.contentHash.hasPrefix("file:") }) else {
            return "import kept pixel-only hashes"
        }
        return nil
    }

    private static func upgradedFinderImageKeepsItsPath() -> String? {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipkeep-rehash-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fileA = root.appendingPathComponent("A.png")
        let fileB = root.appendingPathComponent("B.png")
        let id = UUID(uuidString: "ABABABAB-CDCD-EFEF-1212-343434343434")!
        let name = "\(id.uuidString).png"
        let legacy = ClipboardItem(
            id: id,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            kind: .image,
            preview: "A.png",
            imagePayloadName: name,
            filePaths: [fileA.path],
            contentHash: ImageCapture.digest(png)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try png.write(to: fileA)
            try png.write(to: fileB)
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent("Payloads", isDirectory: true),
                withIntermediateDirectories: true
            )
            try png.write(to: root.appendingPathComponent("Payloads", isDirectory: true).appendingPathComponent(name))
            try encoder.encode([legacy]).write(to: root.appendingPathComponent("history.json"))
        } catch {
            return "could not plant an upgraded image: \(error.localizedDescription)"
        }

        let store = HistoryStore(storageDirectory: root, settings: .default)
        guard store.items.count == 1, let upgraded = store.items.first else {
            return "upgrade changed the clip count"
        }
        guard upgraded.filePaths == [fileA.path] else { return "upgrade dropped the file path" }
        guard upgraded.contentHash == ImageCapture.contentHash(png: png, filePaths: [fileA.path]) else {
            return "upgrade left a pixel-only hash"
        }
        guard upgraded.contentHash != ImageCapture.digest(png) else { return "upgrade hash still matches the PNG alone" }

        let oldCopy = finderItem(path: fileA.path, hash: ImageCapture.digest(png))
        do {
            let archive = try HistoryArchive.build(
                items: [oldCopy],
                loadPayload: { _ in nil },
                exportedAt: Date(timeIntervalSince1970: 1_700_000_100),
                appVersion: "1.2.2"
            )
            let merged = try store.importHistory(archive, mode: .merge)
            guard merged.added == 0, merged.skippedDuplicates == 1 else {
                return "merge added an older copy of A.png (\(merged.added) added)"
            }
        } catch {
            return "merge of an older A.png failed: \(error.localizedDescription)"
        }
        guard store.items.count == 1 else { return "older A.png was imported again" }

        guard let capturedB = capturedImage(fileB) else { return "could not capture B.png" }
        store.add(capturedB)
        guard store.items.count == 2 else { return "B.png collapsed into the upgraded A.png" }
        guard store.items[0].filePaths == [fileB.path] else { return "latest upgraded clip restored \(store.items[0].filePaths)" }
        guard store.items.contains(where: { $0.filePaths == [fileA.path] }) else { return "upgrade lost A.png" }

        let inline = ImageCapture.makeItems(
            fileURLs: [],
            inlineImage: png,
            captureImages: true,
            captureFiles: true,
            sourceBundleID: nil,
            sourceAppName: nil
        )
        guard inline.count == 1 else { return "path-less image was not captured" }
        store.add(inline[0])
        guard store.items.count == 3 else { return "path-less image collapsed into a file clip" }
        guard store.items.contains(where: { $0.filePaths.isEmpty && $0.contentHash == ImageCapture.digest(png) }) else {
            return "path-less image lost its pixel hash"
        }
        return nil
    }

    private static func replaceBudgetsIncomingPayloads() -> String? {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipkeep-budget-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var settings = AppSettings.default
        settings.maxPayloadStorageMB = 1
        let store = HistoryStore(storageDirectory: root.appendingPathComponent("store"), settings: settings)
        let oldID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        store.add(ClipboardItem(
            id: oldID,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            kind: .image,
            preview: "old",
            imagePNGData: paddedPNG(800 * 1024),
            contentHash: "hash-old-budget"
        ))
        guard store.items.count == 1, let oldName = store.items[0].imagePayloadName else {
            return "budget setup did not keep the old image"
        }

        let incoming = [
            ClipboardItem(
                id: UUID(uuidString: "22222222-3333-4444-5555-666666666666")!,
                createdAt: Date(timeIntervalSince1970: 1_700_000_100),
                kind: .image,
                preview: "newer",
                imagePNGData: paddedPNG(400 * 1024),
                contentHash: "hash-budget-newer"
            ),
            ClipboardItem(
                id: UUID(uuidString: "33333333-4444-5555-6666-777777777777")!,
                createdAt: Date(timeIntervalSince1970: 1_700_000_200),
                kind: .image,
                preview: "newest",
                imagePNGData: paddedPNG(400 * 1024),
                contentHash: "hash-budget-newest"
            ),
        ]
        let result: HistoryImportResult
        do {
            let archive = try HistoryArchive.build(
                items: incoming,
                loadPayload: { _ in nil },
                exportedAt: Date(timeIntervalSince1970: 1_700_000_200),
                appVersion: "1.2.2"
            )
            result = try store.importHistory(archive, mode: .replace)
        } catch {
            return "budget replace failed: \(error.localizedDescription)"
        }
        guard result.trimmed == 0 else { return "budget replace trimmed \(result.trimmed)" }
        guard Set(store.items.map(\.preview)) == ["newer", "newest"] else {
            return "budget replace kept \(store.items.map(\.preview))"
        }
        let names = payloadFileNames(in: store.payloadsDir)
        guard names.contains(oldName) == false else { return "budget replace left the old image" }
        guard names.count == 2 else { return "budget replace left payload files \(names)" }
        return nil
    }

    private static func failedHistorySaveKeepsPreviousPayloads() -> String? {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipkeep-save-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let imageID = UUID(uuidString: "ABABABAB-1111-2222-3333-444444444444")!
        let store = HistoryStore(storageDirectory: root, settings: .default)
        store.add(ClipboardItem(
            id: UUID(uuidString: "CDCDCDCD-1111-2222-3333-444444444444")!,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            kind: .text,
            preview: "keep",
            text: "keep",
            contentHash: "hash-keep-text"
        ))
        store.add(ClipboardItem(
            id: imageID,
            createdAt: Date(timeIntervalSince1970: 1_700_000_100),
            kind: .image,
            preview: "red",
            imagePNGData: png,
            contentHash: "hash-red-disk"
        ))
        let payloadName = "\(imageID.uuidString).png"
        let payloadURL = store.payloadsDir.appendingPathComponent(payloadName)
        guard (try? Data(contentsOf: payloadURL)) == png else { return "setup did not write the original image" }

        let historyURL = root.appendingPathComponent("history.json")
        do {
            try FileManager.default.removeItem(at: historyURL)
            try FileManager.default.createDirectory(at: historyURL, withIntermediateDirectories: true)
        } catch {
            return "could not block history.json: \(error.localizedDescription)"
        }

        let incoming = ClipboardItem(
            id: imageID,
            createdAt: Date(timeIntervalSince1970: 1_700_000_200),
            kind: .image,
            preview: "black",
            imagePNGData: pngBlack,
            contentHash: "hash-black-disk"
        )
        do {
            let archive = try HistoryArchive.build(
                items: [incoming],
                loadPayload: { _ in nil },
                exportedAt: Date(timeIntervalSince1970: 1_700_000_200),
                appVersion: "1.2.2"
            )
            _ = try store.importHistory(archive, mode: .replace)
            return "import reported success when history.json could not be saved"
        } catch let error as HistoryArchiveError {
            guard case .writeFailed = error else {
                return "import failed with \(error.localizedDescription)"
            }
        } catch {
            return "import failed with \(error.localizedDescription)"
        }

        guard store.items.count == 2 else { return "failed import changed the clip count to \(store.items.count)" }
        guard store.items.contains(where: { $0.text == "keep" }) else { return "failed import dropped the text clip" }
        guard let image = store.items.first(where: { $0.id == imageID }) else { return "failed import dropped the image" }
        guard image.imagePayloadName == payloadName else { return "failed import renamed the original image" }
        guard (try? Data(contentsOf: payloadURL)) == png else { return "failed import replaced the original image bytes" }
        let names = payloadFileNames(in: store.payloadsDir)
        guard names == [payloadName] else { return "failed import left payload files \(names)" }
        return nil
    }

    private static func capturedImage(_ url: URL) -> ClipboardItem? {
        let items = ImageCapture.makeItems(
            fileURLs: [url],
            inlineImage: nil,
            captureImages: true,
            captureFiles: true,
            sourceBundleID: nil,
            sourceAppName: "Finder"
        )
        guard items.count == 1, items[0].kind == .image else { return nil }
        return items[0]
    }

    private static func finderItem(path: String, hash: String) -> ClipboardItem {
        ClipboardItem(
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            kind: .image,
            preview: (path as NSString).lastPathComponent,
            imagePNGData: png,
            filePaths: [path],
            contentHash: hash
        )
    }

    private static func paddedPNG(_ bytes: Int) -> Data {
        var data = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        if bytes > data.count {
            data.append(Data(repeating: 0, count: bytes - data.count))
        }
        return data
    }

    private static func payloadFileNames(in directory: URL) -> [String] {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else { return [] }
        return urls.map(\.lastPathComponent).filter { $0.hasSuffix(".png") }.sorted()
    }
}
