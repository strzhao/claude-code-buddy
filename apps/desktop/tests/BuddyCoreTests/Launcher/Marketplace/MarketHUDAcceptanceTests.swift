import XCTest
import AppKit
@testable import BuddyCore

/// Tier 0 红队验收测试 —— 独立基于 task 006 设计文档契约。
///
/// 信息隔离原则：
/// - 不读蓝队新写的 MarketHUD.swift 或 MarketplaceManager.swift 的 HUD/lock 修改部分。
/// - 仅依赖以下契约：
///   - protocol `MarketHUDDisplaying { func show(text:actions:); func dismiss() }`，`@MainActor` 方法
///   - `@MainActor final class MarketHUD: MarketHUDDisplaying`
///   - `MarketHUD.Action { let label: String; let handler: () -> Void }`
///   - `var dismissDelay: TimeInterval` 可注入（B5）
///   - `MarketplaceManager.hud` private(set) optional
///   - `MarketplaceManager.configureHUD(_:)`：同实例 no-op，不同实例 precondition trap
///   - `MarketplaceManager.resetHUDForTesting()` internal helper
///   - syncInProgress lock（仅 sync-vs-sync）
///
/// 命名前缀: test_AT<N>_<场景>
///
/// AT12 不自动化：configureHUD 不同实例期望 precondition trap，XCTest 无原生 XCTAssertCrashes，
/// 标 `// AT12: covered by precondition; manual reasoning only`
// swiftlint:disable type_body_length file_length function_body_length
@MainActor
final class MarketHUDAcceptanceTests: XCTestCase {

    // MARK: - Test scratch dir + paths

    private var testRoot: URL!
    private var testPluginsDir: URL!
    private var testMarketplacePath: URL!
    private var testMetaPath: URL!
    private var testSyncLogPath: URL!
    private var testTrustFile: URL!
    private var testTrustStore: TrustStore!
    private var testBundleRoot: URL!

    override func setUpWithError() throws {
        testRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "buddy-test-hud-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: testRoot, withIntermediateDirectories: true)

        testPluginsDir = testRoot.appending(path: "launcher-plugins")
        testMarketplacePath = testRoot.appending(path: "marketplace.json")
        testMetaPath = testRoot.appending(path: "marketplace-meta.json")
        testSyncLogPath = testRoot.appending(path: "launcher-sync.log")
        testTrustFile = testRoot.appending(path: "launcher-trust.json")
        testTrustStore = TrustStore(file: testTrustFile)

        // 仿 bundle 资源
        testBundleRoot = testRoot.appending(path: "bundle")
        try FileManager.default.createDirectory(
            at: testBundleRoot.appending(path: "Marketplace/plugins/translate"),
            withIntermediateDirectories: true
        )
        try minimalMarketplaceJSON(includeHello: false).write(
            to: testBundleRoot.appending(path: "Marketplace/marketplace.json")
        )
        try minimalPluginJSON(name: "translate").write(
            to: testBundleRoot.appending(path: "Marketplace/plugins/translate/plugin.json")
        )

        HUDMockURLProtocol.reset()
    }

    override func tearDownWithError() throws {
        if let testRoot, FileManager.default.fileExists(atPath: testRoot.path) {
            try? FileManager.default.removeItem(at: testRoot)
        }
        HUDMockURLProtocol.reset()
    }

    // MARK: - Factories

    private func makeManager(
        urlSession: URLSession? = nil,
        remoteURL: URL? = nil,
        now: @escaping () -> Date = Date.init,
        resolver: PluginSourceResolving = HUDStubResolver()
    ) -> MarketplaceManager {
        let session = urlSession ?? makeMockSession()
        let remote = remoteURL ?? URL(string: "https://example.test/marketplace.json")!
        let bundleProv: () -> Bundle = { [self] in
            Bundle(url: testBundleRoot) ?? Bundle.main
        }
        return MarketplaceManager(
            resolver: resolver,
            trustStore: testTrustStore,
            pluginsDir: testPluginsDir,
            marketplacePath: testMarketplacePath,
            metaPath: testMetaPath,
            syncLogPath: testSyncLogPath,
            bundleProvider: bundleProv,
            urlSession: session,
            now: now,
            remoteURL: remote
        )
    }

