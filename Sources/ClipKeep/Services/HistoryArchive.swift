import Foundation
import UniformTypeIdentifiers

/// Local snapshot of the whole clipboard history.
///
/// CLIPKEEP/1 is one file (extension `.clipkeep`). Nothing in the file is sent anywhere.
/// Little-endian container, magic `CKH1`:
///
/// ```
/// magic          4 bytes  "CKH1"
/// version        uint16   1
/// reserved       uint16   0
/// entryCount     uint32
/// repeated entry:
///   pathLength   uint16
///   path         UTF-8 relative path
///   byteCount    uint64
///   bytes
/// ```
///
/// Required entries are `manifest.json` and `history.json` (the same item schema as the live store).
/// Image bytes are `payloads/<uuid>.png`. Settings are not included.
struct HistoryArchive: Equatable {
    static let formatID = "CLIPKEEP/1"
    static let containerVersion: UInt16 = 1
    static let fileExtension = "clipkeep"
    static let typeIdentifier = "com.clipkeep.history"

    var manifest: HistoryArchiveManifest
    var items: [ClipboardItem]
    /// Payload filename (for example `UUID.png`) → PNG bytes.
    var payloads: [String: Data]

    var pinnedCount: Int {
        items.reduce(0) { $0 + ($1.isPinned ? 1 : 0) }
    }

    static var fileType: UTType {
        if let declared = UTType(typeIdentifier) {
            return declared
        }
        return UTType(filenameExtension: fileExtension, conformingTo: .data) ?? .data
    }

    static func suggestedFileName(date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HHmm"
        return "ClipKeep History \(formatter.string(from: date)).\(fileExtension)"
    }

    /// Build a normalized archive. Image bytes come from `loadPayload` when a clip already
    /// names a payload file, otherwise from inline PNG data.
    static func build(
        items: [ClipboardItem],
        loadPayload: (String) throws -> Data?,
        exportedAt: Date = Date(),
        appVersion: String
    ) throws -> HistoryArchive {
        guard items.count <= HistoryArchiveLimits.maxEntries else {
            throw HistoryArchiveError.tooLarge("more than \(HistoryArchiveLimits.maxEntries) clips")
        }

        var normalized: [ClipboardItem] = []
        var payloads: [String: Data] = [:]
        normalized.reserveCapacity(items.count)

        for item in items {
            var copy = item
            if copy.imagePayloadName != nil || copy.imagePNGData != nil {
                let name: String
                let bytes: Data
                if let existingName = copy.imagePayloadName {
                    name = try validatePayloadName(existingName)
                    if let loaded = try loadPayload(name) {
                        bytes = loaded
                    } else if let inline = copy.imagePNGData {
                        bytes = inline
                    } else if let shared = payloads[name] {
                        bytes = shared
                    } else {
                        throw HistoryArchiveError.missingPayload(name)
                    }
                } else if let inline = copy.imagePNGData {
                    name = "\(copy.id.uuidString).png"
                    _ = try validatePayloadName(name)
                    bytes = inline
                } else {
                    throw HistoryArchiveError.missingPayload(copy.id.uuidString)
                }

                if let shared = payloads[name], shared != bytes {
                    throw HistoryArchiveError.damaged("two clips use \(name) with different images")
                }
                try validatePNG(bytes, name: name)
                payloads[name] = bytes
                copy.imagePayloadName = name
                copy.imagePNGData = nil
            }
            normalized.append(copy)
        }

        let total = payloads.values.reduce(0) { $0 + $1.count } + 1024
        if total > HistoryArchiveLimits.maxArchiveBytes {
            throw HistoryArchiveError.tooLarge("larger than 8 GB")
        }

        let manifest = HistoryArchiveManifest(
            format: formatID,
            exportedAt: exportedAt,
            appVersion: appVersion,
            itemCount: normalized.count,
            pinnedCount: normalized.reduce(0) { $0 + ($1.isPinned ? 1 : 0) }
        )
        return HistoryArchive(manifest: manifest, items: normalized, payloads: payloads)
    }

    func write(to url: URL) throws {
        let data = try encodedData()
        do {
            try data.write(to: url, options: [.atomic])
        } catch {
            throw HistoryArchiveError.writeFailed(error.localizedDescription)
        }
    }

