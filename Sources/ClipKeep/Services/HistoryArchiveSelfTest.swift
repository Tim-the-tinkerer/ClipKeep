import AppKit
import Foundation

/// Checks the local history file without reading or writing the user's ClipKeep folder.
@MainActor
enum HistoryArchiveSelfTest {
    private static let stamp = Date(timeIntervalSince1970: 1_700_000_000)

    static func run() -> String? {
        let defaultsBefore = UserDefaults.standard.data(forKey: AppSettings.storageKey)
        let userRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ClipKeep", isDirectory: true)
        let historyBefore = try? Data(contentsOf: userRoot.appendingPathComponent("history.json"))
        let payloadsBefore = payloadNames(in: userRoot.appendingPathComponent("Payloads", isDirectory: true))

        let checks: [() -> String?] = [
            roundTripTextFilesAndImage,
            deterministicEncoding,
            rejectsBadMagic,
            rejectsFutureVersion,
            rejectsUnsafePath,
            rejectsTruncation,
            rejectsMissingPayload,
            rejectsNonPNG,
            storeRoundTripReplaceMergeAndTrim,
            sharedPayloadSurvivesRemoval,
            repeatedCopyKeepsImageWhenSaveFails,
            unsafePayloadNameStaysInsidePayloads,
            copyLeavesClipboardWhenClipIsEmpty,
            ImageCaptureSelfTest.run,
        ]
        for check in checks {
            if let failure = check() {
                return failure
            }
        }

        let defaultsAfter = UserDefaults.standard.data(forKey: AppSettings.storageKey)
        if defaultsBefore != defaultsAfter {
            return "self-test wrote user settings"
        }
        let historyAfter = try? Data(contentsOf: userRoot.appendingPathComponent("history.json"))
        if historyBefore != historyAfter {
            return "self-test wrote the user history"
        }
        let payloadsAfter = payloadNames(in: userRoot.appendingPathComponent("Payloads", isDirectory: true))
        if payloadsBefore != payloadsAfter {
            return "self-test changed user image payloads"
        }
        return nil
    }

    private static func roundTripTextFilesAndImage() -> String? {
        let imageID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let text = sampleItem(
            id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            createdAt: stamp,
            isPinned: true,
            kind: .text,
            preview: "Hello ClipKeep",
            sourceBundleID: "com.example.notes",
            sourceAppName: "Notes",
            text: "Hello ClipKeep\nsecond line",
            contentHash: "hash-text"
        )
        let files = sampleItem(
            id: UUID(uuidString: "22222222-3333-4444-5555-666666666666")!,
            createdAt: stamp.addingTimeInterval(-60),
            kind: .files,
            preview: "Report.pdf",
            filePaths: ["/Users/example/Report.pdf"],
            fileBookmarks: [Data([0x01, 0x02, 0xFF, 0x10])],
            contentHash: "hash-files"
        )
        let image = sampleItem(
            id: imageID,
            createdAt: stamp.addingTimeInterval(-120),
            kind: .image,
            preview: "pixel",
            imagePNGData: pngRed,
            contentHash: "hash-image"
        )

        let archive: HistoryArchive
        do {
            archive = try HistoryArchive.build(
                items: [text, files, image],
                loadPayload: { _ in nil },
                exportedAt: stamp,
                appVersion: "1.2.0"
            )
        } catch {
            return "build failed: \(error.localizedDescription)"
        }

        if archive.items.count != 3 { return "expected 3 clips" }
        if archive.payloads.count != 1 { return "expected 1 image payload" }
        if archive.payloads["\(imageID.uuidString).png"] != pngRed { return "image bytes were not stored" }
        if archive.items.contains(where: { $0.imagePNGData != nil }) { return "inline image leaked into the archive" }
        if archive.manifest.format != HistoryArchive.formatID { return "manifest format" }
        if archive.manifest.itemCount != 3 || archive.manifest.pinnedCount != 1 { return "manifest counts" }

        let decoded: HistoryArchive
        do {
            decoded = try HistoryArchive.read(data: try archive.encodedData())
        } catch {
            return "read failed: \(error.localizedDescription)"
        }
        if decoded.items.map(\.id) != archive.items.map(\.id) { return "id order changed" }
        if decoded.items.map(\.contentHash) != ["hash-text", "hash-files", "hash-image"] { return "hashes changed" }
        if decoded.items[0].text != "Hello ClipKeep\nsecond line" { return "text changed" }
        if decoded.items[0].isPinned != true { return "pin was dropped" }
        if decoded.items[0].sourceBundleID != "com.example.notes" { return "source app changed" }
        if decoded.items[1].filePaths != ["/Users/example/Report.pdf"] { return "file path changed" }
        if decoded.items[1].fileBookmarks != [Data([0x01, 0x02, 0xFF, 0x10])] { return "file bookmark changed" }
        if decoded.payloads["\(imageID.uuidString).png"] != pngRed { return "image bytes changed" }
        if abs(decoded.manifest.exportedAt.timeIntervalSince(stamp)) > 1 {
            return "export date changed"
        }
        if abs(decoded.items[0].createdAt.timeIntervalSince(stamp)) > 1 {
            return "clip date changed"
        }
        return nil
    }