    private func makeMockSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HUDMockURLProtocol.self]
        return URLSession(configuration: config)
    }

    // MARK: - JSON fixtures

    private func minimalMarketplaceJSON(
        translateVersion: String = "0.1.0",
        includeHello: Bool = true,
        extraPlugins: [(name: String, version: String)] = []
    ) -> Data {
        var plugins: [[String: Any]] = []
        if includeHello {
            plugins.append([
                "name": "hello",
                "description": "hello demo",
                "version": "0.1.0",
                "author": ["name": "tester"],
                "source": "./plugins/hello"
            ])
        }
        plugins.append([
            "name": "translate",
            "description": "translate demo",
            "version": translateVersion,
            "author": ["name": "tester"],
            "source": "./plugins/translate"
        ])
        for extra in extraPlugins {
            plugins.append([
                "name": extra.name,
                "description": "\(extra.name) demo",
                "version": extra.version,
                "author": ["name": "tester"],
                "source": "./plugins/\(extra.name)"
            ])
        }
        let root: [String: Any] = [
            "schemaVersion": 1,
            "name": "buddy-official",
            "description": "test fixture",
            "owner": ["name": "tester"],
            "plugins": plugins
        ]
        return try! JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    }

    private func minimalPluginJSON(name: String) -> Data {
        let root: [String: Any] = [
            "name": name,
            "version": "0.1.0",
            "description": "test plugin",
            "keywords": [name],
            "mode": "prompt",
            "systemPrompt": "you are a test",
            "maxIterations": 1
        ]
        return try! JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    }

    // MARK: ============ MarketHUD UI 行为（AT01-AT05）============

    /// AT01 MarketHUD.show → panel.isVisible == true
    func test_AT01_show_makesPanelVisible() async throws {
        let hud = MarketHUD()
        hud.dismissDelay = 60  // 防止自隐影响断言
        hud.show(text: "hello", actions: [])

        // 等一个 runloop tick 让 panel 完成 orderFront
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertTrue(hud.isVisible,
                      "show 后 HUD 应可见（依赖 MarketHUD.isVisible 计算属性或 internal panel）")
    }

    /// AT02 dismissDelay=0.1s 注入：show → sleep(0.2s) → panel 不可见
    func test_AT02_dismissDelay_autoDismisses() async throws {
        let hud = MarketHUD()
        hud.dismissDelay = 0.1
        hud.show(text: "auto", actions: [])

        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertFalse(hud.isVisible, "0.1s dismissDelay + sleep 0.2s 后应自隐")
    }

    /// AT03 重复 show 重置倒计时：dismissDelay=1.0s → show → sleep(0.6s) → show → sleep(0.5s) → 仍可见
    ///
    /// 时序余量故意放大（原 0.3/0.2s 末段余量仅 0.1s，CI runner 调度抖动会让 Task.sleep 实际超时，
    /// 翻转 isVisible 结果 → flaky）。1.0s 倒计时 + 0.5s 末段 sleep 留 0.5s 余量，抗 CI 抖动。
    func test_AT03_repeatedShow_resetsDismissTimer() async throws {
        let hud = MarketHUD()
        hud.dismissDelay = 1.0
        hud.show(text: "first", actions: [])
        try await Task.sleep(nanoseconds: 600_000_000)  // 0.6s < 1.0s 仍可见
        hud.show(text: "second", actions: [])  // 重置倒计时
        try await Task.sleep(nanoseconds: 500_000_000)  // 累计 1.1s > 1.0s（未重置会 dismiss），新倒计时仅过 0.5s < 1.0s

        XCTAssertTrue(hud.isVisible,
                      "重复 show 应重置倒计时，新倒计时 0.5s < 1.0s 时仍可见")
    }

    /// AT04 dismiss() → panel.isVisible == false
    func test_AT04_dismiss_hidesPanel() async throws {
        let hud = MarketHUD()
        hud.dismissDelay = 60
        hud.show(text: "to-dismiss", actions: [])
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertTrue(hud.isVisible, "前置：show 后应可见")

        hud.dismiss()
        XCTAssertFalse(hud.isVisible, "dismiss() 后应不可见")
    }

    /// AT05 Action handler 触发：构造 Action(label:"X", handler:{ flag = true }) → 直接调 sender.handler() → flag == true
    func test_AT05_actionHandler_invokedDirectly() {
        var flag = false
        let action = MarketHUD.Action(label: "X", handler: { flag = true })
        action.handler()
        XCTAssertTrue(flag, "Action.handler() 直接调用应触发闭包")
        XCTAssertEqual(action.label, "X")
    }

    // MARK: ============ MarketplaceManager 注入 HUD（AT06-AT09, AT14）============

    /// AT06 sync 成功 + diff 单项 updated=[translate] → mockHUD.show 被调，text == "translate 已更新到 v0.2.0"
    func test_AT06_singleUpdated_triggersHUDShowWithVersion() async throws {
        let remote = URL(string: "https://example.test/marketplace.json")!
        let mgr = makeManager(urlSession: makeMockSession(), remoteURL: remote)
        // 先 seed 让本地 cache 含 translate v0.1.0
        try await mgr.seedFromBundle()

        let mockHUD = MockMarketHUD()
        mgr.configureHUD(mockHUD)

        // 远程返回 translate v0.2.0
        HUDMockURLProtocol.stub(url: remote, status: 200,
                                data: minimalMarketplaceJSON(translateVersion: "0.2.0",
                                                             includeHello: false))
        await mgr.syncFromRemote()

        XCTAssertEqual(mockHUD.shows.count, 1, "应触发 1 次 show")
        XCTAssertEqual(mockHUD.shows.first?.text, "translate 已更新到 v0.2.0",
                       "单项 updated 文本应为 '<name> 已更新到 v<version>'")
    }

    /// AT07 sync 失败累计 3 次（mock 连续 3 次 throw）→ mockHUD.show 被调，text 含"无法连接 Market"
    func test_AT07_threeConsecutiveFailures_triggersHUDShowWithConnectError() async throws {
        let remote = URL(string: "https://example.test/marketplace.json")!
        HUDMockURLProtocol.stubError(
            url: remote,
            error: NSError(domain: "test", code: -1, userInfo: nil)
        )

        // 每次都用新 now 避开 debounce
        var counter = 0
        let mgr = makeManager(
            urlSession: makeMockSession(),
            remoteURL: remote,
            now: {
                counter += 1
                return Date(timeIntervalSince1970: TimeInterval(2_000_000_000 + counter * 7200))
            }
        )
        let mockHUD = MockMarketHUD()
        mgr.configureHUD(mockHUD)

        await mgr.syncFromRemote()
        await mgr.syncFromRemote()
        await mgr.syncFromRemote()

        // 至少在第 3 次时触发了一次"无法连接 Market" HUD
        let connectShow = mockHUD.shows.first { $0.text.contains("无法连接 Market") }
        XCTAssertNotNil(connectShow, "3 次失败后应触发 HUD show，text 含 '无法连接 Market'，实际 shows: \(mockHUD.shows.map { $0.text })")
    }

    /// AT08 sync 成功 + diff 空 (noop) → mockHUD.show 不被调
    func test_AT08_noopDiff_doesNotTriggerHUD() async throws {
        let remote = URL(string: "https://example.test/marketplace.json")!
        let mgr = makeManager(urlSession: makeMockSession(), remoteURL: remote)
        // 先 seed（本地 cache 与远程相同）
        try await mgr.seedFromBundle()

        let mockHUD = MockMarketHUD()
        mgr.configureHUD(mockHUD)

        // 远程返回与本地完全相同的 manifest
        HUDMockURLProtocol.stub(url: remote, status: 200,
                                data: minimalMarketplaceJSON(includeHello: false))
        await mgr.syncFromRemote()

        XCTAssertEqual(mockHUD.shows.count, 0,
                       "noop diff 不应触发 HUD show，实际: \(mockHUD.shows.map { $0.text })")
    }

    /// AT09 HUD 为 nil（默认 init）→ sync 触发 toast 路径不 crash（`?.` 短路）
    func test_AT09_nilHUD_syncDoesNotCrash() async throws {
        let remote = URL(string: "https://example.test/marketplace.json")!
        let mgr = makeManager(urlSession: makeMockSession(), remoteURL: remote)
        try await mgr.seedFromBundle()
        // 不 configureHUD —— hud 保持 nil

        HUDMockURLProtocol.stub(url: remote, status: 200,
                                data: minimalMarketplaceJSON(translateVersion: "0.2.0",
                                                             includeHello: false))
        // 不应 crash
        await mgr.syncFromRemote()
        XCTAssertTrue(true, "HUD nil 时 sync 触发 toast 路径应短路不 crash")
    }

    /// AT14 diff 多项 (updated=["translate"] + added=["weather", "news"]) → mockHUD.show 被调，
    /// text == "Market 同步完成：1 个已更新，2 个新增"
    /// (设计文档示例文案；契约：多项时计数文本不丢信息)
    func test_AT14_multipleDiffs_triggersHUDShowWithCountText() async throws {
        let remote = URL(string: "https://example.test/marketplace.json")!
        let mgr = makeManager(urlSession: makeMockSession(), remoteURL: remote)
        try await mgr.seedFromBundle()  // cache 仅含 translate v0.1.0

        let mockHUD = MockMarketHUD()
        mgr.configureHUD(mockHUD)

        // 远程：translate 升 v0.2.0 (updated=1) + weather + news 新增 (added=2)
        HUDMockURLProtocol.stub(
            url: remote, status: 200,
            data: minimalMarketplaceJSON(
                translateVersion: "0.2.0",
                includeHello: false,
                extraPlugins: [(name: "weather", version: "0.1.0"),
                               (name: "news", version: "0.1.0")]
            )
        )
        await mgr.syncFromRemote()

        XCTAssertEqual(mockHUD.shows.count, 1, "多项 diff 应触发 1 次 show")
        let text = mockHUD.shows.first?.text ?? ""
        // 设计文档契约：多项计数文本不丢信息，格式 "Market 同步完成：N 个已更新，M 个新增"
        XCTAssertTrue(text.hasPrefix("Market 同步完成："),
                      "多项 diff 文案应以 'Market 同步完成：' 开头，实际: \(text)")
        XCTAssertTrue(text.contains("1 个已更新"),
                      "应含 '1 个已更新'，实际: \(text)")
        XCTAssertTrue(text.contains("2 个新增"),
                      "应含 '2 个新增'，实际: \(text)")
    }

    // MARK: ============ 并发互斥（AT10）============

    /// AT10 syncFromRemote 并发：手动 launch 2 个 Task { await mgr.syncFromRemote() }
    /// → 第 2 个 log "concurrent-skipped"
    func test_AT10_concurrentSync_secondLogsSkipped() async throws {
        let remote = URL(string: "https://example.test/marketplace.json")!
        // 用 slow stub 拉长 sync 时长，让两个 Task 真正重叠
        HUDMockURLProtocol.stubSlow(
            url: remote, status: 200,
            data: minimalMarketplaceJSON(translateVersion: "0.2.0", includeHello: false),
            delayMillis: 300
        )

        let mgr = makeManager(urlSession: makeMockSession(), remoteURL: remote)

        // 两个 Task 并发触发
        async let t1: Void = mgr.syncFromRemote()
        // 让 t1 先进入临界区
        try await Task.sleep(nanoseconds: 30_000_000)
        async let t2: Void = mgr.syncFromRemote()
        _ = await (t1, t2)

        let logText = (try? String(contentsOf: testSyncLogPath, encoding: .utf8)) ?? ""
        XCTAssertTrue(
            logText.contains("concurrent-skipped"),
            "第 2 个并发 sync 应写 log 含 'concurrent-skipped'，实际 log: \(logText.prefix(500))"
        )
    }

    // MARK: ============ configureHUD / resetHUDForTesting（AT11-AT13）============

    /// AT11 configureHUD 同实例调用两次 → no-op（hud 仍 === 第一次注入的）
    func test_AT11_configureHUD_sameInstanceTwice_isNoOp() {
        let mgr = makeManager()
        let mockHUD = MockMarketHUD()
        mgr.configureHUD(mockHUD)
        mgr.configureHUD(mockHUD)  // 同实例第二次应 no-op
        XCTAssertTrue(mgr.hud === mockHUD, "同实例两次 configureHUD 后 hud 仍 === 原实例")
    }

    // AT12: covered by precondition; manual reasoning only
    // configureHUD 不同实例期望 precondition trap，XCTest 无原生 XCTAssertCrashes，仅注释。

    /// AT13 resetHUDForTesting → manager.hud == nil + syncInProgress == false
    func test_AT13_resetHUDForTesting_clearsHudAndLock() async throws {
        let mgr = makeManager()
        let mockHUD = MockMarketHUD()
        mgr.configureHUD(mockHUD)
        XCTAssertNotNil(mgr.hud)

        mgr.resetHUDForTesting()
        XCTAssertNil(mgr.hud, "resetHUDForTesting 后 hud 应为 nil")
        // syncInProgress 私有 —— 通过行为间接验证：reset 后能再次 sync 不被锁
        let remote = URL(string: "https://example.test/marketplace.json")!
        HUDMockURLProtocol.stub(url: remote, status: 200,
                                data: minimalMarketplaceJSON(includeHello: false))
        await mgr.syncFromRemote()  // 不应被旧 syncInProgress 卡住
        let logText = (try? String(contentsOf: testSyncLogPath, encoding: .utf8)) ?? ""
        XCTAssertFalse(logText.contains("concurrent-skipped"),
                       "reset 后首次 sync 不应被 syncInProgress 锁住")
    }
}

