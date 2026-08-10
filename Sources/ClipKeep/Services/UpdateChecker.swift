import AppKit
import Foundation

/// Project URLs and GitHub release checks for ClipKeep.
enum AppLinks {
    static let repository = URL(string: "https://github.com/Tim-the-tinkerer/ClipKeep")!
    static let releases = URL(string: "https://github.com/Tim-the-tinkerer/ClipKeep/releases")!
    static let latestReleaseAPI = URL(
        string: "https://api.github.com/repos/Tim-the-tinkerer/ClipKeep/releases/latest"
    )!
}

/// Checks GitHub Releases for a newer version and opens the project page when appropriate.
@MainActor
final class UpdateChecker: ObservableObject {
    enum Status: Equatable {
        case idle
        case checking
        case upToDate(current: String)
        case updateAvailable(current: String, latest: String, releaseURL: URL?)
        case noReleases(current: String)
        case failed(String)

        var summary: String {
            switch self {
            case .idle:
                return "Not checked yet."
            case .checking:
                return "Checking GitHub for updates…"
            case .upToDate(let current):
                return "You’re up to date (\(current))."
            case .updateAvailable(let current, let latest, _):
                return "Update available: \(latest) (you have \(current))."
            case .noReleases(let current):
                return "No GitHub releases published yet (running \(current)). Visit the repository for builds."
            case .failed(let message):
                return "Could not check: \(message)"
            }
        }
    }

    @Published private(set) var status: Status = .idle

    private var inFlight: Task<Void, Never>?

    func openRepository() {
        NSWorkspace.shared.open(AppLinks.repository)
    }

    func openReleases() {
        NSWorkspace.shared.open(AppLinks.releases)
    }

    func openUpdateDestination() {
        switch status {
        case .updateAvailable(_, _, let releaseURL):
            NSWorkspace.shared.open(releaseURL ?? AppLinks.releases)
        case .noReleases:
            openRepository()
        default:
            openReleases()
        }
    }

    /// Start an async check; updates `status` for SwiftUI observers.
    func checkForUpdates() {
        inFlight?.cancel()
        status = .checking
        inFlight = Task { [weak self] in
            guard let self else { return }
            let next = await Self.evaluate()
            guard !Task.isCancelled else { return }
            self.status = next
        }
    }

    /// Check and show a modal result (menus / first-run style).
    func checkForUpdatesPresentingAlert() {
        inFlight?.cancel()
        status = .checking
        inFlight = Task { [weak self] in
            guard let self else { return }
            let next = await Self.evaluate()
            guard !Task.isCancelled else { return }
            self.status = next
            self.presentAlert(for: next)
        }
    }

    private func presentAlert(for status: Status) {
        let alert = NSAlert()
        alert.alertStyle = .informational

        switch status {
        case .upToDate(let current):
            alert.messageText = "You’re up to date"
            alert.informativeText = "ClipKeep \(current) is the latest published release."
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Open GitHub")
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertSecondButtonReturn {
                openRepository()
            }

        case .updateAvailable(let current, let latest, let releaseURL):
            alert.messageText = "Update available"
            alert.informativeText =
                "ClipKeep \(latest) is available (you have \(current)).\n\nDownload the latest build from GitHub."
            alert.addButton(withTitle: "View Release")
            alert.addButton(withTitle: "Open Repository")
            alert.addButton(withTitle: "Later")
            NSApp.activate(ignoringOtherApps: true)
            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                NSWorkspace.shared.open(releaseURL ?? AppLinks.releases)
            } else if response == .alertSecondButtonReturn {
                openRepository()
            }

        case .noReleases(let current):
            alert.messageText = "No releases yet"
            alert.informativeText =
                "GitHub has no published releases for ClipKeep. You’re running \(current).\n\nOpen the repository for source and build instructions."
            alert.addButton(withTitle: "Open GitHub")
            alert.addButton(withTitle: "OK")
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn {
                openRepository()
            }

        case .failed(let message):
            alert.alertStyle = .warning
            alert.messageText = "Update check failed"
            alert.informativeText =
                "\(message)\n\nYou can still open the project page:\n\(AppLinks.repository.absoluteString)"
            alert.addButton(withTitle: "Open GitHub")
            alert.addButton(withTitle: "OK")
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn {
                openRepository()
            }

        case .idle, .checking:
            break
        }
    }

    // MARK: - Network / version compare

    private static func evaluate() async -> Status {
        let current = AppVersion.short
        let result = await fetchLatestRelease()
        switch result {
        case .success(let release):
            if isVersion(release.version, newerThan: current) {
                return .updateAvailable(
                    current: current,
                    latest: release.version,
                    releaseURL: release.htmlURL
                )
            }
            return .upToDate(current: current)
        case .noRelease:
            return .noReleases(current: current)
        case .failure(let message):
            return .failed(message)
        }
    }

    private enum FetchResult {
        case success(ReleaseInfo)
        case noRelease
        case failure(String)
    }

    private struct ReleaseInfo {
        let version: String
        let htmlURL: URL?
    }

    private static func fetchLatestRelease() async -> FetchResult {
        var request = URLRequest(url: AppLinks.latestReleaseAPI)
        request.setValue("ClipKeep/\(AppVersion.short) (macOS)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failure("Invalid response from GitHub.")
            }
            if http.statusCode == 404 {
                return .noRelease
            }
            guard (200...299).contains(http.statusCode) else {
                return .failure("GitHub returned HTTP \(http.statusCode).")
            }

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return .failure("Could not parse release data.")
            }

            let tag = (json["tag_name"] as? String)
                ?? (json["name"] as? String)
                ?? ""
            let version = normalizeVersion(tag)
            guard !version.isEmpty else {
                return .failure("Latest release has no version tag.")
            }

            let html: URL?
            if let s = json["html_url"] as? String {
                html = URL(string: s)
            } else {
                html = nil
            }

            return .success(ReleaseInfo(version: version, htmlURL: html))
        } catch is CancellationError {
            return .failure("Cancelled.")
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    /// Strip leading "v" / pre-release: "v1.2.3-beta" → "1.2.3"
    static func normalizeVersion(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.lowercased().hasPrefix("v") {
            s = String(s.dropFirst())
        }
        if let dash = s.firstIndex(of: "-") {
            s = String(s[..<dash])
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// True if `lhs` is strictly greater than `rhs` using dotted numeric segments.
    static func isVersion(_ lhs: String, newerThan rhs: String) -> Bool {
        let a = numericParts(lhs)
        let b = numericParts(rhs)
        let n = max(a.count, b.count)
        for i in 0..<n {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    private static func numericParts(_ version: String) -> [Int] {
        normalizeVersion(version)
            .split(separator: ".")
            .map { Int($0.filter(\.isNumber)) ?? 0 }
    }
}