    private static func deterministicEncoding() -> String? {
        let item = sampleItem(
            id: UUID(uuidString: "33333333-4444-5555-6666-777777777777")!,
            createdAt: stamp,
            kind: .text,
            preview: "same",
            text: "same",
            contentHash: "hash-same"
        )
        do {
            let first = try HistoryArchive.build(
                items: [item],
                loadPayload: { _ in nil },
                exportedAt: stamp,
                appVersion: "1.2.0"
            ).encodedData()
            let second = try HistoryArchive.build(
                items: [item],
                loadPayload: { _ in nil },
                exportedAt: stamp,
                appVersion: "1.2.0"
            ).encodedData()
            if first != second { return "encoding was not stable" }
        } catch {
            return "determinism build failed: \(error.localizedDescription)"
        }
        return nil
    }

    private static func rejectsBadMagic() -> String? {
        do {
            _ = try HistoryArchive.read(data: Data(repeating: 0, count: 16))
            return "bad magic was accepted"
        } catch HistoryArchiveError.unrecognized {
            return nil
        } catch {
            return "bad magic threw \(error.localizedDescription)"
        }
    }

    private static func rejectsFutureVersion() -> String? {
        let data = rawContainer(version: 2, files: [])
        do {
            _ = try HistoryArchive.read(data: data)
            return "version 2 was accepted"
        } catch HistoryArchiveError.unsupportedVersion(let version) where version == 2 {
            return nil
        } catch {
            return "version 2 threw \(error.localizedDescription)"
        }
    }

    private static func rejectsUnsafePath() -> String? {
        let data = rawContainer(files: [("payloads/../../outside.png", pngRed)])
        do {
            _ = try HistoryArchive.read(data: data)
            return "unsafe path was accepted"
        } catch HistoryArchiveError.unsafePath {
            return nil
        } catch {
            return "unsafe path threw \(error.localizedDescription)"
        }
    }

    private static func rejectsTruncation() -> String? {
        let item = sampleItem(
            id: UUID(uuidString: "44444444-5555-6666-7777-888888888888")!,
            createdAt: stamp,
            kind: .text,
            preview: "cut",
            text: "cut",
            contentHash: "hash-cut"
        )
        do {
            var data = try HistoryArchive.build(
                items: [item],
                loadPayload: { _ in nil },
                exportedAt: stamp,
                appVersion: "1.2.0"
            ).encodedData()
            data.removeLast()
            _ = try HistoryArchive.read(data: data)
            return "truncated file was accepted"
        } catch HistoryArchiveError.damaged {
            return nil
        } catch {
            return "truncated file threw \(error.localizedDescription)"
        }
    }

