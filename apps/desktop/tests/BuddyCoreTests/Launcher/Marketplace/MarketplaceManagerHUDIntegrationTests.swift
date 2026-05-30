import XCTest
@testable import BuddyCore

/// 蓝队集成测试：MarketplaceManager + mock HUD，验证 4 处 NSLog 替换 + 并发锁 + reset helper。
///
/// 与红队 acceptance 互补：红队验证端到端契约；本文件聚焦 sync 路径的精确 HUD 调用次数 + 文案断言。
///
/// 测试类标 `@MainActor` 让 mock HUD 主线程内可见（避免 sendable warning）。
@MainActor
final class MarketplaceManagerHUDIntegrationTests: XCTestCase {

    private var testRoot: URL!
    private var pluginsDir: URL!
    private var marketplacePath: URL!
    private var metaPath: URL!
    private var syncLogPath: URL!
    private var trustFile: URL!
    private var trustStore: TrustStore!
    private var bundleRoot: URL!

    override func setUpWithError() throws {
        testRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "buddy-hud-int-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: testRoot, withIntermediateDirectories: true)

        pluginsDir = testRoot.appending(path: "launcher-plugins")
        marketplacePath = testRoot.appending(path: "marketplace.json")
        metaPath = testRoot.appending(path: "marketplace-meta.json")
        syncLogPath = testRoot.appending(path: "launcher-sync.log")
        trustFile = testRoot.appending(path: "launcher-trust.json")
        trustStore = TrustStore(file: trustFile)

        bundleRoot = testRoot.appending(path: "bundle")
        let mpDir = bundleRoot.appending(path: "Marketplace/plugins/translate")
        try FileManager.default.createDirectory(at: mpDir, withIntermediateDirectories: true)
        try makeMarketplaceData(translateVersion: "0.1.0").write(
            to: bundleRoot.appending(path: "Marketplace/marketplace.json")
        )
        try makePluginJSON(name: "translate", version: "0.1.0").write(
            to: mpDir.appending(path: "plugin.json")
        )

        IntegrationMockURLProtocol.reset()
    }

    override func tearDownWithError() throws {
        if let testRoot, FileManager.default.fileExists(atPath: testRoot.path) {
            try? FileManager.default.removeItem(at: testRoot)
        }
        IntegrationMockURLProtocol.reset()
    }

    // MARK: - Factory

    private func makeManager(
        urlSession: URLSession? = nil,
        remoteURL: URL? = nil,
        now: @escaping () -> Date = Date.init
    ) -> MarketplaceManager {
        let session = urlSession ?? makeMockSession()
        let remote = remoteURL ?? URL(string: "https://example.test/marketplace.json")!
        return MarketplaceManager(
            resolver: IntegrationStubResolver(),
            trustStore: trustStore,
            pluginsDir: pluginsDir,
            marketplacePath: marketplacePath,
            metaPath: metaPath,
            syncLogPath: syncLogPath,
            bundleProvider: { [self] in Bundle(url: bundleRoot) ?? Bundle.main },
            urlSession: session,
            now: now,
            remoteURL: remote
        )
    }

