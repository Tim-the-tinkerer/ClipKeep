import AppKit
import Foundation

/// Persists clipboard history metadata as JSON; image bytes live under Payloads/.
@MainActor
final class HistoryStore: ObservableObject {
    @Published private(set) var items: [ClipboardItem] = []
    @Published var settings: AppSettings {
        didSet {
            settings.save()
            // Trimming must rewrite history.json so deleted payloads/items stay gone after relaunch.
            if applyLimits() {
                persist()
            }
            objectWillChange.send()
            NotificationCenter.default.post(name: .clipKeepSettingsChanged, object: nil)
        }
    }

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
        let payloads = dir.appendingPathComponent("Payloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: payloads, withIntermediateDirectories: true)
        self.rootDir = dir
        self.fileURL = dir.appendingPathComponent("history.json")
        self.payloadsDir = payloads
        self.settings = AppSettings.load()
        load()
    }

    // MARK: - Public mutations

    func add(_ item: ClipboardItem) {
        let item = externalizeImageIfNeeded(item)

        // Move identical content to top instead of duplicating (keep pin if any).
        if let existingIndex = items.firstIndex(where: { $0.contentHash == item.contentHash }) {
            var existing = items.remove(at: existingIndex)
            // Prefer existing payload; drop unused new payload if any
            if existing.imagePayloadName != item.imagePayloadName,
               let newName = item.imagePayloadName {
                deletePayloadFile(named: newName)
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
                imagePayloadName: existing.imagePayloadName ?? item.imagePayloadName,
                imagePNGData: nil,
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
            deletePayloadFile(named: name)
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
            if let name = item.imagePayloadName { deletePayloadFile(named: name) }
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
        if let name = item.imagePayloadName {
            let url = payloadsDir.appendingPathComponent(name)
            if let data = try? Data(contentsOf: url) { return data }
        }
        return item.imagePNGData
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

    /// Applies item-count and payload-byte limits. Returns whether `items` or payloads changed.
    @discardableResult
    private func applyLimits() -> Bool {
        var changed = false
        if trimItemCount() { changed = true }
        if trimPayloadStorage() { changed = true }
        return changed
    }

    private func externalizeImageIfNeeded(_ item: ClipboardItem) -> ClipboardItem {
        guard item.kind == .image,
              let data = item.imagePNGData,
              item.imagePayloadName == nil
        else {
            return item
        }
        let name = "\(item.id.uuidString).png"
        let url = payloadsDir.appendingPathComponent(name)
        do {
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
        let url = payloadsDir.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: url)
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
        guard let name = item.imagePayloadName else {
            return Int64(item.imagePNGData?.count ?? 0)
        }
        let url = payloadsDir.appendingPathComponent(name)
        if let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
           let size = values.fileSize {
            return Int64(size)
        }
        return 0
    }

    private func sortItems() {
        items = items.sorted { a, b in
            if a.isPinned != b.isPinned { return a.isPinned && !b.isPinned }
            return a.createdAt > b.createdAt
        }
    }

    /// Enforce max unpinned item count. Returns whether items were removed.
    @discardableResult
    private func trimItemCount() -> Bool {
        let limit = max(10, settings.maxHistoryCount)
        let pinned = items.filter(\.isPinned)
        var unpinned = items.filter { !$0.isPinned }
        guard unpinned.count > limit else {
            // Still normalize order
            let before = items
            items = pinned + unpinned
            sortItems()
            return before.map(\.id) != items.map(\.id)
        }

        let dropped = Array(unpinned.suffix(from: limit))
        for item in dropped {
            if let name = item.imagePayloadName { deletePayloadFile(named: name) }
            thumbnailCache.removeValue(forKey: item.id)
        }
        unpinned = Array(unpinned.prefix(limit))
        items = pinned + unpinned
        sortItems()
        return true
    }

    /// Drop oldest **unpinned items that free payload bytes** until under budget.
    /// Never removes pinned items. Never removes text-only clips that do not free image storage
    /// (deleting them cannot reduce the PNG total when pinned images alone exceed the budget).
    @discardableResult
    private func trimPayloadStorage() -> Bool {
        let budget = settings.maxPayloadStorageBytes
        guard budget > 0 else { return false }

        var total = payloadBytesOnDisk()
        guard total > budget else { return false }

        // Only candidates that free on-disk (or inline) image bytes.
        let unpinnedWithPayload = items
            .filter { !$0.isPinned && payloadSize(for: $0) > 0 }
            .sorted { $0.createdAt < $1.createdAt }

        var removedIDs = Set<UUID>()
        for item in unpinnedWithPayload {
            guard total > budget else { break }
            let size = payloadSize(for: item)
            if let name = item.imagePayloadName {
                deletePayloadFile(named: name)
            }
            total -= size
            removedIDs.insert(item.id)
            thumbnailCache.removeValue(forKey: item.id)
        }

        if !removedIDs.isEmpty {
            items = items.filter { !removedIDs.contains($0.id) }
            sortItems()
        }

        if total > budget {
            // Pinned (and any remaining) payload still over budget — keep text clips; do not delete them.
            NSLog(
                "ClipKeep: image storage still over budget (\(total) > \(budget) bytes); " +
                    "pinned or remaining payloads cannot be reduced further without removing text-only history"
            )
        }

        return !removedIDs.isEmpty
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
        if migrateInlineImagesToPayloads() {
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
            let data = try encoder.encode(items)
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            NSLog("ClipKeep: failed to save history: \(error.localizedDescription)")
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
