import Foundation

/// Persists clipboard history to Application Support as JSON.
@MainActor
final class HistoryStore: ObservableObject {
    @Published private(set) var items: [ClipboardItem] = []
    @Published var settings: AppSettings {
        didSet {
            settings.save()
            trimToLimit()
            objectWillChange.send()
        }
    }

    private let fileURL: URL
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

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = support.appendingPathComponent("ClipKeep", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.fileURL = dir.appendingPathComponent("history.json")
        self.settings = AppSettings.load()
        load()
    }

    func add(_ item: ClipboardItem) {
        // Move identical content to top instead of duplicating (keep pin if any).
        if let existingIndex = items.firstIndex(where: { $0.contentHash == item.contentHash }) {
            var existing = items.remove(at: existingIndex)
            existing = ClipboardItem(
                id: existing.id,
                createdAt: Date(),
                isPinned: existing.isPinned,
                kind: existing.kind,
                preview: existing.preview,
                sourceBundleID: item.sourceBundleID ?? existing.sourceBundleID,
                sourceAppName: item.sourceAppName ?? existing.sourceAppName,
                text: existing.text,
                imagePNGData: existing.imagePNGData,
                filePaths: existing.filePaths,
                contentHash: existing.contentHash
            )
            items.insert(existing, at: 0)
            persist()
            return
        }

        items.insert(item, at: 0)
        trimToLimit()
        persist()
    }

    func togglePin(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].isPinned.toggle()
        // Keep pinned items near the top among their group
        sortItems()
        persist()
    }

    func remove(_ id: UUID) {
        items.removeAll { $0.id == id }
        persist()
    }

    func clearUnpinned() {
        items.removeAll { !$0.isPinned }
        persist()
    }

    func clearAll() {
        items.removeAll()
        persist()
    }

    func item(id: UUID) -> ClipboardItem? {
        items.first { $0.id == id }
    }

    func filtered(search: String) -> [ClipboardItem] {
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let sorted = items // already pinned-first
        guard !q.isEmpty else { return sorted }
        return sorted.filter { item in
            item.preview.localizedCaseInsensitiveContains(q)
                || (item.text?.localizedCaseInsensitiveContains(q) ?? false)
                || (item.sourceAppName?.localizedCaseInsensitiveContains(q) ?? false)
                || item.kind.label.localizedCaseInsensitiveContains(q)
        }
    }

    // MARK: - Private

    private func sortItems() {
        items.sort { a, b in
            if a.isPinned != b.isPinned { return a.isPinned && !b.isPinned }
            return a.createdAt > b.createdAt
        }
    }

    private func trimToLimit() {
        let limit = max(10, settings.maxHistoryCount)
        let pinned = items.filter(\.isPinned)
        var unpinned = items.filter { !$0.isPinned }
        if unpinned.count > limit {
            unpinned = Array(unpinned.prefix(limit))
        }
        items = pinned + unpinned
        sortItems()
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
        trimToLimit()
    }

    private func persist() {
        do {
            let data = try encoder.encode(items)
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            NSLog("ClipKeep: failed to save history: \(error.localizedDescription)")
        }
    }
}
