import AppKit
import Foundation
import Combine

/// 升级阶段枚举，用于驱动 AboutSettingsViewController 的进度 UI。
enum UpgradePhase {
    case idle
    case checking
    case downloading
    case installing
    case done
    case failed(Error)
}

extension UpgradePhase: Equatable {
    static func == (lhs: UpgradePhase, rhs: UpgradePhase) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle),
             (.checking, .checking),
             (.downloading, .downloading),
             (.installing, .installing),
             (.done, .done):
            return true
        case (.failed(let lhsError), .failed(let rhsError)):
            return lhsError.localizedDescription == rhsError.localizedDescription
        default:
            return false
        }
    }
}

final class UpdateChecker {
    static let shared = UpdateChecker()

    private static let checkInterval: TimeInterval = 24 * 60 * 60
    private static let cacheKey = "lastUpdateCheckTimestamp"
    private static let dismissedVersionKey = "dismissedUpdateVersion"
    private static let releasesURL = "https://api.github.com/repos/strzhao/claude-code-buddy/releases/latest"
    private static let releasesPageURL = "https://github.com/strzhao/claude-code-buddy/releases"
    private static let startupDelay: TimeInterval = 10.0

    private(set) var isUpgrading = false
    private var pendingUpdate: UpdateAvailableEvent?
    private var checkTimer: Timer?
    /// 缓存最新 release 信息（供 shouldShowSystemCat 使用，即使已 dismiss 也保留）。
    private var latestRelease: ReleaseInfo?

    /// 升级进度流（后台线程发布，订阅方通过 receive(on: RunLoop.main) 接收）。
    let upgradeProgress = PassthroughSubject<UpgradePhase, Never>()