    private static func rejectsMissingPayload() -> String? {
        let id = UUID(uuidString: "55555555-6666-7777-8888-999999999999")!
        let item = sampleItem(
            id: id,
            createdAt: stamp,
            kind: .image,
            preview: "gone",
            imagePayloadName: "\(id.uuidString).png",
            contentHash: "hash-gone"
        )
        do {
            _ = try HistoryArchive.build(items: [item], loadPayload: { _ in nil }, exportedAt: stamp, appVersion: "1.2.0")
            return "missing image was accepted"
        } catch HistoryArchiveError.missingPayload {
            return nil
        } catch {
            return "missing image threw \(error.localizedDescription)"
        }
    }

    private static func rejectsNonPNG() -> String? {
        let item = sampleItem(
            id: UUID(uuidString: "66666666-7777-8888-9999-AAAAAAAAAAAA")!,
            createdAt: stamp,
            kind: .image,
            preview: "nope",
            imagePNGData: Data("not a png".utf8),
            contentHash: "hash-nope"
        )
        do {
            _ = try HistoryArchive.build(items: [item], loadPayload: { _ in nil }, exportedAt: stamp, appVersion: "1.2.0")
            return "non-PNG image was accepted"
        } catch HistoryArchiveError.notPNG {
            return nil
        } catch {
            return "non-PNG threw \(error.localizedDescription)"
        }
    }

