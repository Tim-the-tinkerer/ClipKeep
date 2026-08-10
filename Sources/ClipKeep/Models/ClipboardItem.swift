import AppKit
import Foundation

enum ClipboardContentKind: String, Codable, CaseIterable, Identifiable {
    case text
    case richText
    case image
    case files
    case unknown

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .text: return "doc.plaintext"
        case .richText: return "doc.richtext"
        case .image: return "photo"
        case .files: return "doc.on.doc"
        case .unknown: return "questionmark.square"
        }
    }

    var label: String {
        switch self {
        case .text: return "Text"
        case .richText: return "Rich Text (plain)"
        case .image: return "Image"
        case .files: return "Files"
        case .unknown: return "Other"
        }
    }
}

struct ClipboardItem: Identifiable, Equatable, Hashable {
    let id: UUID
    let createdAt: Date
    var isPinned: Bool
    let kind: ClipboardContentKind
    /// Plain preview for list UI and search.
    let preview: String
    /// Source app bundle identifier when known.
    let sourceBundleID: String?
    /// Source app display name when known.
    let sourceAppName: String?
    /// UTF-8 text payload (plain or RTF decoded to plain for storage simplicity).
    let text: String?
    /// Relative filename under Application Support/ClipKeep/Payloads/ (e.g. `<uuid>.png`).
    var imagePayloadName: String?
    /// In-memory / legacy inline PNG. Prefer `imagePayloadName` on disk; not re-encoded when a payload name is set.
    var imagePNGData: Data?
    /// Display paths (last-path components used in UI).
    var filePaths: [String]
    /// Security-scoped bookmark blobs aligned with `filePaths` (empty if unavailable).
    var fileBookmarks: [Data]
    /// Content fingerprint used to avoid duplicate consecutive entries.
    let contentHash: String

    init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
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
    ) {
        self.id = id
        self.createdAt = createdAt
        self.isPinned = isPinned
        self.kind = kind
        self.preview = preview
        self.sourceBundleID = sourceBundleID
        self.sourceAppName = sourceAppName
        self.text = text
        self.imagePayloadName = imagePayloadName
        self.imagePNGData = imagePNGData
        self.filePaths = filePaths
        self.fileBookmarks = fileBookmarks
        self.contentHash = contentHash
    }

    var displayTitle: String {
        let trimmed = preview.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return kind.label
        }
        let singleLine = trimmed
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        if singleLine.count <= 120 {
            return singleLine
        }
        return String(singleLine.prefix(117)) + "…"
    }

    var subtitle: String {
        var parts: [String] = [kind.label]
        if let sourceAppName, !sourceAppName.isEmpty {
            parts.append(sourceAppName)
        }
        parts.append(Self.relativeDateFormatter.localizedString(for: createdAt, relativeTo: Date()))
        return parts.joined(separator: " · ")
    }

    /// Approximate on-disk size contribution of this item (payloads + bookmarks + text).
    var approximateByteSize: Int {
        var total = (text?.utf8.count ?? 0)
        total += imagePNGData?.count ?? 0
        for b in fileBookmarks { total += b.count }
        for p in filePaths { total += p.utf8.count }
        // Payload files counted separately by store when known; inline only here.
        return total
    }

    private static let relativeDateFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()
}

// MARK: - Codable (payload + bookmark aware, migration-friendly)

extension ClipboardItem: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, createdAt, isPinned, kind, preview
        case sourceBundleID, sourceAppName, text
        case imagePayloadName, imagePNGData
        case filePaths, fileBookmarks, contentHash
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        isPinned = try c.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        kind = try c.decode(ClipboardContentKind.self, forKey: .kind)
        preview = try c.decode(String.self, forKey: .preview)
        sourceBundleID = try c.decodeIfPresent(String.self, forKey: .sourceBundleID)
        sourceAppName = try c.decodeIfPresent(String.self, forKey: .sourceAppName)
        text = try c.decodeIfPresent(String.self, forKey: .text)
        imagePayloadName = try c.decodeIfPresent(String.self, forKey: .imagePayloadName)
        // Legacy Base64-in-JSON images
        imagePNGData = try c.decodeIfPresent(Data.self, forKey: .imagePNGData)
        filePaths = try c.decodeIfPresent([String].self, forKey: .filePaths) ?? []
        fileBookmarks = try c.decodeIfPresent([Data].self, forKey: .fileBookmarks) ?? []
        contentHash = try c.decode(String.self, forKey: .contentHash)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(isPinned, forKey: .isPinned)
        try c.encode(kind, forKey: .kind)
        try c.encode(preview, forKey: .preview)
        try c.encodeIfPresent(sourceBundleID, forKey: .sourceBundleID)
        try c.encodeIfPresent(sourceAppName, forKey: .sourceAppName)
        try c.encodeIfPresent(text, forKey: .text)
        try c.encodeIfPresent(imagePayloadName, forKey: .imagePayloadName)
        // Prefer external payload: do not re-embed large PNG once on disk.
        if imagePayloadName == nil {
            try c.encodeIfPresent(imagePNGData, forKey: .imagePNGData)
        }
        try c.encode(filePaths, forKey: .filePaths)
        try c.encode(fileBookmarks, forKey: .fileBookmarks)
        try c.encode(contentHash, forKey: .contentHash)
    }
}

// MARK: - File resolution

/// Result of resolving file clips; call `endAccess()` when finished (e.g. after pasteboard write).
struct ResolvedFileAccess {
    let urls: [URL]
    /// URLs for which `startAccessingSecurityScopedResource()` returned true.
    private let scopedURLs: [URL]

    init(urls: [URL], scopedURLs: [URL]) {
        self.urls = urls
        self.scopedURLs = scopedURLs
    }

    func endAccess() {
        for url in scopedURLs {
            url.stopAccessingSecurityScopedResource()
        }
    }
}

extension ClipboardItem {
    /// Resolve file clips using security-scoped bookmarks when available, else path.
    /// Caller **must** call `endAccess()` on the result when done (typically via `defer`).
    func resolveFiles() -> ResolvedFileAccess {
        var urls: [URL] = []
        var scoped: [URL] = []
        let count = max(filePaths.count, fileBookmarks.count)
        for i in 0..<count {
            let bookmark = i < fileBookmarks.count ? fileBookmarks[i] : nil
            let path = i < filePaths.count ? filePaths[i] : nil

            if let bookmark, !bookmark.isEmpty {
                var isStale = false
                if let url = try? URL(
                    resolvingBookmarkData: bookmark,
                    options: [.withSecurityScope],
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                ) {
                    let started = url.startAccessingSecurityScopedResource()
                    if FileManager.default.fileExists(atPath: url.path) {
                        urls.append(url)
                        if started { scoped.append(url) }
                        continue
                    }
                    if started {
                        url.stopAccessingSecurityScopedResource()
                    }
                }
            }
            if let path, FileManager.default.fileExists(atPath: path) {
                urls.append(URL(fileURLWithPath: path))
            }
        }
        return ResolvedFileAccess(urls: urls, scopedURLs: scoped)
    }

    static func bookmarks(for urls: [URL]) -> [Data] {
        urls.map { url in
            (try? url.bookmarkData(
                options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )) ?? Data()
        }
    }
}