    /// 检查结果流：checkForUpdates 完成后发布 CheckOutcome（available/upToDate/failed），
    /// 供 AboutSettingsViewController 事件驱动渲染「检查更新」反馈。
    let checkResult = PassthroughSubject<CheckOutcome, Never>()

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
            let currentVersion = Self.currentVersion()
            do {
                let release = try await fetchLatestRelease()
                processFetchResult(.success(release), currentVersion: currentVersion)
            } catch {
                processFetchResult(.failure(error), currentVersion: currentVersion)
            }
        }
    }

    func forceCheckForUpdates() {
        UserDefaults.standard.removeObject(forKey: Self.cacheKey)
        checkForUpdates()
    }

    /// 处理一次 fetch 结果，判定并发布 CheckOutcome（同时维护 pendingUpdate / latestRelease / EventBus）。
    /// 抽取为独立方法以便单元测试绕过网络；UI 相关事件在主线程发布。
    func processFetchResult(_ result: Result<ReleaseInfo, Error>, currentVersion: String) {
        switch result {
        case .success(let release):
            // 缓存最新 release 信息（即使已 dismiss 也保留，供 shouldShowSystemCat 使用）
            latestRelease = release
            if compareVersions(currentVersion, release.version) == .orderedAscending {
                let event = UpdateAvailableEvent(
                    currentVersion: currentVersion,
                    newVersion: release.version,
                    htmlURL: release.htmlURL
                )
                pendingUpdate = event
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    EventBus.shared.updateAvailable.send(event)
                    self.checkResult.send(.available(event))
                }
            } else {
                DispatchQueue.main.async { [weak self] in
                    self?.checkResult.send(.upToDate)
                }
            }
            UserDefaults.standard.set(Date(), forKey: Self.cacheKey)
        case .failure(let error):
            BuddyLogger.shared.warn("update check failed", subsystem: "app", meta: ["error": "\(error)"])
            DispatchQueue.main.async { [weak self] in
                self?.checkResult.send(.failed(error))
            }
        }
    }

    /// 将当前 pendingUpdate 的 newVersion 写入已忽略列表。
    func dismissCurrentVersion() {
        guard let version = pendingUpdate?.newVersion else { return }
        dismissedUpdateVersion = version
        BuddyLogger.shared.info("dismissed update version", subsystem: "app", meta: ["version": version])
    }

    /// 系统猫是否应该显示：有新版本且未被用户忽略。
    func shouldShowSystemCat() -> Bool {
        guard let pending = pendingUpdate else {
            // 有缓存 release 但未创建 pendingUpdate？用 latestRelease 兜底
            guard let latest = latestRelease,
                  compareVersions(Self.currentVersion(), latest.version) == .orderedAscending else {
                return false
            }
            return dismissedUpdateVersion != latest.version
        }
        return dismissedUpdateVersion != pending.newVersion
    }

    func startUpgrade() {
        guard !isUpgrading else { return }
        isUpgrading = true
        upgradeProgress.send(.checking)

        if let brew = brewPath() {
            executeBrewUpgradeStreaming(brew: brew)
        } else {
            openReleasesPageInBrowser()
            isUpgrading = false
            upgradeProgress.send(.idle)
        }
    }

    var hasPendingUpdate: Bool { pendingUpdate != nil }

    /// pendingUpdate 的新版本号（供关于页初始展示），无则 nil。
    var pendingNewVersion: String? { pendingUpdate?.newVersion }

    /// 已忽略的更新版本（UserDefaults 持久化）。
    /// 读：从 UserDefaults 取；写：写入 UserDefaults（nil 时 removeObject）。
    var dismissedUpdateVersion: String? {
        get { UserDefaults.standard.string(forKey: Self.dismissedVersionKey) }
        set {
            if let version = newValue {
                UserDefaults.standard.set(version, forKey: Self.dismissedVersionKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.dismissedVersionKey)
            }
        }
    }

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

    // MARK: - Upgrade (流式进度)

    private func executeBrewUpgradeStreaming(brew: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: brew)
        process.arguments = ["upgrade", "claude-code-buddy"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        // 流式读取 stdout/stderr，按关键词匹配阶段
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let self = self else { return }
            if let output = String(data: data, encoding: .utf8) {
                let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty { return }
                BuddyLogger.shared.debug("brew output", subsystem: "app", meta: ["line": trimmed])

                // 阶段匹配
                if trimmed.contains("==>") || trimmed.contains("Downloading") || trimmed.contains("download") {
                    self.upgradeProgress.send(.downloading)
                } else if trimmed.contains("Pouring") || trimmed.contains("Installing") || trimmed.contains("install") {
                    self.upgradeProgress.send(.installing)
                }
            }
        }

        process.terminationHandler = { [weak self] proc in
            guard let self = self else { return }
            // 清理 readabilityHandler 避免泄漏
            pipe.fileHandleForReading.readabilityHandler = nil

            DispatchQueue.main.async {
                if proc.terminationStatus == 0 {
                    self.upgradeProgress.send(.done)
                    EventBus.shared.upgradeCompleted.send()
                } else {
                    let error = NSError(
                        domain: "UpdateChecker",
                        code: Int(proc.terminationStatus),
                        userInfo: [NSLocalizedDescriptionKey: "brew upgrade 退出码: \(proc.terminationStatus)"]
                    )
                    self.upgradeProgress.send(.failed(error))
                    BuddyLogger.shared.warn("brew upgrade exited", subsystem: "app", meta: ["exitCode": proc.terminationStatus])
                    self.isUpgrading = false
                }
            }
        }

        do {
            try process.run()
            upgradeProgress.send(.checking)
        } catch {
            BuddyLogger.shared.error("brew upgrade failed to start", subsystem: "app", meta: ["error": "\(error)"])
            upgradeProgress.send(.failed(error))
            isUpgrading = false
        }
    }

    private func openReleasesPageInBrowser() {
        guard let url = URL(string: Self.releasesPageURL) else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Test Helpers

    /// 测试用：注入 pendingUpdate（模拟 checkForUpdates 检测到新版本）。
    func setPendingUpdateForTesting(_ event: UpdateAvailableEvent) {
        pendingUpdate = event
        latestRelease = ReleaseInfo(tagName: "v\(event.newVersion)", version: event.newVersion, htmlURL: event.htmlURL)
    }

    /// 测试用：清除 pendingUpdate 和 latestRelease。
    func clearPendingUpdateForTesting() {
        pendingUpdate = nil
        latestRelease = nil
    }
}

// MARK: - Supporting Types

struct ReleaseInfo {
    let tagName: String
    let version: String
    let htmlURL: URL
}

/// 一次更新检查的结果，驱动 AboutSettingsViewController 的反馈 UI。
enum CheckOutcome {
    case available(UpdateAvailableEvent)
    case upToDate
    case failed(Error)
}

enum UpdateError: Error {
    case invalidURL
    case invalidResponse
}