    func encodedData() throws -> Data {
        let manifestData = try Self.encodeJSON(manifest)
        let historyData = try Self.encodeJSON(items)
        var files: [(String, Data)] = [
            ("manifest.json", manifestData),
            ("history.json", historyData),
        ]
        for name in payloads.keys.sorted() {
            guard let data = payloads[name] else { continue }
            files.append(("payloads/\(name)", data))
        }
        return try Self.encodeContainer(files: files)
    }

    static func read(from url: URL) throws -> HistoryArchive {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        if values?.isRegularFile == false {
            throw HistoryArchiveError.readFailed("not a file")
        }
        if let size = values?.fileSize, Int64(size) > Int64(HistoryArchiveLimits.maxArchiveBytes) {
            throw HistoryArchiveError.tooLarge("larger than 8 GB")
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw HistoryArchiveError.readFailed(error.localizedDescription)
        }
        return try read(data: data)
    }

    static func read(data: Data) throws -> HistoryArchive {
        if data.count > HistoryArchiveLimits.maxArchiveBytes {
            throw HistoryArchiveError.tooLarge("larger than 8 GB")
        }
        let files = try decodeContainer(data)
        var byPath: [String: Data] = [:]
        for file in files {
            if byPath[file.path] != nil {
                throw HistoryArchiveError.damaged("duplicate entry \(file.path)")
            }
            byPath[file.path] = file.data
        }

        guard let manifestData = byPath["manifest.json"] else {
            throw HistoryArchiveError.damaged("missing manifest")
        }
        guard let historyData = byPath["history.json"] else {
            throw HistoryArchiveError.damaged("missing history")
        }

        let manifest: HistoryArchiveManifest
        let decodedItems: [ClipboardItem]
        do {
            manifest = try decodeJSON(HistoryArchiveManifest.self, from: manifestData)
            decodedItems = try decodeJSON([ClipboardItem].self, from: historyData)
        } catch let error as HistoryArchiveError {
            throw error
        } catch {
            throw HistoryArchiveError.damaged(error.localizedDescription)
        }

        guard manifest.format == formatID else {
            throw HistoryArchiveError.unsupportedFormat(manifest.format)
        }
        guard decodedItems.count <= HistoryArchiveLimits.maxEntries else {
            throw HistoryArchiveError.tooLarge("more than \(HistoryArchiveLimits.maxEntries) clips")
        }

        var payloads: [String: Data] = [:]
        var normalized: [ClipboardItem] = []
        normalized.reserveCapacity(decodedItems.count)

        for item in decodedItems {
            var copy = item
            if copy.imagePayloadName != nil || copy.imagePNGData != nil {
                let name: String
                if let existingName = copy.imagePayloadName {
                    name = try validatePayloadName(existingName)
                } else {
                    name = "\(copy.id.uuidString).png"
                    _ = try validatePayloadName(name)
                }

                let bytes: Data
                if let packed = byPath["payloads/\(name)"] {
                    if let inline = copy.imagePNGData, inline != packed {
                        throw HistoryArchiveError.damaged("image \(name) does not match the clip")
                    }
                    bytes = packed
                } else if let inline = copy.imagePNGData {
                    bytes = inline
                } else {
                    throw HistoryArchiveError.missingPayload(name)
                }
                if let shared = payloads[name], shared != bytes {
                    throw HistoryArchiveError.damaged("two clips use \(name) with different images")
                }
                try validatePNG(bytes, name: name)
                payloads[name] = bytes
                copy.imagePayloadName = name
                copy.imagePNGData = nil
            }
            normalized.append(copy)
        }

        return HistoryArchive(manifest: manifest, items: normalized, payloads: payloads)
    }

    // MARK: - Container

    static func encodeContainer(files: [(String, Data)]) throws -> Data {
        guard files.count <= HistoryArchiveLimits.maxEntries else {
            throw HistoryArchiveError.tooLarge("too many entries")
        }
        var data = Data()
        data.append(contentsOf: Array(magic))
        appendUInt16(containerVersion, to: &data)
        appendUInt16(0, to: &data)
        appendUInt32(UInt32(files.count), to: &data)

        var total = data.count
        for file in files {
            try validateEntryPath(file.0)
            let pathBytes = Data(file.0.utf8)
            guard pathBytes.count <= HistoryArchiveLimits.maxPathBytes else {
                throw HistoryArchiveError.unsafePath
            }
            guard file.1.count <= HistoryArchiveLimits.maxEntryBytes else {
                throw HistoryArchiveError.tooLarge(file.0)
            }
            total += 2 + pathBytes.count + 8 + file.1.count
            if total > HistoryArchiveLimits.maxArchiveBytes {
                throw HistoryArchiveError.tooLarge("larger than 8 GB")
            }
            appendUInt16(UInt16(pathBytes.count), to: &data)
            data.append(pathBytes)
            appendUInt64(UInt64(file.1.count), to: &data)
            data.append(file.1)
        }
        return data
    }