    private static func storeRoundTripReplaceMergeAndTrim() -> String? {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipkeep-selftest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let imageID = UUID(uuidString: "ABCDABCD-1234-5678-9ABC-DEF012345678")!
        let source = HistoryStore(storageDirectory: root.appendingPathComponent("source"), settings: .default)
        source.add(sampleItem(
            id: imageID,
            createdAt: stamp,
            kind: .image,
            preview: "pixel",
            imagePNGData: pngRed,
            contentHash: "hash-red"
        ))
        source.add(sampleItem(
            id: UUID(uuidString: "99999999-8888-7777-6666-555555555555")!,
            createdAt: stamp.addingTimeInterval(10),
            isPinned: true,
            kind: .text,
            preview: "pinned note",
            text: "pinned note",
            contentHash: "hash-pinned"
        ))
        source.add(sampleItem(
            id: UUID(uuidString: "12121212-3434-5656-7878-909090909090")!,
            createdAt: stamp.addingTimeInterval(20),
            kind: .files,
            preview: "Notes.txt",
            filePaths: ["/tmp/Notes.txt"],
            fileBookmarks: [Data([0x0A, 0x0B])],
            contentHash: "hash-notes"
        ))

        let file = root.appendingPathComponent("history.clipkeep")
        let exported: HistoryArchive
        do {
            exported = try source.exportHistory(to: file, exportedAt: stamp)
        } catch {
            return "store export failed: \(error.localizedDescription)"
        }

        let restored = HistoryStore(storageDirectory: root.appendingPathComponent("restored"), settings: .default)
        let replaceResult: HistoryImportResult
        do {
            let archive = try HistoryArchive.read(from: file)
            replaceResult = try restored.importHistory(archive, mode: .replace)
        } catch {
            return "store replace failed: \(error.localizedDescription)"
        }
        if replaceResult.resultingCount != 3 || restored.items.count != 3 {
            return "replace count \(restored.items.count)"
        }
        if restored.items.map(\.contentHash).sorted() != ["hash-notes", "hash-pinned", "hash-red"] {
            return "replace hashes \(restored.items.map(\.contentHash))"
        }
        guard let pinned = restored.items.first(where: { $0.contentHash == "hash-pinned" }) else {
            return "pinned clip missing after replace"
        }
        if pinned.text != "pinned note" || pinned.isPinned != true { return "pinned clip changed" }
        guard let files = restored.items.first(where: { $0.contentHash == "hash-notes" }) else {
            return "file clip missing after replace"
        }
        if files.filePaths != ["/tmp/Notes.txt"] || files.fileBookmarks != [Data([0x0A, 0x0B])] {
            return "file clip changed"
        }
        guard let image = restored.items.first(where: { $0.id == imageID }) else {
            return "image id changed"
        }
        let imageURL = restored.payloadsDir.appendingPathComponent("\(imageID.uuidString).png")
        if (try? Data(contentsOf: imageURL)) != pngRed { return "restored image bytes differ" }
        if image.imagePNGData != nil { return "restored image kept inline bytes" }

        restored.add(sampleItem(
            id: UUID(),
            createdAt: stamp.addingTimeInterval(30),
            kind: .text,
            preview: "local only",
            text: "local only",
            contentHash: "hash-local"
        ))
        let merge: HistoryImportResult
        do {
            merge = try restored.importHistory(exported, mode: .merge)
        } catch {
            return "merge failed: \(error.localizedDescription)"
        }
        if merge.skippedDuplicates != 3 { return "merge skipped \(merge.skippedDuplicates)" }
        if merge.added != 0 { return "merge added \(merge.added)" }
        if restored.items.contains(where: { $0.contentHash == "hash-local" }) == false {
            return "merge dropped the local clip"
        }

        let clobber = HistoryStore(storageDirectory: root.appendingPathComponent("clobber"), settings: .default)
        clobber.add(sampleItem(
            id: imageID,
            createdAt: stamp,
            kind: .image,
            preview: "red",
            imagePNGData: pngRed,
            contentHash: "hash-red"
        ))
        let incoming = sampleItem(
            id: imageID,
            createdAt: stamp.addingTimeInterval(5),
            kind: .image,
            preview: "black",
            imagePNGData: pngBlack,
            contentHash: "hash-black"
        )
        let incomingArchive: HistoryArchive
        do {
            incomingArchive = try HistoryArchive.build(
                items: [incoming],
                loadPayload: { _ in nil },
                exportedAt: stamp,
                appVersion: "1.2.0"
            )
            _ = try clobber.importHistory(incomingArchive, mode: .merge)
        } catch {
            return "clobber merge failed: \(error.localizedDescription)"
        }
        let originalURL = clobber.payloadsDir.appendingPathComponent("\(imageID.uuidString).png")
        if (try? Data(contentsOf: originalURL)) != pngRed {
            return "merge overwrote an existing image"
        }
        guard let added = clobber.items.first(where: { $0.contentHash == "hash-black" }) else {
            return "merged image clip missing"
        }
        if added.id == imageID { return "merged clip reused an existing id" }
        guard let addedName = added.imagePayloadName else { return "merged image has no payload" }
        if addedName == "\(imageID.uuidString).png" { return "merged image reused the existing payload name" }
        if (try? Data(contentsOf: clobber.payloadsDir.appendingPathComponent(addedName))) != pngBlack {
            return "merged image bytes missing"
        }

        let wiped = HistoryStore(storageDirectory: root.appendingPathComponent("wiped"), settings: .default)
        wiped.add(sampleItem(
            id: imageID,
            createdAt: stamp,
            kind: .image,
            preview: "red",
            imagePNGData: pngRed,
            contentHash: "hash-red"
        ))
        let textOnly = sampleItem(
            id: UUID(uuidString: "ABABABAB-CDCD-EFEF-1212-343434343434")!,
            createdAt: stamp,
            kind: .text,
            preview: "only text",
            text: "only text",
            contentHash: "hash-only"
        )
        do {
            let archive = try HistoryArchive.build(
                items: [textOnly],
                loadPayload: { _ in nil },
                exportedAt: stamp,
                appVersion: "1.2.0"
            )
            _ = try wiped.importHistory(archive, mode: .replace)
        } catch {
            return "text replace failed: \(error.localizedDescription)"
        }
        if wiped.items.map(\.contentHash) != ["hash-only"] { return "replace did not match the file" }
        if FileManager.default.fileExists(atPath: wiped.payloadsDir.appendingPathComponent("\(imageID.uuidString).png").path) {
            return "replace left the old image on disk"
        }

        var limited = AppSettings.default
        limited.maxHistoryCount = 10
        let trimmedStore = HistoryStore(
            storageDirectory: root.appendingPathComponent("trimmed"),
            settings: limited
        )
        var many: [ClipboardItem] = []
        for index in 0..<12 {
            many.append(sampleItem(
                id: UUID(),
                createdAt: stamp.addingTimeInterval(TimeInterval(index)),
                kind: .text,
                preview: "u\(index)",
                text: "u\(index)",
                contentHash: "hash-u\(index)"
            ))
        }
        many.append(sampleItem(
            id: UUID(uuidString: "FEDCBA98-7654-3210-FEDC-BA9876543210")!,
            createdAt: stamp.addingTimeInterval(-10_000),
            isPinned: true,
            kind: .text,
            preview: "keep pinned",
            text: "keep pinned",
            contentHash: "hash-keep"
        ))
        let trimResult: HistoryImportResult
        do {
            let archive = try HistoryArchive.build(
                items: many,
                loadPayload: { _ in nil },
                exportedAt: stamp,
                appVersion: "1.2.0"
            )
            trimResult = try trimmedStore.importHistory(archive, mode: .replace)
        } catch {
            return "trim import failed: \(error.localizedDescription)"
        }
        if trimResult.trimmed != 2 { return "trimmed \(trimResult.trimmed)" }
        if trimmedStore.items.count != 11 { return "trim left \(trimmedStore.items.count)" }
        if trimmedStore.items.contains(where: { $0.contentHash == "hash-keep" && $0.isPinned }) == false {
            return "trim dropped the pinned clip"
        }
        if trimmedStore.items.contains(where: { $0.contentHash == "hash-u0" }) {
            return "trim kept the oldest unpinned clip"
        }
        if trimmedStore.items.contains(where: { $0.contentHash == "hash-u11" }) == false {
            return "trim dropped a newest unpinned clip"
        }
        return nil
    }

