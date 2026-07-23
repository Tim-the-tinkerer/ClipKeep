import Foundation

/// User preferences persisted with UserDefaults via Codable JSON.
struct AppSettings: Codable, Equatable {
    /// Maximum unpinned history items retained.
    var maxHistoryCount: Int
    /// Poll interval for pasteboard changeCount (seconds).
    var pollInterval: Double
    /// Capture plain text.
    var captureText: Bool
    /// Capture rich text (stored as plain for history).
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

    static let `default` = AppSettings(
        maxHistoryCount: 100,
        pollInterval: 0.4,
        captureText: true,
        captureRichText: true,
        captureImages: true,
        captureFiles: true,
        respectConcealedPasteboard: true,
        excludeBySourceApp: true,
        excludedBundleIDs: defaultExcludedBundleIDs,
        launchAtLogin: false,
        showCountInMenuBar: false
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
}