    static func decodeContainer(_ data: Data) throws -> [(path: String, data: Data)] {
        var reader = Reader(data: data)
        let magicBytes = try reader.take(4)
        guard magicBytes.elementsEqual(magic) else {
            throw HistoryArchiveError.unrecognized
        }
        let version = try reader.u16()
        guard version == containerVersion else {
            throw HistoryArchiveError.unsupportedVersion(Int(version))
        }
        let reserved = try reader.u16()
        guard reserved == 0 else {
            throw HistoryArchiveError.damaged("unsupported flags")
        }
        let count = try reader.u32()
        guard count <= UInt32(HistoryArchiveLimits.maxEntries) else {
            throw HistoryArchiveError.tooLarge("too many entries")
        }

        var files: [(path: String, data: Data)] = []
        files.reserveCapacity(Int(count))
        for _ in 0..<count {
            let pathLength = try reader.u16()
            guard pathLength <= HistoryArchiveLimits.maxPathBytes else {
                throw HistoryArchiveError.unsafePath
            }
            let pathData = try reader.take(Int(pathLength))
            guard let path = String(data: pathData, encoding: .utf8) else {
                throw HistoryArchiveError.damaged("entry path is not UTF-8")
            }
            try validateEntryPath(path)
            let byteCount = try reader.u64()
            guard byteCount <= UInt64(HistoryArchiveLimits.maxEntryBytes) else {
                throw HistoryArchiveError.tooLarge(path)
            }
            let bytes = try reader.take(Int(byteCount))
            files.append((path, bytes))
        }
        guard reader.offset == data.count else {
            throw HistoryArchiveError.damaged("trailing bytes")
        }
        return files
    }

    static func validatePayloadName(_ name: String) throws -> String {
        guard name.range(of: payloadNamePattern, options: .regularExpression) != nil else {
            throw HistoryArchiveError.unsafePath
        }
        return name
    }

    static func validateEntryPath(_ path: String) throws {
        guard isSafeRelativePath(path) else {
            throw HistoryArchiveError.unsafePath
        }
        if path == "manifest.json" || path == "history.json" {
            return
        }
        if path.hasPrefix("payloads/") {
            let name = String(path.dropFirst("payloads/".count))
            guard !name.contains("/") else {
                throw HistoryArchiveError.unsafePath
            }
            _ = try validatePayloadName(name)
            return
        }
        // Unknown extra entries are kept out of the history. The path itself must still be safe.
    }

    private static func validatePNG(_ data: Data, name: String) throws {
        guard data.count <= HistoryArchiveLimits.maxEntryBytes else {
            throw HistoryArchiveError.tooLarge(name)
        }
        guard data.count >= pngSignature.count, data.prefix(pngSignature.count).elementsEqual(pngSignature) else {
            throw HistoryArchiveError.notPNG(name)
        }
    }

    private static func isSafeRelativePath(_ path: String) -> Bool {
        if path.isEmpty || path.hasPrefix("/") || path.contains("\\") || path.contains("\0") || path.contains(":") {
            return false
        }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        if parts.isEmpty || parts.contains("") || parts.contains(".") || parts.contains("..") {
            return false
        }
        return true
    }

    private static func encodeJSON<T: Encodable>(_ value: T) throws -> Data {
        do {
            return try jsonEncoder.encode(value)
        } catch {
            throw HistoryArchiveError.damaged(error.localizedDescription)
        }
    }