    private static func sharedPayloadSurvivesRemoval() -> String? {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipkeep-shared-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sharedID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let otherID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let pinnedID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        let name = "\(sharedID.uuidString).png"
        let pinned = sampleItem(
            id: pinnedID,
            createdAt: stamp,
            isPinned: true,
            kind: .image,
            preview: "pinned",
            imagePayloadName: name,
            contentHash: "hash-shared-pinned"
        )
        let loose = sampleItem(
            id: otherID,
            createdAt: stamp.addingTimeInterval(10),
            kind: .image,
            preview: "loose",
            imagePayloadName: name,
            contentHash: "hash-shared-loose"
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent("Payloads", isDirectory: true),
                withIntermediateDirectories: true
            )
            try pngRed.write(to: root.appendingPathComponent("Payloads").appendingPathComponent(name))
            try encoder.encode([pinned, loose]).write(to: root.appendingPathComponent("history.json"))
        } catch {
            return "could not plant a shared image: \(error.localizedDescription)"
        }

        let store = HistoryStore(storageDirectory: root, settings: .default)
        guard store.items.count == 2 else { return "shared image changed the clip count" }
        let payload = store.payloadsDir.appendingPathComponent(name)
        store.clearUnpinned()
        guard store.items.count == 1, store.items[0].id == pinnedID else {
            return "clear unpinned removed the pinned clip"
        }
        guard (try? Data(contentsOf: payload)) == pngRed else { return "clear unpinned deleted the pinned image" }

        let again = sampleItem(
            id: otherID,
            createdAt: stamp.addingTimeInterval(20),
            kind: .image,
            preview: "loose again",
            imagePayloadName: name,
            contentHash: "hash-shared-again"
        )
        store.add(again)
        guard store.items.count == 2 else { return "shared image was not added again" }
        store.remove(otherID)
        guard store.items.count == 1, store.items[0].id == pinnedID else { return "remove dropped the other shared clip" }
        guard (try? Data(contentsOf: payload)) == pngRed else { return "remove deleted the image still in use" }
        guard store.imageData(for: store.items[0]) == pngRed else { return "remaining clip lost its image" }

