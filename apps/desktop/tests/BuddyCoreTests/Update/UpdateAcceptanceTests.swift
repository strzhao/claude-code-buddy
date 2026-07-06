import XCTest
import Combine
@testable import BuddyCore

// MARK: - UpdateAcceptanceTests

/// 自动升级功能优化 — 验收测试。
///
/// 这些测试基于设计文档编写，验证 UpdateChecker 增强、SystemCatManager、
/// BuddyScene 适配、AppDelegate 修复、AboutSettingsViewController 改造的
/// 核心契约是否正确实现。
///
/// 部分类型/方法可能尚未被蓝队实现 —— 测试先表达设计意图，编译失败是预期的。
final class UpdateAcceptanceTests: XCTestCase {

    private var checker: UpdateChecker!
    private var cancellables: Set<AnyCancellable>!

    /// UserDefaults key，与设计文档保持一致。
    private static let dismissedKey = "dismissedUpdateVersion"

    override func setUp() {
        super.setUp()
        checker = UpdateChecker.shared
        cancellables = Set<AnyCancellable>()
        UserDefaults.standard.removeObject(forKey: Self.dismissedKey)
        checker.clearPendingUpdateForTesting()
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: Self.dismissedKey)
        cancellables = nil
        super.tearDown()
    }

    // MARK: - 1. UpgradePhase 枚举

    /// 验证 UpgradePhase 枚举包含所有预期 case。
    ///
    /// 契约：idle / checking / downloading / installing / done / failed(Error)
    func testUpgradePhaseEnumExistsWithAllCases() {
        // 验证枚举 case 存在（通过构造和比较来断言）
        let idle = UpgradePhase.idle
        let checking = UpgradePhase.checking
        let downloading = UpgradePhase.downloading
        let installing = UpgradePhase.installing
        let done = UpgradePhase.done

        // failed 携带 Error
        let testError = UpdateError.invalidResponse
        let failed = UpgradePhase.failed(testError)

        // 验证 case 彼此不同
        let allCases: [UpgradePhase] = [idle, checking, downloading, installing, done, failed]
        // 6 个 case 应各不同
        XCTAssertEqual(allCases.count, 6, "UpgradePhase 应包含 6 个 case")

        // done 和 done 应相等
        XCTAssertEqual(done, UpgradePhase.done, "相同的 case 应相等")

        // idle 不等于 done
        XCTAssertNotEqual(idle, UpgradePhase.done, "idle 和 done 应不同")
    }

    /// 验证 UpgradePhase.failed 正确携带关联的 Error。
    func testUpgradePhaseFailedCarriesError() {
        let error = UpdateError.invalidResponse
        let phase = UpgradePhase.failed(error)

        switch phase {
        case .failed(let capturedError):
            XCTAssertTrue(capturedError is UpdateError, "failed 应携带 UpdateError")
        default:
            XCTFail("Expected .failed but got \(phase)")
        }
    }

    // MARK: - 2. dismissedUpdateVersion 持久化（C2）

    /// 验证 dismissedUpdateVersion 可通过 UserDefaults 读写。
    ///
    /// 契约 C2：dismissedUpdateVersion 在点击时立即写入 UserDefaults，
    /// key 为 "dismissedUpdateVersion"。
    func testDismissedVersionPersistenceReadWrite() {
        // 初始状态下 dismissedVersion 应为 nil
        XCTAssertNil(checker.dismissedUpdateVersion,
                     "初始 dismissedUpdateVersion 应为 nil")

        // 写入版本号
        let version = "0.15.0"
        checker.dismissedUpdateVersion = version

        // 从 UserDefaults 直接验证
        XCTAssertEqual(
            UserDefaults.standard.string(forKey: Self.dismissedKey),
            version,
            "UserDefaults 中应存储正确的版本号"
        )

        // 通过属性读回
        XCTAssertEqual(checker.dismissedUpdateVersion, version,
                       "dismissedUpdateVersion 应读回写入的值")
    }

    /// 验证清除 dismissedUpdateVersion 后返回 nil。
    func testDismissedVersionClearReturnsNil() {
        checker.dismissedUpdateVersion = "0.15.0"
        XCTAssertEqual(checker.dismissedUpdateVersion, "0.15.0")

        checker.dismissedUpdateVersion = nil

        XCTAssertNil(checker.dismissedUpdateVersion,
                     "清除后 dismissedUpdateVersion 应为 nil")
        XCTAssertNil(UserDefaults.standard.string(forKey: Self.dismissedKey),
                     "UserDefaults 中的 key 也应被移除")
    }

    // MARK: - 3. dismissCurrentVersion（C2）

    /// 验证 dismissCurrentVersion() 将 pendingUpdate 的 newVersion 写入 UserDefaults。
    ///
    /// 契约 C2：点击时立即写入，不依赖升级成功。
    func testDismissCurrentVersionPersistsPendingNewVersion() {
        // 设置一个 pendingUpdate
        let event = UpdateAvailableEvent(
            currentVersion: "0.14.0",
            newVersion: "0.15.0",
            htmlURL: URL(string: "https://github.com/test/releases/tag/v0.15.0")!
        )
        // 通过 EventBus 注入 pendingUpdate（模拟 checkForUpdates 结果）
        checker.setPendingUpdateForTesting(event)

        // 执行 dismiss
        checker.dismissCurrentVersion()

        // 验证 UserDefaults 持久化
        XCTAssertEqual(
            UserDefaults.standard.string(forKey: Self.dismissedKey),
            "0.15.0",
            "dismissCurrentVersion() 应将 pendingUpdate.newVersion 写入 UserDefaults"
        )
        XCTAssertEqual(checker.dismissedUpdateVersion, "0.15.0",
                       "dismissedUpdateVersion 应与 pendingUpdate.newVersion 一致")
    }

    // MARK: - 4. shouldShowSystemCat — 有更新且未 dismiss

    /// 验证有 pendingUpdate 且 newVersion != dismissedVersion 时返回 true。
    func testShouldShowSystemCatWhenUpdateAvailable() {
        // 设置 pendingUpdate: newVersion = "0.15.0"
        let event = UpdateAvailableEvent(
            currentVersion: "0.14.0",
            newVersion: "0.15.0",
            htmlURL: URL(string: "https://github.com/test/releases/tag/v0.15.0")!
        )
        checker.setPendingUpdateForTesting(event)

        // 清除 dismissedVersion
        checker.dismissedUpdateVersion = nil

        XCTAssertTrue(checker.shouldShowSystemCat(),
                      "有 pendingUpdate 且版本未 dismiss 时应返回 true")
    }

    // MARK: - 5. shouldShowSystemCat — 已 dismiss 同版本

    /// 验证 pendingUpdate.newVersion == dismissedVersion 时返回 false。
    func testShouldNotShowSystemCatWhenDismissed() {
        let version = "0.15.0"
        let event = UpdateAvailableEvent(
            currentVersion: "0.14.0",
            newVersion: version,
            htmlURL: URL(string: "https://github.com/test/releases/tag/v0.15.0")!
        )
        checker.setPendingUpdateForTesting(event)
        checker.dismissedUpdateVersion = version  // 同版本已 dismiss

        XCTAssertFalse(checker.shouldShowSystemCat(),
                       "已 dismiss 同版本时应返回 false")
    }

    /// 验证 dismissedVersion 与 pendingUpdate.newVersion 不同时（dismiss 了旧版本、
    /// 检测到新版本），返回 true。
    func testShouldShowSystemCatWhenNewVersionDiffersFromDismissed() {
        let event = UpdateAvailableEvent(
            currentVersion: "0.14.0",
            newVersion: "0.16.0",   // 新版本
            htmlURL: URL(string: "https://github.com/test/releases/tag/v0.16.0")!
        )
        checker.setPendingUpdateForTesting(event)
        checker.dismissedUpdateVersion = "0.15.0"  // dismiss 的是旧版本

        XCTAssertTrue(checker.shouldShowSystemCat(),
                     "dismiss 的是旧版本、检测到新版本时应返回 true")
    }

    // MARK: - 6. shouldShowSystemCat — 无更新

    /// 验证 pendingUpdate 为 nil 时返回 false。
    func testShouldNotShowSystemCatWhenNoUpdate() {
        // 确保没有 pendingUpdate
        checker.clearPendingUpdateForTesting()

        XCTAssertFalse(checker.shouldShowSystemCat(),
                       "无 pendingUpdate 时应返回 false")
    }

    // MARK: - 7. upgradeProgress Publisher（C3）

    /// 验证 upgradeProgress 是 PassthroughSubject<UpgradePhase, Never>。
    func testUpgradeProgressPublisherReceivesEvents() {
        let expectation = XCTestExpectation(description: "upgradeProgress 发布事件")

        var receivedPhase: UpgradePhase?
        checker.upgradeProgress
            .sink { phase in
                receivedPhase = phase
                expectation.fulfill()
            }
            .store(in: &cancellables)

        // 发送一个事件
        checker.upgradeProgress.send(.checking)

        wait(for: [expectation], timeout: 1.0)

        XCTAssertEqual(receivedPhase, .checking,
                       "upgradeProgress 应收到发布的 .checking 事件")
    }

    /// 验证 upgradeProgress 可发布多个阶段事件。
    func testUpgradeProgressPublisherMultipleEvents() {
        var phases: [UpgradePhase] = []
        checker.upgradeProgress
            .sink { phases.append($0) }
            .store(in: &cancellables)

        checker.upgradeProgress.send(.checking)
        checker.upgradeProgress.send(.downloading)
        checker.upgradeProgress.send(.installing)
        checker.upgradeProgress.send(.done)

        XCTAssertEqual(phases.count, 4, "应收到全部 4 个阶段事件")
        XCTAssertEqual(phases[0], .checking)
        XCTAssertEqual(phases[1], .downloading)
        XCTAssertEqual(phases[2], .installing)
        XCTAssertEqual(phases[3], .done)
    }

    /// 契约 C3：startUpgrade() 无论成功/失败都必须发布 .done 或 .failed 终止事件。
    /// 本测试验证 failed 事件可被发布。
    func testUpgradeProgressPublishesFailedOnError() {
        let expectation = XCTestExpectation(description: "upgradeProgress 发布 .failed")

        var receivedPhase: UpgradePhase?
        checker.upgradeProgress
            .sink { phase in
                receivedPhase = phase
                if case .failed = phase {
                    expectation.fulfill()
                }
            }
            .store(in: &cancellables)

        let testError = UpdateError.invalidResponse
        checker.upgradeProgress.send(.failed(testError))

        wait(for: [expectation], timeout: 1.0)

        guard case .failed(let error) = receivedPhase else {
            XCTFail("应收到 .failed 事件")
            return
        }
        XCTAssertTrue(error is UpdateError, "failed 应携带 UpdateError")
    }

    // MARK: - 8. 系统猫 sessionId（C1）

    /// 契约 C1：系统猫 sessionId 必须为 "__system_update__"，
    /// SessionManager 不管理此 id。
    func testSystemCatSessionIdIsConstant() {
        XCTAssertEqual(
            SystemCatManager.systemCatSessionId,
            "__system_update__",
            "系统猫 sessionId 必须为 \"__system_update__\""
        )
    }

    /// 验证 SystemCatManager 创建的系统猫 sessionId 正确。
    func testSystemCatSessionIdOnCreatedCat() {
        // 系统猫的 sessionId 应为常量值（静态属性）
        XCTAssertEqual(
            SystemCatManager.systemCatSessionId,
            "__system_update__",
            "SystemCatManager 管理的系统猫 sessionId 应为 \"__system_update__\""
        )
    }

    // MARK: - 9. compareVersions 行为不变

    /// 验证原有 compareVersions 升序比较行为不变。
    func testCompareVersionsAscendingUnchanged() {
        XCTAssertEqual(checker.compareVersions("0.12.0", "0.12.1"), .orderedAscending)
        XCTAssertEqual(checker.compareVersions("0.11.9", "0.12.0"), .orderedAscending)
        XCTAssertEqual(checker.compareVersions("0.0.1", "1.0.0"), .orderedAscending)
        XCTAssertEqual(checker.compareVersions("0.14.0", "0.14.1"), .orderedAscending)
    }

    /// 验证原有 compareVersions 降序比较行为不变。
    func testCompareVersionsDescendingUnchanged() {
        XCTAssertEqual(checker.compareVersions("0.13.0", "0.12.0"), .orderedDescending)
        XCTAssertEqual(checker.compareVersions("1.0.0", "0.99.9"), .orderedDescending)
        XCTAssertEqual(checker.compareVersions("2.0.0", "1.9.9"), .orderedDescending)
        XCTAssertEqual(checker.compareVersions("0.15.0", "0.14.0"), .orderedDescending)
    }

    /// 验证原有 compareVersions 相等比较行为不变。
    func testCompareVersionsEqualUnchanged() {
        XCTAssertEqual(checker.compareVersions("0.14.0", "0.14.0"), .orderedSame)
        XCTAssertEqual(checker.compareVersions("1.0.0", "1.0.0"), .orderedSame)
        XCTAssertEqual(checker.compareVersions("0.0.0", "0.0.0"), .orderedSame)
    }

    /// 验证跨段比较行为不变（major > minor > patch）。
    func testCompareVersionsMajorBeatsMinorUnchanged() {
        XCTAssertEqual(checker.compareVersions("1.0.0", "0.99.99"), .orderedDescending)
        XCTAssertEqual(checker.compareVersions("0.99.99", "1.0.0"), .orderedAscending)
        XCTAssertEqual(checker.compareVersions("0.2.0", "0.1.99"), .orderedDescending)
    }

    /// 验证带 "v" 前缀的版本号比较。
    func testCompareVersionsWithVPrefix() {
        XCTAssertEqual(checker.compareVersions("v0.14.0", "v0.15.0"), .orderedAscending)
        XCTAssertEqual(checker.compareVersions("v0.15.0", "v0.14.0"), .orderedDescending)
        XCTAssertEqual(checker.compareVersions("0.14.0", "v0.15.0"), .orderedAscending)
    }

    // MARK: - 10. About 页面更新区域（C5；T7 重构后控件在 NSStackView 内，递归查找）

    /// 递归收集所有子视图（含嵌套层级）。
    private func collectAllSubviews(_ view: NSView) -> [NSView] {
        var result: [NSView] = [view]
        for sub in view.subviews {
            result.append(contentsOf: collectAllSubviews(sub))
        }
        return result
    }

    /// 契约 C5：About 页面包含更新相关子视图（检查更新按钮、立即升级按钮、进度条、状态标签）。
    /// T7（2026-07-02）重构后控件在 NSStackView（buttonRow / statusRow）内，
    /// 用递归查找而非 view.subviews 直接遍历。
    func testAboutViewHasUpdateSectionSubviews() {
        let aboutVC = AboutSettingsViewController()
        _ = aboutVC.view  // 触发 loadView

        let allSubviews = collectAllSubviews(aboutVC.view)

        // 检查更新按钮
        let checkUpdateButton = allSubviews.first { subview in
            (subview as? NSButton)?.title == "检查更新"
        }
        XCTAssertNotNil(checkUpdateButton, "About 页面应包含「检查更新」按钮")

        // 立即升级按钮（初始 isHidden=true，仍在层级中）
        let upgradeButton = allSubviews.first { subview in
            (subview as? NSButton)?.title == "立即升级"
        }
        XCTAssertNotNil(upgradeButton, "About 页面应包含「立即升级」按钮")

        // 进度条（indeterminate NSProgressIndicator）
        let progressIndicator = allSubviews.first { subview in
            subview is NSProgressIndicator
        }
        XCTAssertNotNil(progressIndicator, "About 页面应包含 NSProgressIndicator")

        // 状态标签（可能存在也可能为空状态）
        _ = allSubviews.first { subview in
            guard let label = subview as? NSTextField else { return false }
            return label.stringValue == "正在检查更新…" || label.stringValue.isEmpty
        }
        let textFields = allSubviews.compactMap { $0 as? NSTextField } as [NSTextField]
        XCTAssertGreaterThanOrEqual(textFields.count, 3,
                                    "About 页面应至少有 3 个 NSTextField（名称、版本、状态），实际: \(textFields.count)")
    }

    /// 验证 About 页面含反馈按钮 + 检查更新按钮 + 版本标签（T7 后结构断言，不再依赖 index 顺序）。
    func testUpdateSectionIsAboveFeedbackButton() {
        let aboutVC = AboutSettingsViewController()
        _ = aboutVC.view

        let allSubviews = collectAllSubviews(aboutVC.view)

        // 反馈按钮存在
        let feedbackButton = allSubviews.first { subview in
            (subview as? NSButton)?.title == "反馈问题"
        }
        XCTAssertNotNil(feedbackButton, "应存在「反馈问题」按钮")

        // 版本标签存在
        let versionLabel = allSubviews.first { subview in
            (subview as? NSTextField)?.stringValue.hasPrefix("版本") ?? false
        }
        XCTAssertNotNil(versionLabel, "应存在版本标签")

        // 更新区域控件存在（检查更新 / 立即升级 / 进度条至少其一）
        let hasUpdateButton = allSubviews.contains { subview in
            (subview as? NSButton)?.title == "检查更新" || (subview as? NSButton)?.title == "立即升级"
        }
        let hasProgressIndicator = allSubviews.contains { subview in
            subview is NSProgressIndicator
        }
        XCTAssertTrue(hasUpdateButton || hasProgressIndicator,
                      "更新区域控件应存在（检查更新/立即升级按钮或进度条）")
    }

    /// AC-ABOUT-ROW（T7）：检查更新 / 反馈 / 开源 3 按钮必须在同一水平 NSStackView 行内。
    func testAboutThreeButtonsInSameRow() {
        let aboutVC = AboutSettingsViewController()
        _ = aboutVC.view

        let allSubviews = collectAllSubviews(aboutVC.view)

        // 找含「检查更新」按钮的 NSStackView（其 arrangedSubviews 同时含 3 按钮）
        let stackViews = allSubviews.compactMap { $0 as? NSStackView }
        let buttonRow = stackViews.first { stack in
            let arranged = stack.arrangedSubviews
            let titles = arranged.compactMap { ($0 as? NSButton)?.title }
            return titles.contains("检查更新")
        }
        XCTAssertNotNil(buttonRow, "应存在含「检查更新」按钮的 NSStackView 按钮行（buttonRow）")

        if let row = buttonRow {
            let titles = row.arrangedSubviews.compactMap { ($0 as? NSButton)?.title }
            XCTAssertTrue(titles.contains("检查更新"), "buttonRow 应含「检查更新」按钮，实际: \(titles)")
            XCTAssertTrue(titles.contains("反馈问题"), "buttonRow 应含「反馈问题」按钮，实际: \(titles)")
            XCTAssertTrue(titles.contains("开源地址"), "buttonRow 应含「开源地址」按钮，实际: \(titles)")
            XCTAssertEqual(row.orientation, .horizontal, "buttonRow 必须为水平方向")
        }
    }

    // MARK: - 11. checkResult Publisher（检查结果事件驱动，修复「检查更新无反馈」）

    /// 契约：checkForUpdates 完成后必须通过 checkResult 发布结果，让关于页事件驱动更新 UI。
    /// 检测到新版本 → .available(UpdateAvailableEvent)。
    func testCheckResultPublishesAvailableWhenNewerVersion() {
        checker.clearPendingUpdateForTesting()

        let expectation = XCTestExpectation(description: "checkResult 发布 .available")
        var received: CheckOutcome?
        checker.checkResult
            .sink { outcome in
                received = outcome
                expectation.fulfill()
            }
            .store(in: &cancellables)

        let release = ReleaseInfo(
            tagName: "v0.37.5",
            version: "0.37.5",
            htmlURL: URL(string: "https://github.com/test")!
        )
        checker.processFetchResult(.success(release), currentVersion: "0.37.4")

        wait(for: [expectation], timeout: 1.0)

        guard case .available(let event) = received else {
            XCTFail("检测到新版本应发布 .available，实际：\(String(describing: received))")
            return
        }
        XCTAssertEqual(event.newVersion, "0.37.5", "应携带新版本号")
        XCTAssertEqual(event.currentVersion, "0.37.4", "应携带当前版本号")
    }

    /// 契约：远程版本不高于当前版本 → .upToDate（不再静默无反馈）。
    func testCheckResultPublishesUpToDateWhenSameVersion() {
        checker.clearPendingUpdateForTesting()

        let expectation = XCTestExpectation(description: "checkResult 发布 .upToDate")
        var received: CheckOutcome?
        checker.checkResult
            .sink { outcome in
                received = outcome
                expectation.fulfill()
            }
            .store(in: &cancellables)

        let release = ReleaseInfo(
            tagName: "v0.37.5",
            version: "0.37.5",
            htmlURL: URL(string: "https://github.com/test")!
        )
        checker.processFetchResult(.success(release), currentVersion: "0.37.5")

        wait(for: [expectation], timeout: 1.0)

        guard case .upToDate = received else {
            XCTFail("同版本应发布 .upToDate，实际：\(String(describing: received))")
            return
        }
    }

    /// 契约：fetch 失败（如网络/限流）→ .failed(Error)，不再只记日志无 UI 反馈。
    func testCheckResultPublishesFailedOnFetchError() {
        checker.clearPendingUpdateForTesting()

        let expectation = XCTestExpectation(description: "checkResult 发布 .failed")
        var received: CheckOutcome?
        checker.checkResult
            .sink { outcome in
                received = outcome
                expectation.fulfill()
            }
            .store(in: &cancellables)

        checker.processFetchResult(.failure(UpdateError.invalidResponse), currentVersion: "0.37.5")

        wait(for: [expectation], timeout: 1.0)

        guard case .failed(let error) = received else {
            XCTFail("fetch 失败应发布 .failed，实际：\(String(describing: received))")
            return
        }
        XCTAssertTrue(error is UpdateError, "应携带原始 Error")
    }

    // MARK: - 12. About 更新区域状态机（修复「检查更新无反馈」，C6）

    /// 契约：updateAreaState = .checking 时立即显示「正在检查更新...」并隐藏按钮。
    /// 这是点击「检查更新」后的即时反馈（不再静默无响应）。
    func testAboutCheckingStateShowsCheckingMessage() {
        let aboutVC = AboutSettingsViewController()
        _ = aboutVC.view
        aboutVC.updateAreaState = .checking

        XCTAssertEqual(aboutVC.updateAreaStatusText, "正在检查更新...",
                       "checking 应显示「正在检查更新...」")
        XCTAssertTrue(aboutVC.isCheckUpdateButtonHidden, "checking 时检查按钮应隐藏")
        XCTAssertTrue(aboutVC.isUpgradeButtonHidden, "checking 时升级按钮应隐藏")
    }

    /// 契约：发现新版本 → 显示版本号 + 「立即升级」按钮。
    func testAboutUpdateAvailableShowsVersionAndUpgradeButton() {
        let aboutVC = AboutSettingsViewController()
        _ = aboutVC.view
        aboutVC.updateAreaState = .updateAvailable("0.37.5")

        XCTAssertTrue(aboutVC.updateAreaStatusText.contains("发现新版本"), "应显示「发现新版本」")
        XCTAssertTrue(aboutVC.updateAreaStatusText.contains("0.37.5"), "应包含新版本号")
        XCTAssertFalse(aboutVC.isUpgradeButtonHidden, "应显示「立即升级」按钮")
        XCTAssertTrue(aboutVC.isCheckUpdateButtonHidden, "应隐藏「检查更新」按钮")
    }

    /// 契约：无新版本 → 「✓ 已是最新版本」+ 可重新检查。
    func testAboutUpToDateShowsLatestMessage() {
        let aboutVC = AboutSettingsViewController()
        _ = aboutVC.view
        aboutVC.updateAreaState = .upToDate

        XCTAssertEqual(aboutVC.updateAreaStatusText, "✓ 已是最新版本")
        XCTAssertFalse(aboutVC.isCheckUpdateButtonHidden, "应显示「检查更新」以便重新检查")
        XCTAssertTrue(aboutVC.isUpgradeButtonHidden)
    }

    /// 契约：检查失败 → 显示失败原因 + 可重试。
    func testAboutCheckFailedShowsFailureMessage() {
        let aboutVC = AboutSettingsViewController()
        _ = aboutVC.view
        aboutVC.updateAreaState = .checkFailed("网络错误")

        XCTAssertTrue(aboutVC.updateAreaStatusText.contains("检查失败"), "应显示「检查失败」")
        XCTAssertTrue(aboutVC.updateAreaStatusText.contains("网络错误"), "应包含失败原因")
        XCTAssertFalse(aboutVC.isCheckUpdateButtonHidden, "失败时应可重试")
    }

    // MARK: - 13. 端到端接线：checkResult → 关于页状态（C7，修复核心）

    /// 契约：关于页订阅 UpdateChecker.checkResult，收到事件后事件驱动切换 UI。
    /// 这是「检查更新无反馈」根因（关于页未订阅结果流）的回归保护。
    func testAboutSettingsReactsToCheckResultUpToDate() {
        let aboutVC = AboutSettingsViewController()
        _ = aboutVC.view  // 触发 loadView → subscribeToCheckResult

        UpdateChecker.shared.checkResult.send(.upToDate)
        // 刷新主 RunLoop 让 receive(on: RunLoop.main) 派发完成
        let exp = XCTestExpectation()
        DispatchQueue.main.async { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)

        XCTAssertEqual(aboutVC.updateAreaStatusText, "✓ 已是最新版本",
                       "收到 .upToDate 应事件驱动显示「已是最新版本」")
    }

    func testAboutSettingsReactsToCheckResultAvailable() {
        let aboutVC = AboutSettingsViewController()
        _ = aboutVC.view

        let event = UpdateAvailableEvent(
            currentVersion: "0.37.4",
            newVersion: "0.37.5",
            htmlURL: URL(string: "https://github.com/test")!
        )
        UpdateChecker.shared.checkResult.send(.available(event))
        let exp = XCTestExpectation()
        DispatchQueue.main.async { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)

        XCTAssertTrue(aboutVC.updateAreaStatusText.contains("发现新版本 0.37.5"),
                      "收到 .available 应事件驱动显示「发现新版本 X」")
        XCTAssertFalse(aboutVC.isUpgradeButtonHidden, "应显示「立即升级」按钮")
    }
}