    private static func decodeJSON<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try jsonDecoder.decode(type, from: data)
        } catch {
            throw HistoryArchiveError.damaged(error.localizedDescription)
        }
    }

    private static func appendUInt16(_ value: UInt16, to data: inout Data) {
        data.append(UInt8(value & 0xff))
        data.append(UInt8((value >> 8) & 0xff))
    }

    private static func appendUInt32(_ value: UInt32, to data: inout Data) {
        var rest = value
        for _ in 0..<4 {
            data.append(UInt8(rest & 0xff))
            rest >>= 8
        }
    }

    private static func appendUInt64(_ value: UInt64, to data: inout Data) {
        var rest = value
        for _ in 0..<8 {
            data.append(UInt8(rest & 0xff))
            rest >>= 8
        }
    }

    fileprivate static let magic = Data("CKH1".utf8)
    private static let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
    private static let payloadNamePattern =
        #"^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\.png$"#

    private static let jsonEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let jsonDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private struct Reader {
        let data: Data
        var offset = 0

        mutating func take(_ count: Int) throws -> Data {
            guard count >= 0, offset <= data.count, count <= data.count - offset else {
                throw HistoryArchiveError.damaged("truncated")
            }
            let end = offset + count
            let slice = data.subdata(in: offset..<end)
            offset = end
            return slice
        }

        mutating func u16() throws -> UInt16 {
            let bytes = try take(2)
            return UInt16(bytes[0]) | (UInt16(bytes[1]) << 8)
        }

        mutating func u32() throws -> UInt32 {
            let bytes = try take(4)
            var value: UInt32 = 0
            for (index, byte) in bytes.enumerated() {
                value |= UInt32(byte) << (8 * index)
            }
            return value
        }

        mutating func u64() throws -> UInt64 {
            let bytes = try take(8)
            var value: UInt64 = 0
            for (index, byte) in bytes.enumerated() {
                value |= UInt64(byte) << (8 * index)
            }
            return value
        }
    }
}

struct HistoryArchiveManifest: Codable, Equatable {
    var format: String
    var exportedAt: Date
    var appVersion: String
    var itemCount: Int
    var pinnedCount: Int
}

enum HistoryArchiveLimits {
    static let maxEntries = 100_000
    static let maxEntryBytes = 128 * 1024 * 1024
    static let maxArchiveBytes = 8 * 1024 * 1024 * 1024
    static let maxPathBytes = 240
}

enum HistoryImportMode: Equatable {
    case replace
    case merge
}

struct HistoryImportResult: Equatable {
    var mode: HistoryImportMode
    /// Clips taken from the file before the history limits ran.
    var added: Int
    var skippedDuplicates: Int
    var trimmed: Int
    var resultingCount: Int

    var summary: String {
        switch mode {
        case .replace:
            var text = "History now matches the file (\(Self.clips(resultingCount)))."
            if trimmed > 0 {
                text += " Limits removed \(Self.clips(trimmed))."
            }
            return text
        case .merge:
            var text = "Added \(Self.clips(added))."
            if skippedDuplicates > 0 {
                text += " \(Self.clips(skippedDuplicates)) already in history were left as they are."
            }
            if trimmed > 0 {
                text += " Limits removed \(Self.clips(trimmed))."
            }
            text += " History now has \(Self.clips(resultingCount))."
            return text
        }
    }

    private static func clips(_ count: Int) -> String {
        count == 1 ? "1 clip" : "\(count) clips"
    }
}

enum HistoryArchiveError: LocalizedError, Equatable {
    case unrecognized
    case unsupportedVersion(Int)
    case unsupportedFormat(String)
    case damaged(String)
    case missingPayload(String)
    case unsafePath
    case notPNG(String)
    case tooLarge(String)
    case readFailed(String)
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .unrecognized:
            return "This file is not a ClipKeep history."
        case .unsupportedVersion(let version):
            return "This history file uses container version \(version). ClipKeep reads version 1."
        case .unsupportedFormat(let format):
            return "This history file uses format \(format). ClipKeep reads CLIPKEEP/1."
        case .damaged(let detail):
            return "This history file is damaged (\(detail))."
        case .missingPayload(let name):
            return "This history file is missing the image \(name)."
        case .unsafePath:
            return "This history file contains a path ClipKeep will not use."
        case .notPNG(let name):
            return "The image \(name) is not a PNG."
        case .tooLarge(let detail):
            return "This history file is too large (\(detail))."
        case .readFailed(let detail):
            return "ClipKeep could not read the history file (\(detail))."
        case .writeFailed(let detail):
            return "ClipKeep could not write the history file (\(detail))."
        }
    }
}