        var tight = AppSettings.default
        tight.maxPayloadStorageMB = 1
        let budgetRoot = root.appendingPathComponent("budget", isDirectory: true)
        let heavy = paddedPNG(1_200 * 1024)
        let heavyName = "\(sharedID.uuidString).png"
        let first = sampleItem(
            id: sharedID,
            createdAt: stamp,
            kind: .image,
            preview: "one",
            imagePayloadName: heavyName,
            contentHash: "hash-heavy-one"
        )
        let second = sampleItem(
            id: otherID,
            createdAt: stamp.addingTimeInterval(5),
            kind: .image,
            preview: "two",
            imagePayloadName: heavyName,
            contentHash: "hash-heavy-two"
        )
        do {
            try FileManager.default.createDirectory(at: budgetRoot, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(
                at: budgetRoot.appendingPathComponent("Payloads", isDirectory: true),
                withIntermediateDirectories: true
            )
            try heavy.write(
                to: budgetRoot.appendingPathComponent("Payloads").appendingPathComponent(heavyName)
            )
            try encoder.encode([first, second]).write(to: budgetRoot.appendingPathComponent("history.json"))
        } catch {
            return "could not plant a shared image over the budget: \(error.localizedDescription)"
        }
        let budgetStore = HistoryStore(storageDirectory: budgetRoot, settings: tight)
        guard budgetStore.items.count == 2 else {
            return "budget removed a shared image that is still in use (\(budgetStore.items.count) left)"
        }
        guard FileManager.default.fileExists(
            atPath: budgetStore.payloadsDir.appendingPathComponent(heavyName).path
        ) else { return "budget deleted the shared image" }
        return nil
    }

    private static func repeatedCopyKeepsImageWhenSaveFails() -> String? {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipkeep-inline-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = HistoryStore(storageDirectory: root, settings: .default)
        do {
            try FileManager.default.removeItem(at: store.payloadsDir)
            try Data("not a directory".utf8).write(to: store.payloadsDir)
        } catch {
            return "could not block payload saves: \(error.localizedDescription)"
        }
        let first = sampleItem(
            id: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
            createdAt: stamp,
            kind: .image,
            preview: "pixel",
            imagePNGData: pngRed,
            contentHash: "hash-inline-repeat"
        )
        let second = sampleItem(
            id: UUID(uuidString: "55555555-5555-5555-5555-555555555555")!,
            createdAt: stamp.addingTimeInterval(5),
            kind: .image,
            preview: "pixel",
            imagePNGData: pngRed,
            contentHash: "hash-inline-repeat"
        )
        store.add(first)
        guard store.items.count == 1 else { return "first image was not kept" }
        guard store.imageData(for: store.items[0]) == pngRed else { return "failed save dropped the image" }
        store.add(second)
        guard store.items.count == 1 else { return "repeat created a second clip" }
        guard store.imageData(for: store.items[0]) == pngRed else { return "repeat dropped the image" }
        guard store.items[0].id == first.id else { return "repeat replaced the original clip" }
        return nil
    }

    private static func unsafePayloadNameStaysInsidePayloads() -> String? {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipkeep-escape-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let secret = root.appendingPathComponent("secret.png")
        let item = sampleItem(
            id: UUID(uuidString: "66666666-6666-6666-6666-666666666666")!,
            createdAt: stamp,
            kind: .image,
            preview: "escape",
            imagePayloadName: "../secret.png",
            contentHash: "hash-escape"
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try Data("keep-me".utf8).write(to: secret)
            try encoder.encode([item]).write(to: root.appendingPathComponent("history.json"))
        } catch {
            return "could not plant an unsafe payload name: \(error.localizedDescription)"
        }
        let store = HistoryStore(storageDirectory: root, settings: .default)
        guard (try? Data(contentsOf: secret)) == Data("keep-me".utf8) else {
            return "opening history changed a file outside Payloads"
        }
        guard store.items.count == 1 else { return "unsafe payload name dropped the clip" }
        guard store.items[0].imagePayloadName == nil else { return "unsafe payload name was kept" }
        guard store.imageData(for: store.items[0]) == nil else { return "unsafe payload name was read" }
        store.remove(item.id)
        guard (try? Data(contentsOf: secret)) == Data("keep-me".utf8) else {
            return "remove deleted a file outside Payloads"
        }
        return nil
    }

