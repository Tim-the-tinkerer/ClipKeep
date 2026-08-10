import Foundation

/// Marketing and build version from the app bundle (`AppInfo.plist` / Info.plist).
enum AppVersion {
    /// e.g. "1.1.2" — `CFBundleShortVersionString`
    static var short: String {
        value(for: "CFBundleShortVersionString") ?? "1.1.2"
    }

    /// e.g. "6" — `CFBundleVersion`
    static var build: String {
        value(for: "CFBundleVersion") ?? "6"
    }

    /// Settings / About display string, e.g. "1.1.2 (6)"
    static var display: String {
        "\(short) (\(build))"
    }

    private static func value(for key: String) -> String? {
        let raw = Bundle.main.object(forInfoDictionaryKey: key) as? String
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty == false) ? trimmed : nil
    }
}
