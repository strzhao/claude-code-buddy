import AppKit
import Foundation

final class UpdateChecker {
    static let shared = UpdateChecker()

    private static let checkInterval: TimeInterval = 24 * 60 * 60
    private static let cacheKey = "lastUpdateCheckTimestamp"
    private static let releasesURL = "https://api.github.com/repos/strzhao/claude-code-buddy/releases/latest"
    private static let releasesPageURL = "https://github.com/strzhao/claude-code-buddy/releases"
    private static let startupDelay: TimeInterval = 10.0

    private(set) var isUpgrading = false
    private var pendingUpdate: UpdateAvailableEvent?
    private var checkTimer: Timer?

    private init() {}

    // MARK: - Public API

    func scheduleInitialCheck() {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.startupDelay) { [weak self] in
            self?.checkForUpdates()
            self?.startPeriodicCheck()
        }
    }

    func checkForUpdates() {
        guard shouldCheck() else { return }

        Task {
            do {
                let release = try await fetchLatestRelease()
                let currentVersion = Self.currentVersion()

                if compareVersions(currentVersion, release.version) == .orderedAscending {
                    let event = UpdateAvailableEvent(
                        currentVersion: currentVersion,
                        newVersion: release.version,
                        htmlURL: release.htmlURL
                    )
                    pendingUpdate = event
                    DispatchQueue.main.async {
                        EventBus.shared.updateAvailable.send(event)
                    }
                }
                UserDefaults.standard.set(Date(), forKey: Self.cacheKey)
            } catch {
                NSLog("[UpdateChecker] Check failed: \(error)")
            }
        }
    }

    func forceCheckForUpdates() {
        UserDefaults.standard.removeObject(forKey: Self.cacheKey)
        checkForUpdates()
    }

    func startUpgrade() {
        guard !isUpgrading else { return }
        isUpgrading = true

        if let brew = brewPath() {
            executeBrewUpgrade(brew: brew)
        } else {
            openReleasesPageInBrowser()
            isUpgrading = false
        }
    }

    var hasPendingUpdate: Bool { pendingUpdate != nil }

    // MARK: - Periodic Check

    private func startPeriodicCheck() {
        checkTimer?.invalidate()
        checkTimer = Timer.scheduledTimer(withTimeInterval: Self.checkInterval, repeats: true) { [weak self] _ in
            self?.checkForUpdates()
        }
    }

    // MARK: - Version Check

    private func shouldCheck() -> Bool {
        guard let lastCheck = UserDefaults.standard.object(forKey: Self.cacheKey) as? Date else {
            return true
        }
        return Date().timeIntervalSince(lastCheck) >= Self.checkInterval
    }

    private func fetchLatestRelease() async throws -> ReleaseInfo {
        guard let url = URL(string: Self.releasesURL) else {
            throw UpdateError.invalidURL
        }

        var request = URLRequest(url: url)
        request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")
        request.setValue("ClaudeCodeBuddy", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 10

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw UpdateError.invalidResponse
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tagName = json["tag_name"] as? String,
              let htmlURLString = json["html_url"] as? String,
              let htmlURL = URL(string: htmlURLString)
        else {
            throw UpdateError.invalidResponse
        }

        let version = tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName
        return ReleaseInfo(tagName: tagName, version: version, htmlURL: htmlURL)
    }

    static func currentVersion() -> String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    // MARK: - Version Comparison

    func compareVersions(_ a: String, _ b: String) -> ComparisonResult {
        let va = parseVersion(a)
        let vb = parseVersion(b)
        for (x, y) in zip(va, vb) where x != y {
            return x < y ? .orderedAscending : .orderedDescending
        }
        return .orderedSame
    }

    private func parseVersion(_ version: String) -> [Int] {
        let cleaned = version.hasPrefix("v") ? String(version.dropFirst()) : version
        let parts = cleaned.split(separator: ".").compactMap { Int($0) }
        return [
            parts.isEmpty ? 0 : parts[0],
            parts.count > 1 ? parts[1] : 0,
            parts.count > 2 ? parts[2] : 0,
        ]
    }

    // MARK: - Homebrew

    private func brewPath() -> String? {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
            .first { FileManager.default.fileExists(atPath: $0) }
    }

    // MARK: - Upgrade

    private func executeBrewUpgrade(brew: String) {
        Task {
            do {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: brew)
                process.arguments = ["upgrade", "claude-code-buddy"]

                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe

                try process.run()
                process.waitUntilExit()

                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    if process.terminationStatus == 0 {
                        EventBus.shared.upgradeCompleted.send()
                    } else {
                        NSLog("[UpdateChecker] brew upgrade exited with code \(process.terminationStatus)")
                        self.isUpgrading = false
                    }
                }
            } catch {
                NSLog("[UpdateChecker] brew upgrade failed: \(error)")
                DispatchQueue.main.async { [weak self] in
                    self?.isUpgrading = false
                }
            }
        }
    }

    private func openReleasesPageInBrowser() {
        guard let url = URL(string: Self.releasesPageURL) else { return }
        NSWorkspace.shared.open(url)
    }
}

// MARK: - Supporting Types

struct ReleaseInfo {
    let tagName: String
    let version: String
    let htmlURL: URL
}

enum UpdateError: Error {
    case invalidURL
    case invalidResponse
}