    private static func copyLeavesClipboardWhenClipIsEmpty() -> String? {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("ClipKeepSelfTest.\(UUID().uuidString)"))
        pasteboard.clearContents()
        guard pasteboard.setString("sentinel", forType: .string) else { return "could not prepare a pasteboard" }
        let monitor = ClipboardMonitor()
        let missing = sampleItem(
            id: UUID(),
            createdAt: stamp,
            kind: .files,
            preview: "gone.txt",
            filePaths: ["/tmp/clipkeep-no-such-file-\(UUID().uuidString)"],
            contentHash: "hash-missing-file"
        )
        if monitor.write(missing, to: pasteboard) {
            return "missing file was written to the pasteboard"
        }
        guard pasteboard.string(forType: .string) == "sentinel" else {
            return "copying a missing file cleared the clipboard"
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipkeep-copy-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let picture = root.appendingPathComponent("A.png")
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try pngRed.write(to: picture)
        } catch {
            return "could not write an image to copy: \(error.localizedDescription)"
        }
        let image = sampleItem(
            id: UUID(),
            createdAt: stamp,
            kind: .image,
            preview: "A.png",
            imagePNGData: pngRed,
            filePaths: [picture.path],
            contentHash: "hash-copy-image"
        )
        guard monitor.write(image, to: pasteboard) else { return "image clip was not copied" }
        guard pasteboard.data(forType: .png) == pngRed else { return "copied image lost its PNG" }
        let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []
        guard urls.first?.path == picture.path else { return "copied image lost its file" }
        return nil
    }

    private static func paddedPNG(_ bytes: Int) -> Data {
        var data = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        if bytes > data.count {
            data.append(Data(repeating: 0, count: bytes - data.count))
        }
        return data
    }

    private static func sampleItem(
        id: UUID,
        createdAt: Date,
        isPinned: Bool = false,
        kind: ClipboardContentKind,
        preview: String,
        sourceBundleID: String? = nil,
        sourceAppName: String? = nil,
        text: String? = nil,
        imagePayloadName: String? = nil,
        imagePNGData: Data? = nil,
        filePaths: [String] = [],
        fileBookmarks: [Data] = [],
        contentHash: String
    ) -> ClipboardItem {
        ClipboardItem(
            id: id,
            createdAt: createdAt,
            isPinned: isPinned,
            kind: kind,
            preview: preview,
            sourceBundleID: sourceBundleID,
            sourceAppName: sourceAppName,
            text: text,
            imagePayloadName: imagePayloadName,
            imagePNGData: imagePNGData,
            filePaths: filePaths,
            fileBookmarks: fileBookmarks,
            contentHash: contentHash
        )
    }

    private static func payloadNames(in directory: URL) -> [String] {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else { return [] }
        return urls.map(\.lastPathComponent).sorted()
    }

    private static func rawContainer(version: UInt16 = 1, files: [(String, Data)]) -> Data {
        var data = Data("CKH1".utf8)
        func appendUInt16(_ value: UInt16) {
            data.append(UInt8(value & 0xff))
            data.append(UInt8(value >> 8))
        }
        func appendUInt32(_ value: UInt32) {
            var rest = value
            for _ in 0..<4 {
                data.append(UInt8(rest & 0xff))
                rest >>= 8
            }
        }
        func appendUInt64(_ value: UInt64) {
            var rest = value
            for _ in 0..<8 {
                data.append(UInt8(rest & 0xff))
                rest >>= 8
            }
        }
        appendUInt16(version)
        appendUInt16(0)
        appendUInt32(UInt32(files.count))
        for file in files {
            let path = Data(file.0.utf8)
            appendUInt16(UInt16(path.count))
            data.append(path)
            appendUInt64(UInt64(file.1.count))
            data.append(file.1)
        }
        return data
    }

    /// 1×1 red PNG.
    private static let pngRed = Data(
        base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFBQIAX8jx0gAAAABJRU5ErkJggg=="
    )!
    /// 1×1 black PNG.
    private static let pngBlack = Data(
        base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
    )!
}