// MARK: - MockMarketHUD

/// 实现 MarketHUDDisplaying 协议，记录 show calls。
@MainActor
private final class MockMarketHUD: MarketHUDDisplaying {
    struct ShowCall {
        let text: String
        let actions: [MarketHUD.Action]
    }
    var shows: [ShowCall] = []
    var dismissCount: Int = 0

    func show(text: String, actions: [MarketHUD.Action]) {
        shows.append(ShowCall(text: text, actions: actions))
    }

    func dismiss() {
        dismissCount += 1
    }
}

// MARK: - HUDStubResolver

private final class HUDStubResolver: PluginSourceResolving {
    func resolve(_ source: PluginSourceConfig, bundleRoot: URL?) async throws -> URL {
        switch source {
        case .localSubdir(let path):
            guard let bundleRoot else {
                throw LauncherError.pluginInvalid("HUDStubResolver: missing bundleRoot")
            }
            let resolved = bundleRoot.appending(path: path)
            // 自动创建缺失的 plugin.json（让 added 路径下 weather/news 等不在 bundle 的插件也能被 resolver "解析"）
            let pluginJSON = resolved.appending(path: "plugin.json")
            if !FileManager.default.fileExists(atPath: pluginJSON.path) {
                try? FileManager.default.createDirectory(
                    at: resolved, withIntermediateDirectories: true
                )
                let name = resolved.lastPathComponent
                let root: [String: Any] = [
                    "name": name,
                    "version": "0.1.0",
                    "description": "stub",
                    "keywords": [name],
                    "mode": "prompt",
                    "systemPrompt": "stub",
                    "maxIterations": 1
                ]
                let data = try JSONSerialization.data(withJSONObject: root)
                try? data.write(to: pluginJSON)
            }
            return resolved
        case .file(let path):
            return URL(fileURLWithPath: path)
        case .gitURL, .gitSubdir:
            throw LauncherError.pluginInvalid("HUDStubResolver: git not supported")
        }
    }
}

