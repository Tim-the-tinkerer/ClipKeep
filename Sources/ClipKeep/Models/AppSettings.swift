import AppKit
import Foundation

/// User preferences persisted with UserDefaults via Codable JSON.
///
/// Decoding is migration-friendly: missing keys fall back to defaults so adding
/// new non-optional fields does not wipe existing preferences.
struct AppSettings: Equatable {
    /// Maximum unpinned history items retained.
    var maxHistoryCount: Int
    /// Max total size of image payloads on disk (MB). 0 = unlimited. Pinned items never deleted by size trim.
    var maxPayloadStorageMB: Int
    /// Poll interval for pasteboard changeCount (seconds).
    var pollInterval: Double
    /// Capture plain text.
    var captureText: Bool
    /// Capture rich text (stored as plain text in history).
    var captureRichText: Bool
    /// Capture images (PNG).
    var captureImages: Bool
    /// Capture file URL lists.
    var captureFiles: Bool
    /// Honor NSPASTEBOARD concealed/transient markers (password managers).
    var respectConcealedPasteboard: Bool
    /// Skip capturing when frontmost app matches excluded bundle IDs.
    var excludeBySourceApp: Bool
    /// Bundle IDs never captured from (password managers, etc.).
    var excludedBundleIDs: [String]
    /// Launch at login (best-effort; managed via SMAppService when available).
    var launchAtLogin: Bool
    /// Show count badge on menu bar icon.
    var showCountInMenuBar: Bool
    /// Register a system-wide hotkey to open the history panel.
    var globalHotkeyEnabled: Bool
    /// Carbon / macOS virtual key code (e.g. 9 = V).
    var globalHotkeyKeyCode: Int
    /// Modifier flags raw value (`NSEvent.ModifierFlags` device-independent flags).
    var globalHotkeyModifiers: Int

    static let defaultExcludedBundleIDs: [String] = [
        // 1Password
        "com.1password.1password",
        "com.1password.1password-launcher",
        "com.agilebits.onepassword7",
        "com.agilebits.onepassword-osx",
        "com.1password.safari",
        // Bitwarden
        "com.bitwarden.desktop",
        "com.bitwarden.desktop.safari",
        // LastPass
        "com.lastpass.LastPass",
        "com.lastpass.lpmacosx",
        // KeePass / KeePassXC
        "org.keepassx.keepassxc",
        "org.keepassx.keepassx",
        "com.apple.Safari", // only when combined with other checks; kept out of defaults
        // Dashlane
        "com.dashlane.dashlanephonefinal",
        "com.dashlane.Dashlane",
        // Enpass
        "in.sinew.Enpass-Desktop",
        // RoboForm
        "com.SiberSystems.RoboForm",
        // Strongbox / KeePass clients
        "com.markmcguill.strongbox",
        // Authy / 2FA (often secrets)
        "com.authy.authy-mac",
        // Proton Pass
        "me.proton.pass.electron",
        // NordPass
        "com.nordsec.nordpass",
        // Keeper
        "com.keepersecurity.KeeperDesktop",
        // Sticky Password
        "com.stickypassword.StickyPassword",
        // macOS Keychain Access
        "com.apple.keychainaccess",
        // Secrets / password generators
        "com.apple.Passwords",
        "com.apple.passwordmanager",
    ].filter { $0 != "com.apple.Safari" }

    /// Default hotkey: ⌘⇧V
    static let defaultHotkeyKeyCode = 9 // kVK_ANSI_V
    static let defaultHotkeyModifiers = Int(
        NSEvent.ModifierFlags([.command, .shift]).intersection(.deviceIndependentFlagsMask).rawValue
    )

    static let `default` = AppSettings(
        maxHistoryCount: 100,
        maxPayloadStorageMB: 200,
        pollInterval: 0.4,
        captureText: true,
        captureRichText: true,
        captureImages: true,
        captureFiles: true,
        respectConcealedPasteboard: true,
        excludeBySourceApp: true,
        excludedBundleIDs: defaultExcludedBundleIDs,
        launchAtLogin: false,
        showCountInMenuBar: false,
        globalHotkeyEnabled: true,
        globalHotkeyKeyCode: defaultHotkeyKeyCode,
        globalHotkeyModifiers: defaultHotkeyModifiers
    )

    static let storageKey = "ClipKeep.AppSettings"

    static func load() -> AppSettings {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode(AppSettings.self, from: data)
        else {
            return .default
        }
        return decoded
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }

