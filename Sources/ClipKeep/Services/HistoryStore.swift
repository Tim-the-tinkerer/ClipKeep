import AppKit
import Foundation

/// Persists clipboard history metadata as JSON; image bytes live under Payloads/.
@MainActor
final class HistoryStore: ObservableObject {
    @Published private(set) var items: [ClipboardItem] = []
    @Published var settings: AppSettings {
        didSet {
            if persistsSettings {
                settings.save()
            }
            // Trimming must rewrite history.json so deleted payloads/items stay gone after relaunch.
            if applyLimits() {
                persist()
            }
            objectWillChange.send()
            NotificationCenter.default.post(name: .clipKeepSettingsChanged, object: nil)
        }
    }

    private let persistsSettings: Bool
    private let rootDir: URL
    private let fileURL: URL
    let payloadsDir: URL
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// Small list-row previews; avoids decoding full PNG per body rebuild.
    private var thumbnailCache: [UUID: NSImage] = [:]
    private let thumbnailPixelSize = 72

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = support.appendingPathComponent("ClipKeep", isDirectory: true)
        self.persistsSettings = true
        self.rootDir = dir
        self.fileURL = dir.appendingPathComponent("history.json")
        self.payloadsDir = dir.appendingPathComponent("Payloads", isDirectory: true)
        self.settings = AppSettings.load()
        prepareDirectories()
        load()
    }

    /// Store rooted at `storageDirectory`. Does not read or write the user's settings.
    init(storageDirectory: URL, settings: AppSettings) {
        self.persistsSettings = false
        self.rootDir = storageDirectory
        self.fileURL = storageDirectory.appendingPathComponent("history.json")
        self.payloadsDir = storageDirectory.appendingPathComponent("Payloads", isDirectory: true)
        self.settings = settings
        prepareDirectories()
        load()
    }

    // MARK: - Public mutations

    func add(_ item: ClipboardItem) {
        let item = externalizeImageIfNeeded(item)

        // A repeated copy of the same content moves to the top. The pin and payload stay.
        // Finder image clips include the file path in the hash, so this only folds a repeated copy of that file.
        if let existingIndex = items.firstIndex(where: { $0.contentHash == item.contentHash }) {
            var existing = items.remove(at: existingIndex)
            // Keep a payload the clip already has. Adopt the new file only when the old clip has none.
            // Keep inline bytes when neither clip has a file, so a failed save does not drop the image.
            let keptName = existing.imagePayloadName ?? item.imagePayloadName
            let keptInline: Data? = keptName == nil ? (existing.imagePNGData ?? item.imagePNGData) : nil
            if let newName = item.imagePayloadName, newName != keptName {
                deletePayloadIfUnused(newName)
            }
            existing = ClipboardItem(
                id: existing.id,
                createdAt: Date(),
                isPinned: existing.isPinned,
                kind: existing.kind,
                preview: existing.preview,
                sourceBundleID: item.sourceBundleID ?? existing.sourceBundleID,
                sourceAppName: item.sourceAppName ?? existing.sourceAppName,
                text: existing.text,
                imagePayloadName: keptName,
                imagePNGData: keptInline,
                filePaths: existing.filePaths.isEmpty ? item.filePaths : existing.filePaths,
                fileBookmarks: existing.fileBookmarks.isEmpty ? item.fileBookmarks : existing.fileBookmarks,
                contentHash: existing.contentHash
            )
            items.insert(existing, at: 0)
            thumbnailCache.removeValue(forKey: existing.id)
            _ = applyLimits()
            persist()
            return
        }

        items.insert(item, at: 0)
        _ = applyLimits()
        persist()
    }

    /// Number of unpinned items (candidates for "clear unpinned").
    var unpinnedCount: Int {
        items.reduce(0) { $0 + ($1.isPinned ? 0 : 1) }
    }

    /// Number of pinned items (preserved by `clearUnpinned()`).
    var pinnedCount: Int {
        items.reduce(0) { $0 + ($1.isPinned ? 1 : 0) }
    }

    /// Total bytes of files in Payloads/.
    var payloadStorageBytes: Int64 {
        payloadBytesOnDisk()
    }

    /// True when on-disk payloads exceed the configured budget (e.g. pinned images alone).
    var isPayloadBudgetExceeded: Bool {
        let budget = settings.maxPayloadStorageBytes
        guard budget > 0 else { return false }
        return payloadBytesOnDisk() > budget
    }

    func togglePin(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        var updated = items
        updated[index].isPinned.toggle()
        items = updated
        sortItems()
        // Pinning can push budget over limit for unpinned images — re-apply limits, always save.
        _ = applyLimits()
        persist()
    }

    func remove(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        items = items.filter { $0.id != id }
        if let name = item.imagePayloadName {
            deletePayloadIfUnused(name)
        }
        thumbnailCache.removeValue(forKey: id)
        persist()
    }

    /// Removes every unpinned clip. Pinned clips are kept and stay pinned.
    func clearUnpinned() {
        let removed = items.filter { !$0.isPinned }
        let kept = items.filter(\.isPinned)
        guard kept.count != items.count else { return }
        items = kept
        for item in removed {
            if let name = item.imagePayloadName {
                deletePayloadIfUnused(name)
            }
            thumbnailCache.removeValue(forKey: item.id)
        }
        persist()
    }

    func clearAll() {
        guard !items.isEmpty else { return }
        for item in items {
            if let name = item.imagePayloadName { deletePayloadFile(named: name) }
        }
        items = []
        thumbnailCache.removeAll()
        // Best-effort wipe leftover payload files
        if let files = try? FileManager.default.contentsOfDirectory(at: payloadsDir, includingPropertiesForKeys: nil) {
            for url in files { try? FileManager.default.removeItem(at: url) }
        }
        persist()
    }

    func item(id: UUID) -> ClipboardItem? {
        items.first { $0.id == id }
    }

    func filtered(search: String) -> [ClipboardItem] {
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let sorted = items
        guard !q.isEmpty else { return sorted }
        return sorted.filter { item in
            item.preview.localizedCaseInsensitiveContains(q)
                || (item.text?.localizedCaseInsensitiveContains(q) ?? false)
                || (item.sourceAppName?.localizedCaseInsensitiveContains(q) ?? false)
                || item.kind.label.localizedCaseInsensitiveContains(q)
        }
    }

    /// Load PNG bytes for re-copy (full payload). Prefer `thumbnail(for:)` in list UI.
    func imageData(for item: ClipboardItem) -> Data? {
        if let name = item.imagePayloadName, let safe = safePayloadName(name) {
            let url = payloadsDir.appendingPathComponent(safe)
            if let data = try? Data(contentsOf: url) { return data }
        }
        return item.imagePNGData
    }

    // MARK: - History file (local)

    /// Snapshot of every current clip, including image payloads. Settings are not included.
    func makeHistoryArchive(exportedAt: Date = Date()) throws -> HistoryArchive {
        try HistoryArchive.build(
            items: items,
            loadPayload: { name in
                let safe = try HistoryArchive.validatePayloadName(name)
                let url = self.payloadsDir.appendingPathComponent(safe)
                guard FileManager.default.fileExists(atPath: url.path) else { return nil }
                do {
                    return try Data(contentsOf: url)
                } catch {
                    throw HistoryArchiveError.readFailed(error.localizedDescription)
                }
            },
            exportedAt: exportedAt,
            appVersion: AppVersion.short
        )
    }

    @discardableResult
    func exportHistory(to url: URL, exportedAt: Date = Date()) throws -> HistoryArchive {
        let archive = try makeHistoryArchive(exportedAt: exportedAt)
        try archive.write(to: url)
        return archive
    }

    /// Replace the current history, or add clips whose content is not already here.
    /// Payload files are written only after the archive has been checked.
    @discardableResult
    func importHistory(_ archive: HistoryArchive, mode: HistoryImportMode) throws -> HistoryImportResult {
        switch mode {
        case .replace:
            return try importReplacing(archive)
        case .merge:
            return try importMerging(archive)
        }
    }

    /// Cached 72px preview for list rows (does not keep full-resolution images in row views).
    func thumbnail(for item: ClipboardItem) -> NSImage? {
        guard item.kind == .image else { return nil }
        if let cached = thumbnailCache[item.id] {
            return cached
        }
        guard let data = imageData(for: item),
              let full = NSImage(data: data),
              let thumb = Self.makeThumbnail(from: full, maxPixel: thumbnailPixelSize)
        else {
            return nil
        }
        thumbnailCache[item.id] = thumb
        return thumb
    }

    // MARK: - Private

    private func prepareDirectories() {
        try? FileManager.default.createDirectory(at: rootDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: payloadsDir, withIntermediateDirectories: true)
    }

    private func importReplacing(_ archive: HistoryArchive) throws -> HistoryImportResult {
        let incoming = archive.items.map { withFinderIdentity($0, payloads: archive.payloads) }
        let trimmed = try commitHistory(
            incoming,
            payloads: archive.payloads,
            retargetIDs: Set(incoming.map(\.id))
        )
        return HistoryImportResult(
            mode: .replace,
            added: archive.items.count,
            skippedDuplicates: 0,
            trimmed: trimmed,
            resultingCount: items.count
        )
    }

    private func importMerging(_ archive: HistoryArchive) throws -> HistoryImportResult {
        let incoming = archive.items.map { withFinderIdentity($0, payloads: archive.payloads) }
        var kept = items
        var hashes = Set(kept.map(\.contentHash))
        var ids = Set(kept.map(\.id))
        var addedIDs = Set<UUID>()
        var added = 0
        var skipped = 0

        for item in incoming {
            if hashes.contains(item.contentHash) {
                skipped += 1
                continue
            }

            var placed = item
            if ids.contains(placed.id) {
                placed = placed.withIdentity(id: UUID(), imagePayloadName: placed.imagePayloadName)
            }
            hashes.insert(placed.contentHash)
            ids.insert(placed.id)
            kept.append(placed)
            addedIDs.insert(placed.id)
            added += 1
        }

        let trimmed = try commitHistory(kept, payloads: archive.payloads, retargetIDs: addedIDs)
        return HistoryImportResult(
            mode: .merge,
            added: added,
            skippedDuplicates: skipped,
            trimmed: trimmed,
            resultingCount: items.count
        )
    }

    /// Writes the new history only after its payloads are on disk.
    /// A failed `history.json` write deletes payloads created for this attempt and leaves the previous history in place.
    /// Payload names already used by the current history are never overwritten. Only `retargetIDs` may receive a new name.
    private func commitHistory(
        _ next: [ClipboardItem],
        payloads: [String: Data],
        retargetIDs: Set<UUID>
    ) throws -> Int {
        let protected = referencedPayloadNames()
        let created = CreatedPayloads()
        var committed = false
        defer {
            if !committed {
                for name in created.names where !protected.contains(name) {
                    deletePayloadFile(named: name)
                }
            }
        }

        let staged = try stagePayloads(
            next,
            payloads: payloads,
            retargetIDs: retargetIDs,
            protected: protected,
            created: created
        )
        let sorted = sortedItems(staged)
        let limited = limit(sorted)
        try writeHistory(limited.kept)
        committed = true

        let keptNames = Set(limited.kept.compactMap(\.imagePayloadName))
        for name in created.names where !keptNames.contains(name) && !protected.contains(name) {
            deletePayloadFile(named: name)
        }
        logPayloadBudget(limited)
        items = limited.kept
        thumbnailCache.removeAll()
        pruneOrphanPayloads()
        return sorted.count - limited.kept.count
    }

    /// Copies payload bytes for newly imported clips. An existing file, including one the current history still names, is left untouched.
    private func stagePayloads(
        _ next: [ClipboardItem],
        payloads: [String: Data],
        retargetIDs: Set<UUID>,
        protected: Set<String>,
        created: CreatedPayloads
    ) throws -> [ClipboardItem] {
        var assigned: [String: String] = [:]
        var staged: [ClipboardItem] = []
        staged.reserveCapacity(next.count)

        for item in next {
            guard retargetIDs.contains(item.id), let sourceName = item.imagePayloadName else {
                staged.append(item)
                continue
            }
            let safeSource = try HistoryArchive.validatePayloadName(sourceName)
            if let dest = assigned[safeSource] {
                staged.append(item.withIdentity(id: item.id, imagePayloadName: dest))
                continue
            }
            guard let data = payloads[safeSource] else {
                throw HistoryArchiveError.missingPayload(safeSource)
            }
            let destName = try unusedPayloadName(
                preferred: safeSource,
                protected: protected,
                taken: Set(assigned.values)
            )
            try writeNewPayload(data, name: destName)
            created.names.append(destName)
            assigned[safeSource] = destName
            staged.append(item.withIdentity(id: item.id, imagePayloadName: destName))
        }
        return staged
    }

    private func unusedPayloadName(
        preferred: String,
        protected: Set<String>,
        taken: Set<String>
    ) throws -> String {
        let preferredURL = payloadsDir.appendingPathComponent(preferred)
        if !protected.contains(preferred),
           !taken.contains(preferred),
           !FileManager.default.fileExists(atPath: preferredURL.path) {
            return preferred
        }
        for _ in 0..<8 {
            let name = "\(UUID().uuidString).png"
            let url = payloadsDir.appendingPathComponent(name)
            if !protected.contains(name), !taken.contains(name), !FileManager.default.fileExists(atPath: url.path) {
                return name
            }
        }
        throw HistoryArchiveError.writeFailed("could not choose an image name")
    }

    /// Writes a payload that is not already on disk. An existing file or symlink is left alone.
    private func writeNewPayload(_ data: Data, name: String) throws {
        let safe = try HistoryArchive.validatePayloadName(name)
        let dest = payloadsDir.appendingPathComponent(safe)
        if let values = try? dest.resourceValues(forKeys: [.isSymbolicLinkKey]),
           values.isSymbolicLink == true {
            throw HistoryArchiveError.writeFailed("refusing to replace a symlink payload")
        }
        if FileManager.default.fileExists(atPath: dest.path) {
            throw HistoryArchiveError.writeFailed("refusing to replace an existing image")
        }
        do {
            try FileManager.default.createDirectory(at: payloadsDir, withIntermediateDirectories: true)
            try data.write(to: dest, options: [.atomic])
        } catch {
            throw HistoryArchiveError.writeFailed(error.localizedDescription)
        }
    }

    /// Applies item-count and payload-byte limits. Returns whether `items` changed.
    /// The image budget counts payloads named by the items being kept, not every file in Payloads/.
    @discardableResult
    private func applyLimits() -> Bool {
        let limited = limit(items)
        logPayloadBudget(limited)
        let changed = limited.kept.map(\.id) != items.map(\.id)
        guard changed else { return false }
        let keptNames = Set(limited.kept.compactMap(\.imagePayloadName))
        for name in limited.droppedPayloads where !keptNames.contains(name) {
            deletePayloadFile(named: name)
        }
        for id in limited.droppedIDs {
            thumbnailCache.removeValue(forKey: id)
        }
        items = limited.kept
        return true
    }

    private func externalizeImageIfNeeded(_ item: ClipboardItem) -> ClipboardItem {
        guard item.kind == .image,
              let data = item.imagePNGData,
              item.imagePayloadName == nil
        else {
            return item
        }
        guard let name = allocatePayloadName(preferred: "\(item.id.uuidString).png") else {
            return item
        }
        let url = payloadsDir.appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(at: payloadsDir, withIntermediateDirectories: true)
            try data.write(to: url, options: [.atomic])
            var copy = item
            copy.imagePayloadName = name
            copy.imagePNGData = nil
            return copy
        } catch {
            NSLog("ClipKeep: failed to write payload \(name): \(error.localizedDescription)")
            return item
        }
    }

    /// A name another clip already uses is left alone. The new bytes go to a fresh file instead.
    private func allocatePayloadName(preferred: String) -> String? {
        if let safe = safePayloadName(preferred),
           !items.contains(where: { $0.imagePayloadName == safe }) {
            return safe
        }
        for _ in 0..<8 {
            let name = "\(UUID().uuidString).png"
            if safePayloadName(name) != nil,
               !items.contains(where: { $0.imagePayloadName == name }) {
                return name
            }
        }
        return nil
    }

    /// A single copied image file used to be stored as a path only. Copy its bytes into Payloads
    /// when the file is still readable, and keep the path so it can still be pasted as a file.
    private func snapshotImageFiles() -> Bool {
        guard settings.captureImages else { return false }
        var changed = false
        var next: [ClipboardItem] = []
        next.reserveCapacity(items.count)
        for item in items {
            guard item.kind == .files,
                  item.imagePayloadName == nil,
                  item.imagePNGData == nil,
                  item.filePaths.count == 1,
                  let path = item.filePaths.first
            else {
                next.append(item)
                continue
            }
            let access = item.resolveFiles()
            let url = access.urls.first ?? URL(fileURLWithPath: path)
            let png = ImageCapture.isImageFile(url) ? ImageCapture.pngData(contentsOf: url) : nil
            access.endAccess()
            guard let png else {
                next.append(item)
                continue
            }
            let image = ClipboardItem(
                id: item.id,
                createdAt: item.createdAt,
                isPinned: item.isPinned,
                kind: .image,
                preview: item.preview,
                sourceBundleID: item.sourceBundleID,
                sourceAppName: item.sourceAppName,
                text: item.text,
                imagePNGData: png,
                filePaths: item.filePaths,
                fileBookmarks: item.fileBookmarks,
                contentHash: ImageCapture.contentHash(png: png, filePaths: item.filePaths)
            )
            next.append(externalizeImageIfNeeded(image))
            changed = true
        }
        if changed {
            items = next
        }
        return changed
    }

    /// Migrates legacy Base64-in-JSON images to Payloads/. Returns whether any item changed.
    @discardableResult
    private func migrateInlineImagesToPayloads() -> Bool {
        var changed = false
        var migrated: [ClipboardItem] = []
        for item in items {
            if item.kind == .image, item.imagePNGData != nil, item.imagePayloadName == nil {
                migrated.append(externalizeImageIfNeeded(item))
                changed = true
            } else {
                migrated.append(item)
            }
        }
        if changed {
            items = migrated
        }
        return changed
    }

    private func deletePayloadFile(named name: String) {
        guard let safe = safePayloadName(name) else { return }
        let url = payloadsDir.appendingPathComponent(safe)
        try? FileManager.default.removeItem(at: url)
    }

    /// Deletes a payload file only after the last clip that names it is gone.
    private func deletePayloadIfUnused(_ name: String) {
        guard !items.contains(where: { $0.imagePayloadName == name }) else { return }
        deletePayloadFile(named: name)
    }

    /// Payload files are `<uuid>.png` inside Payloads/. Anything else is ignored so a history file cannot name a path outside that folder.
    private func safePayloadName(_ name: String) -> String? {
        guard let safe = try? HistoryArchive.validatePayloadName(name), safe == name else { return nil }
        return safe
    }

    private func referencedPayloadNames() -> Set<String> {
        Set(items.compactMap(\.imagePayloadName))
    }

    private func pruneOrphanPayloads() {
        let keep = referencedPayloadNames()
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: payloadsDir,
            includingPropertiesForKeys: nil
        ) else { return }
        for url in files {
            if !keep.contains(url.lastPathComponent) {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    private func payloadBytesOnDisk() -> Int64 {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: payloadsDir,
            includingPropertiesForKeys: [.fileSizeKey]
        ) else { return 0 }
        var total: Int64 = 0
        for url in files {
            if let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
               let size = values.fileSize {
                total += Int64(size)
            }
        }
        return total
    }

    private func payloadSize(for item: ClipboardItem) -> Int64 {
        if let name = item.imagePayloadName {
            guard safePayloadName(name) != nil else {
                return Int64(item.imagePNGData?.count ?? 0)
            }
            let size = payloadFileSize(named: name)
            if size > 0 { return size }
        }
        return Int64(item.imagePNGData?.count ?? 0)
    }

    private func sortItems() {
        items = sortedItems(items)
    }

    private func sortedItems(_ list: [ClipboardItem]) -> [ClipboardItem] {
        list.sorted { a, b in
            if a.isPinned != b.isPinned { return a.isPinned && !b.isPinned }
            return a.createdAt > b.createdAt
        }
    }

    /// Item-count trim, then the image budget. Does not delete files.
    /// Pinned clips stay. Text-only clips stay when removing them would not free image bytes.
    /// The budget is the sum of payloads these items name, counted once per file.
    private func limit(_ source: [ClipboardItem]) -> LimitedHistory {
        let sorted = sortedItems(source)
        var droppedIDs = Set<UUID>()
        var droppedPayloads: [String] = []

        let cap = max(10, settings.maxHistoryCount)
        let pinned = sorted.filter(\.isPinned)
        var unpinned = sorted.filter { !$0.isPinned }
        if unpinned.count > cap {
            for item in unpinned.suffix(from: cap) {
                droppedIDs.insert(item.id)
                if let name = item.imagePayloadName {
                    droppedPayloads.append(name)
                }
            }
            unpinned = Array(unpinned.prefix(cap))
        }

        var kept = sortedItems(pinned + unpinned)
        let budget = settings.maxPayloadStorageBytes
        var total = referencedPayloadBytes(kept)
        var stillOver = false
        if budget > 0, total > budget {
            var shares: [String: Int] = [:]
            for item in kept {
                if let name = item.imagePayloadName {
                    shares[name, default: 0] += 1
                }
            }
            let candidates = kept
                .filter { !$0.isPinned && payloadSize(for: $0) > 0 }
                .sorted { $0.createdAt < $1.createdAt }
            for item in candidates {
                guard total > budget else { break }
                let freed: Int64
                if let name = item.imagePayloadName {
                    // A file another clip still names is not freed by removing this one.
                    guard shares[name] == 1 else { continue }
                    freed = payloadFileSize(named: name)
                    guard freed > 0 else { continue }
                    shares[name] = 0
                } else {
                    freed = Int64(item.imagePNGData?.count ?? 0)
                    guard freed > 0 else { continue }
                }
                droppedIDs.insert(item.id)
                if let name = item.imagePayloadName {
                    droppedPayloads.append(name)
                }
                total -= freed
            }
            kept = sortedItems(kept.filter { !droppedIDs.contains($0.id) })
            total = referencedPayloadBytes(kept)
            stillOver = total > budget
        }
        return LimitedHistory(
            kept: kept,
            droppedIDs: droppedIDs,
            droppedPayloads: droppedPayloads,
            stillOverBudget: stillOver,
            referencedBytes: total
        )
    }

    /// Sum of payload files named by `list`, plus inline PNG bytes. Each file counts once.
    private func referencedPayloadBytes(_ list: [ClipboardItem]) -> Int64 {
        var seen = Set<String>()
        var total: Int64 = 0
        for item in list {
            if let name = item.imagePayloadName {
                if seen.insert(name).inserted {
                    total += payloadFileSize(named: name)
                }
            } else {
                total += Int64(item.imagePNGData?.count ?? 0)
            }
        }
        return total
    }

    private func payloadFileSize(named name: String) -> Int64 {
        guard let name = safePayloadName(name) else { return 0 }
        let url = payloadsDir.appendingPathComponent(name)
        if let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
           values.isRegularFile != false,
           let size = values.fileSize {
            return Int64(size)
        }
        return 0
    }

    private func logPayloadBudget(_ limited: LimitedHistory) {
        guard limited.stillOverBudget else { return }
        let budget = settings.maxPayloadStorageBytes
        NSLog(
            "ClipKeep: image storage still over budget (\(limited.referencedBytes) > \(budget) bytes); " +
                "pinned or remaining payloads cannot be reduced further without removing text-only history"
        )
    }

    /// Drop payload names that are not a UUID file in Payloads/. Inline bytes, if any, stay on the clip.
    private func neutralizeUnsafePayloadNames() -> Bool {
        var changed = false
        var next: [ClipboardItem] = []
        next.reserveCapacity(items.count)
        for item in items {
            guard let name = item.imagePayloadName, safePayloadName(name) == nil else {
                next.append(item)
                continue
            }
            var copy = item
            copy.imagePayloadName = nil
            next.append(copy)
            changed = true
        }
        if changed {
            items = next
        }
        return changed
    }

    /// An older image clip stored the PNG hash only. A Finder path is part of the identity, so reload it that way.
    private func rehashFinderImages() -> Bool {
        var changed = false
        var next: [ClipboardItem] = []
        next.reserveCapacity(items.count)
        for item in items {
            guard item.kind == .image,
                  !item.filePaths.isEmpty,
                  !item.contentHash.hasPrefix("file:"),
                  let png = imageData(for: item)
            else {
                next.append(item)
                continue
            }
            let hash = ImageCapture.contentHash(png: png, filePaths: item.filePaths)
            guard hash != item.contentHash else {
                next.append(item)
                continue
            }
            next.append(item.withContentHash(hash))
            changed = true
        }
        if changed {
            items = next
        }
        return changed
    }

    /// Give an imported Finder image the same hash a new capture of that file would get.
    private func withFinderIdentity(_ item: ClipboardItem, payloads: [String: Data]) -> ClipboardItem {
        guard item.kind == .image,
              !item.filePaths.isEmpty,
              !item.contentHash.hasPrefix("file:")
        else {
            return item
        }
        let png: Data?
        if let name = item.imagePayloadName {
            png = payloads[name] ?? item.imagePNGData
        } else {
            png = item.imagePNGData
        }
        guard let png else { return item }
        return item.withContentHash(ImageCapture.contentHash(png: png, filePaths: item.filePaths))
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL),
              let decoded = try? decoder.decode([ClipboardItem].self, from: data)
        else {
            items = []
            return
        }
        items = decoded
        sortItems()
        var needsPersist = false
        if neutralizeUnsafePayloadNames() {
            needsPersist = true
        }
        if migrateInlineImagesToPayloads() {
            needsPersist = true
        }
        if snapshotImageFiles() {
            needsPersist = true
        }
        if rehashFinderImages() {
            needsPersist = true
        }
        if applyLimits() {
            needsPersist = true
        }
        pruneOrphanPayloads()
        if needsPersist {
            persist()
        }
    }

    private func persist() {
        do {
            try writeHistory(items)
        } catch {
            NSLog("ClipKeep: failed to save history: \(error.localizedDescription)")
        }
    }

    private func writeHistory(_ list: [ClipboardItem]) throws {
        do {
            let data = try encoder.encode(list)
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            throw HistoryArchiveError.writeFailed(error.localizedDescription)
        }
    }

    private static func makeThumbnail(from image: NSImage, maxPixel: Int) -> NSImage? {
        let target = CGFloat(maxPixel)
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }
        let scale = min(target / size.width, target / size.height, 1.0)
        let newSize = NSSize(width: max(1, size.width * scale), height: max(1, size.height * scale))
        let thumb = NSImage(size: newSize)
        thumb.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .medium
        image.draw(
            in: NSRect(origin: .zero, size: newSize),
            from: NSRect(origin: .zero, size: size),
            operation: .copy,
            fraction: 1.0
        )
        thumb.unlockFocus()
        return thumb
    }
}

private extension ClipboardItem {
    func withIdentity(id: UUID, imagePayloadName: String?) -> ClipboardItem {
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
            imagePNGData: nil,
            filePaths: filePaths,
            fileBookmarks: fileBookmarks,
            contentHash: contentHash
        )
    }

    func withContentHash(_ contentHash: String) -> ClipboardItem {
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
}

/// Payload files created during an import. A class so a thrown error still reports names to roll back.
private final class CreatedPayloads {
    var names: [String] = []
}

private struct LimitedHistory {
    var kept: [ClipboardItem]
    var droppedIDs: Set<UUID>
    var droppedPayloads: [String]
    var stillOverBudget: Bool
    var referencedBytes: Int64
}
