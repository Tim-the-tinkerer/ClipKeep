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
        case .richText: return "Rich Text"
        case .image: return "Image"
        case .files: return "Files"
        case .unknown: return "Other"
        }
    }
}

struct ClipboardItem: Identifiable, Codable, Equatable, Hashable {
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
    /// PNG image bytes when kind is image.
    let imagePNGData: Data?
    /// File URLs (bookmark data preferred for persistence).
    let filePaths: [String]
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
        imagePNGData: Data? = nil,
        filePaths: [String] = [],
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
        self.imagePNGData = imagePNGData
        self.filePaths = filePaths
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

    private static let relativeDateFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()
}