    mutating func addExcludedBundleID(_ id: String) {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !excludedBundleIDs.contains(trimmed) else { return }
        excludedBundleIDs.append(trimmed)
        excludedBundleIDs.sort()
    }

    mutating func removeExcludedBundleID(_ id: String) {
        excludedBundleIDs.removeAll { $0 == id }
    }

    mutating func resetExcludedAppsToDefaults() {
        excludedBundleIDs = Self.defaultExcludedBundleIDs
    }

    var maxPayloadStorageBytes: Int64 {
        guard maxPayloadStorageMB > 0 else { return 0 }
        return Int64(maxPayloadStorageMB) * 1024 * 1024
    }
}

// MARK: - Codable (forward-compatible)

extension AppSettings: Codable {
    private enum CodingKeys: String, CodingKey {
        case maxHistoryCount
        case maxPayloadStorageMB
        case pollInterval
        case captureText
        case captureRichText
        case captureImages
        case captureFiles
        case respectConcealedPasteboard
        case excludeBySourceApp
        case excludedBundleIDs
        case launchAtLogin
        case showCountInMenuBar
        case globalHotkeyEnabled
        case globalHotkeyKeyCode
        case globalHotkeyModifiers
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Self.default
        maxHistoryCount = try c.decodeIfPresent(Int.self, forKey: .maxHistoryCount) ?? d.maxHistoryCount
        maxPayloadStorageMB = try c.decodeIfPresent(Int.self, forKey: .maxPayloadStorageMB) ?? d.maxPayloadStorageMB
        pollInterval = try c.decodeIfPresent(Double.self, forKey: .pollInterval) ?? d.pollInterval
        captureText = try c.decodeIfPresent(Bool.self, forKey: .captureText) ?? d.captureText
        captureRichText = try c.decodeIfPresent(Bool.self, forKey: .captureRichText) ?? d.captureRichText
        captureImages = try c.decodeIfPresent(Bool.self, forKey: .captureImages) ?? d.captureImages
        captureFiles = try c.decodeIfPresent(Bool.self, forKey: .captureFiles) ?? d.captureFiles
        respectConcealedPasteboard = try c.decodeIfPresent(Bool.self, forKey: .respectConcealedPasteboard)
            ?? d.respectConcealedPasteboard
        excludeBySourceApp = try c.decodeIfPresent(Bool.self, forKey: .excludeBySourceApp)
            ?? d.excludeBySourceApp
        excludedBundleIDs = try c.decodeIfPresent([String].self, forKey: .excludedBundleIDs)
            ?? d.excludedBundleIDs
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? d.launchAtLogin
        showCountInMenuBar = try c.decodeIfPresent(Bool.self, forKey: .showCountInMenuBar)
            ?? d.showCountInMenuBar
        globalHotkeyEnabled = try c.decodeIfPresent(Bool.self, forKey: .globalHotkeyEnabled)
            ?? d.globalHotkeyEnabled
        globalHotkeyKeyCode = try c.decodeIfPresent(Int.self, forKey: .globalHotkeyKeyCode)
            ?? d.globalHotkeyKeyCode
        globalHotkeyModifiers = try c.decodeIfPresent(Int.self, forKey: .globalHotkeyModifiers)
            ?? d.globalHotkeyModifiers
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(maxHistoryCount, forKey: .maxHistoryCount)
        try c.encode(maxPayloadStorageMB, forKey: .maxPayloadStorageMB)
        try c.encode(pollInterval, forKey: .pollInterval)
        try c.encode(captureText, forKey: .captureText)
        try c.encode(captureRichText, forKey: .captureRichText)
        try c.encode(captureImages, forKey: .captureImages)
        try c.encode(captureFiles, forKey: .captureFiles)
        try c.encode(respectConcealedPasteboard, forKey: .respectConcealedPasteboard)
        try c.encode(excludeBySourceApp, forKey: .excludeBySourceApp)
        try c.encode(excludedBundleIDs, forKey: .excludedBundleIDs)
        try c.encode(launchAtLogin, forKey: .launchAtLogin)
        try c.encode(showCountInMenuBar, forKey: .showCountInMenuBar)
        try c.encode(globalHotkeyEnabled, forKey: .globalHotkeyEnabled)
        try c.encode(globalHotkeyKeyCode, forKey: .globalHotkeyKeyCode)
        try c.encode(globalHotkeyModifiers, forKey: .globalHotkeyModifiers)
    }
}
