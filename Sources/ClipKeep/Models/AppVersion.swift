import Foundation

/// Marketing and build version from the app bundle (`AppInfo.plist` / Info.plist).
enum AppVersion {
    /// e.g. "1.2.3" — `CFBundleShortVersionString`
    static var short: String {
        value(for: "CFBundleShortVersionString") ?? "1.2.3"
    }

    /// e.g. "10" — `CFBundleVersion`
    static var build: String {
        value(for: "CFBundleVersion") ?? "10"
    }

    /// Settings / About display string, e.g. "1.2.3 (10)"
    static var display: String {
        "\(short) (\(build))"
    }

    private static func value(for key: String) -> String? {
        let raw = Bundle.main.object(forInfoDictionaryKey: key) as? String
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty == false) ? trimmed : nil
    }
}