// MARK: - HUDMockURLProtocol

/// 自包含 URLProtocol mock（支持 slow stub 触发并发）。
final class HUDMockURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var stubs: [URL: (data: Data?, status: Int, error: Error?, delayMs: Int)] = [:]

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        stubs.removeAll()
    }
    static func stub(url: URL, status: Int, data: Data) {
        lock.lock(); defer { lock.unlock() }
        stubs[url] = (data, status, nil, 0)
    }
    static func stubError(url: URL, error: Error) {
        lock.lock(); defer { lock.unlock() }
        stubs[url] = (nil, 0, error, 0)
    }
    static func stubSlow(url: URL, status: Int, data: Data, delayMillis: Int) {
        lock.lock(); defer { lock.unlock() }
        stubs[url] = (data, status, nil, delayMillis)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        Self.lock.lock()
        let stub = Self.stubs[url]
        Self.lock.unlock()

        guard let stub else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }

        let deliver: () -> Void = { [weak self] in
            guard let self else { return }
            if let error = stub.error {
                self.client?.urlProtocol(self, didFailWithError: error)
                return
            }
            let response = HTTPURLResponse(
                url: url,
                statusCode: stub.status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if let data = stub.data {
                self.client?.urlProtocol(self, didLoad: data)
            }
            self.client?.urlProtocolDidFinishLoading(self)
        }

        if stub.delayMs > 0 {
            DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(stub.delayMs)) {
                deliver()
            }
        } else {
            deliver()
        }
    }

    override func stopLoading() {}
}