    private func makeMockSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [IntegrationMockURLProtocol.self]
        return URLSession(configuration: config)
    }

    private func makeMarketplaceData(translateVersion: String, includeWeather: Bool = false) -> Data {
        var plugins: [[String: Any]] = [[
            "name": "translate",
            "description": "translate plugin",
            "version": translateVersion,
            "author": ["name": "tester"],
            "source": "./plugins/translate"
        ]]
        if includeWeather {
            plugins.append([
                "name": "weather",
                "description": "weather plugin",
                "version": "0.1.0",
                "author": ["name": "tester"],
                "source": "./plugins/weather"
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

    private func makePluginJSON(name: String, version: String) -> Data {
        let root: [String: Any] = [
            "name": name,
            "version": version,
            "description": "demo",
            "keywords": [name],
            "mode": "prompt",
            "systemPrompt": "test",
            "maxIterations": 1
        ]
        return try! JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    }

    // MARK: - 1. sync 成功 + 单项 updated → HUD.show 调用 1 次 + 文案

    func test_sync_singleUpdated_callsHudShowWithVersionText() async throws {
        let mockHUD = MockHUD()
        let remote = URL(string: "https://example.test/marketplace.json")!
        let mgr = makeManager(remoteURL: remote, now: { Date(timeIntervalSince1970: 2_000_000_000) })
        mgr.configureHUD(mockHUD)

        // 先 seed local cache（version 0.1.0），再 stub remote 0.2.0
        try await mgr.seedFromBundle()
        IntegrationMockURLProtocol.stub(
            url: remote, status: 200,
            data: makeMarketplaceData(translateVersion: "0.2.0")
        )

        await mgr.syncFromRemote()

        XCTAssertEqual(mockHUD.showCount, 1, "单项 updated 应触发 1 次 HUD.show")
        XCTAssertEqual(mockHUD.lastText, "translate 已更新到 v0.2.0",
                       "文案应为 '<name> 已更新到 v<version>'")
    }

    // MARK: - 2. sync 连续 3 次失败 → HUD.show 触发 "无法连接 Market" 文案

    func test_sync_threeFailures_triggersConnectErrorText() async throws {
        let mockHUD = MockHUD()
        let remote = URL(string: "https://example.test/marketplace.json")!
        var ticker = 0
        let mgr = makeManager(
            remoteURL: remote,
            now: {
                ticker += 1
                return Date(timeIntervalSince1970: TimeInterval(3_000_000_000 + ticker * 7200))
            }
        )
        mgr.configureHUD(mockHUD)

        IntegrationMockURLProtocol.stub(url: remote, status: 500, data: Data("err".utf8))
        await mgr.syncFromRemote() // 1
        await mgr.syncFromRemote() // 2
        await mgr.syncFromRemote() // 3

        XCTAssertEqual(mockHUD.showCount, 1,
                       "前 2 次失败不应触发 HUD（counter < 3），第 3 次才触发")
        XCTAssertTrue(mockHUD.lastText?.contains("无法连接 Market") == true,
                      "文案应含 '无法连接 Market'，实际: \(mockHUD.lastText ?? "nil")")
    }

    // MARK: - 3. sync 成功 + noop（diff 空）→ HUD.show 不调用

    func test_sync_noopDiff_doesNotCallHud() async throws {
        let mockHUD = MockHUD()
        let remote = URL(string: "https://example.test/marketplace.json")!
        let mgr = makeManager(remoteURL: remote, now: { Date(timeIntervalSince1970: 2_100_000_000) })
        mgr.configureHUD(mockHUD)

        try await mgr.seedFromBundle()
        // remote 内容与本地 cache 完全相同 → noop
        IntegrationMockURLProtocol.stub(
            url: remote, status: 200,
            data: makeMarketplaceData(translateVersion: "0.1.0")
        )

        await mgr.syncFromRemote()

        XCTAssertEqual(mockHUD.showCount, 0, "noop diff 不应触发 HUD")
    }

    // MARK: - 4. HUD 为 nil 时 sync 不 crash（短路）

    func test_sync_nilHud_doesNotCrash() async throws {
        let remote = URL(string: "https://example.test/marketplace.json")!
        let mgr = makeManager(remoteURL: remote, now: { Date(timeIntervalSince1970: 2_200_000_000) })
        // 不调 configureHUD，hud == nil

        try await mgr.seedFromBundle()
        IntegrationMockURLProtocol.stub(
            url: remote, status: 200,
            data: makeMarketplaceData(translateVersion: "0.2.0")
        )

        await mgr.syncFromRemote()
        XCTAssertNil(mgr.hud, "hud 仍应为 nil")
    }

    // MARK: - 5. 并发 sync：第 2 个写 log "concurrent-skipped"

    func test_sync_concurrent_secondLogsConcurrentSkipped() async throws {
        let mockHUD = MockHUD()
        let remote = URL(string: "https://example.test/marketplace.json")!
        var ticker = 0
        let mgr = makeManager(
            remoteURL: remote,
            now: {
                ticker += 1
                return Date(timeIntervalSince1970: TimeInterval(2_300_000_000 + ticker * 7200))
            }
        )
        mgr.configureHUD(mockHUD)
        IntegrationMockURLProtocol.stub(
            url: remote, status: 200,
            data: makeMarketplaceData(translateVersion: "0.1.0")
        )

        // 启 2 个并发 task
        async let a: Void = mgr.syncFromRemote()
        async let b: Void = mgr.syncFromRemote()
        _ = await (a, b)

        // 验证 log 内至少出现一次 "concurrent-skipped"
        let logData = try Data(contentsOf: syncLogPath)
        let logStr = String(data: logData, encoding: .utf8) ?? ""
        XCTAssertTrue(logStr.contains("concurrent-skipped"),
                      "并发 sync 第 2 次应记录 concurrent-skipped，实际 log:\n\(logStr)")
    }

    // MARK: - 6. resetHUDForTesting 清零 hud + 锁

    func test_resetHUDForTesting_clearsHudAndUnlocks() async throws {
        let mockHUD = MockHUD()
        let remote = URL(string: "https://example.test/marketplace.json")!
        // 推进时间 ticker，避免 1h debounce 跳过第二次 sync
        var ticker = 0
        let mgr = makeManager(
            remoteURL: remote,
            now: {
                ticker += 1
                return Date(timeIntervalSince1970: TimeInterval(2_400_000_000 + ticker * 7200))
            }
        )
        mgr.configureHUD(mockHUD)
        try await mgr.seedFromBundle()
        IntegrationMockURLProtocol.stub(
            url: remote, status: 200,
            data: makeMarketplaceData(translateVersion: "0.1.0")
        )
        await mgr.syncFromRemote() // 让 syncInProgress 走完
        mgr.resetHUDForTesting()
        XCTAssertNil(mgr.hud, "resetHUDForTesting 后 hud 应为 nil")

        // 重新注入 + sync 仍可工作（说明 syncInProgress 已 false）
        let mockHUD2 = MockHUD()
        mgr.configureHUD(mockHUD2)
        IntegrationMockURLProtocol.stub(
            url: remote, status: 200,
            data: makeMarketplaceData(translateVersion: "0.5.0")
        )
        await mgr.syncFromRemote()
        XCTAssertGreaterThanOrEqual(mockHUD2.showCount, 1,
                                    "reset 后注入新 HUD 应能继续工作")
    }

    // MARK: - 7. configureHUD 同实例两次 no-op

    func test_configureHUD_sameInstanceTwice_isNoOp() {
        let mockHUD = MockHUD()
        let mgr = makeManager()
        mgr.configureHUD(mockHUD)
        mgr.configureHUD(mockHUD)
        XCTAssertTrue(mgr.hud === mockHUD)
    }

    // MARK: - 8. diff helper: 多项 → 计数文本

    func test_makeDiffText_multipleItems_usesCountText() throws {
        let mgr = makeManager()
        let manifestData = makeMarketplaceData(translateVersion: "0.2.0", includeWeather: true)
        let manifest = try JSONDecoder().decode(MarketplaceManifest.self, from: manifestData)
        let text = mgr.makeDiffText(
            added: ["weather"],
            updated: ["translate"],
            remoteManifest: manifest
        )
        XCTAssertEqual(text, "Market 同步完成：1 个已更新，1 个新增")
    }

    // MARK: - 9. diff helper: added 单项 → "新增插件"文案

    func test_makeDiffText_singleAdded_usesAddedText() throws {
        let mgr = makeManager()
        let manifestData = makeMarketplaceData(translateVersion: "0.2.0", includeWeather: true)
        let manifest = try JSONDecoder().decode(MarketplaceManifest.self, from: manifestData)
        let text = mgr.makeDiffText(
            added: ["weather"],
            updated: [],
            remoteManifest: manifest
        )
        XCTAssertEqual(text, "新增插件：weather")
    }
}

// MARK: - MockHUD

@MainActor
private final class MockHUD: MarketHUDDisplaying {
    private(set) var showCount: Int = 0
    private(set) var dismissCount: Int = 0
    private(set) var lastText: String?
    private(set) var lastActions: [MarketHUD.Action] = []

    func show(text: String, actions: [MarketHUD.Action]) {
        showCount += 1
        lastText = text
        lastActions = actions
    }

    func dismiss() {
        dismissCount += 1
    }
}

// MARK: - IntegrationStubResolver

private final class IntegrationStubResolver: PluginSourceResolving {
    func resolve(_ source: PluginSourceConfig, bundleRoot: URL?) async throws -> URL {
        switch source {
        case .localSubdir(let path):
            guard let bundleRoot else {
                throw LauncherError.pluginInvalid("IntegrationStubResolver: missing bundleRoot")
            }
            let resolved = bundleRoot.appending(path: path)
            return resolved
        case .file(let path):
            return URL(fileURLWithPath: path)
        case .gitURL, .gitSubdir:
            throw LauncherError.pluginInvalid("IntegrationStubResolver: git not supported")
        }
    }
}

// MARK: - IntegrationMockURLProtocol

final class IntegrationMockURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var stubs: [URL: (data: Data?, status: Int, error: Error?)] = [:]

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        stubs.removeAll()
    }
    static func stub(url: URL, status: Int, data: Data) {
        lock.lock(); defer { lock.unlock() }
        stubs[url] = (data, status, nil)
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

        if let stub {
            if let error = stub.error {
                client?.urlProtocol(self, didFailWithError: error)
                return
            }
            let response = HTTPURLResponse(
                url: url, statusCode: stub.status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if let data = stub.data {
                client?.urlProtocol(self, didLoad: data)
            }
            client?.urlProtocolDidFinishLoading(self)
        } else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
        }
    }

    override func stopLoading() {}
}
