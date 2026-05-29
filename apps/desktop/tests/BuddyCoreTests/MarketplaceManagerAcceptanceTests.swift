import XCTest
@testable import BuddyCore

/// Tier 0 红队验收测试 —— 独立基于 task 003 设计文档契约。
///
/// 信息隔离原则：
/// - 不读 MarketplaceManager.swift 蓝队实现。
/// - 仅依赖契约：seedFromBundle/syncFromRemote/install/migrateLegacy/reseed/inspect 公开签名 +
///   MarketplaceManifest/MarketplacePlugin schema + TrustRecord struct + LauncherError 错误契约。
///
/// 命名前缀: test_AT<N>_<场景>
/// swiftlint:disable type_body_length file_length function_body_length
final class MarketplaceManagerAcceptanceTests: XCTestCase {

    // MARK: - Test scratch dir + paths

    private var testRoot: URL!
    private var testPluginsDir: URL!
    private var testMarketplacePath: URL!
    private var testMetaPath: URL!
    private var testSyncLogPath: URL!
    private var testTrustFile: URL!
    private var testTrustStore: TrustStore!
    private var testBundleRoot: URL!  // 仿 bundle 内 Marketplace 资源根

    override func setUpWithError() throws {
        testRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "buddy-test-mm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: testRoot, withIntermediateDirectories: true)

        testPluginsDir = testRoot.appending(path: "launcher-plugins")
        testMarketplacePath = testRoot.appending(path: "marketplace.json")
        testMetaPath = testRoot.appending(path: "marketplace-meta.json")
        testSyncLogPath = testRoot.appending(path: "launcher-sync.log")
        testTrustFile = testRoot.appending(path: "launcher-trust.json")
        testTrustStore = TrustStore(file: testTrustFile)

        // 创建仿 bundle 资源：testBundleRoot/Marketplace/marketplace.json + plugins/<name>/plugin.json
        testBundleRoot = testRoot.appending(path: "bundle")
        try FileManager.default.createDirectory(
            at: testBundleRoot.appending(path: "Marketplace/plugins/hello"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: testBundleRoot.appending(path: "Marketplace/plugins/translate"),
            withIntermediateDirectories: true
        )
        try minimalMarketplaceJSON().write(
            to: testBundleRoot.appending(path: "Marketplace/marketplace.json")
        )
        try minimalPluginJSON(name: "hello").write(
            to: testBundleRoot.appending(path: "Marketplace/plugins/hello/plugin.json")
        )
        try minimalPluginJSON(name: "translate").write(
            to: testBundleRoot.appending(path: "Marketplace/plugins/translate/plugin.json")
        )

        MarketplaceMockURLProtocol.reset()
    }

    override func tearDownWithError() throws {
        if let testRoot, FileManager.default.fileExists(atPath: testRoot.path) {
            try? FileManager.default.removeItem(at: testRoot)
        }
        MarketplaceMockURLProtocol.reset()
    }

    // MARK: - Factories

    /// 构造被测 MarketplaceManager，注入全部 testable 路径。
    /// 使用 default resolver（不在 seed 场景触发 git，因为我们用 localSubdir）。
    private func makeManager(
        urlSession: URLSession? = nil,
        remoteURL: URL? = nil,
        now: @escaping () -> Date = Date.init,
        resolver: PluginSourceResolving = StubResolver()
    ) -> MarketplaceManager {
        let session = urlSession ?? makeMockSession()
        let remote = remoteURL ?? URL(string: "https://example.test/marketplace.json")!
        let bundleProv: () -> Bundle = { [self] in BundleStub.make(rootURL: testBundleRoot) }
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
        config.protocolClasses = [MarketplaceMockURLProtocol.self]
        return URLSession(configuration: config)
    }

    // MARK: - JSON fixtures

    private func minimalMarketplaceJSON(
        translateVersion: String = "0.1.0",
        includeHello: Bool = true
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

    private func legacyPluginJSON(name: String) -> Data {
        // legacy builtin-* plugin.json 用 prompt-mode（与现网 builtin-translate 一致）
        return minimalPluginJSON(name: name)
    }

    private func schemaV99JSON() -> Data {
        let root: [String: Any] = [
            "schemaVersion": 99,
            "name": "future",
            "owner": ["name": "x"],
            "plugins": []
        ]
        return try! JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    }

    // MARK: ============ migrateLegacy 系列 ============

    /// AT01 首次迁移：旧 dir + 旧 trust 在，新都不在 → Phase1+1.5+2 全做
    func test_AT01_migrateLegacy_fresh_fullMigration() throws {
        // 准备旧目录
        let oldDir = testPluginsDir.appending(path: "builtin-translate")
        try FileManager.default.createDirectory(at: oldDir, withIntermediateDirectories: true)
        try legacyPluginJSON(name: "builtin-translate")
            .write(to: oldDir.appending(path: "plugin.json"))
        // 准备旧 trust
        let oldRecord = TrustRecord(
            trustKey: "prompt:abc123def4567890",
            pluginName: "builtin-translate",
            approvedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        try testTrustStore.addRecord(oldRecord)

        let mgr = makeManager()
        try mgr.migrateLegacy()

        let newDir = testPluginsDir.appending(path: "translate")
        XCTAssertTrue(FileManager.default.fileExists(atPath: newDir.path),
                      "新目录 translate 应被创建")
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldDir.path),
                       "旧目录 builtin-translate 应被删除")
        let records = try testTrustStore.list()
        XCTAssertTrue(records.contains { $0.pluginName == "translate" },
                      "新 trust translate 应存在")
        XCTAssertFalse(records.contains { $0.pluginName == "builtin-translate" },
                       "旧 trust builtin-translate 应被删除")
    }

    /// AT02 Phase 1 之后 crash：旧 dir+旧 trust 在 / 新 dir 在 / 新 trust 不在 → 再次调能补全
    func test_AT02_migrateLegacy_resumeAfterPhase1() throws {
        // 仿 Phase 1 后 crash：旧+新 dir 都在；旧 trust 在；新 trust 没在
        let oldDir = testPluginsDir.appending(path: "builtin-translate")
        let newDir = testPluginsDir.appending(path: "translate")
        try FileManager.default.createDirectory(at: oldDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: newDir, withIntermediateDirectories: true)
        try legacyPluginJSON(name: "builtin-translate")
            .write(to: oldDir.appending(path: "plugin.json"))
        try minimalPluginJSON(name: "translate")
            .write(to: newDir.appending(path: "plugin.json"))
        try testTrustStore.addRecord(TrustRecord(
            trustKey: "prompt:abc123def4567890",
            pluginName: "builtin-translate",
            approvedAt: Date(timeIntervalSince1970: 1_700_000_000)
        ))

        let mgr = makeManager()
        try mgr.migrateLegacy()

        let records = try testTrustStore.list()
        XCTAssertTrue(records.contains { $0.pluginName == "translate" },
                      "新 trust 应被补登记（Phase 1.5）")
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldDir.path),
                       "旧目录应被 Phase 2 删")
        XCTAssertFalse(records.contains { $0.pluginName == "builtin-translate" },
                       "旧 trust 应被 Phase 2 删")
    }

    /// AT03 Phase 1.5 之后 crash：旧 dir+trust 在 / 新 dir+trust 都在 → 再次调，仅删旧
    func test_AT03_migrateLegacy_resumeAfterPhase15() throws {
        let oldDir = testPluginsDir.appending(path: "builtin-translate")
        let newDir = testPluginsDir.appending(path: "translate")
        try FileManager.default.createDirectory(at: oldDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: newDir, withIntermediateDirectories: true)
        try legacyPluginJSON(name: "builtin-translate")
            .write(to: oldDir.appending(path: "plugin.json"))
        try minimalPluginJSON(name: "translate")
            .write(to: newDir.appending(path: "plugin.json"))
        let trustKey = "prompt:abc123def4567890"
        try testTrustStore.addRecord(TrustRecord(
            trustKey: trustKey,
            pluginName: "builtin-translate",
            approvedAt: Date(timeIntervalSince1970: 1_700_000_000)
        ))
        try testTrustStore.addRecord(TrustRecord(
            trustKey: trustKey,
            pluginName: "translate",
            approvedAt: Date(timeIntervalSince1970: 1_700_000_000)
        ))

        let mgr = makeManager()
        try mgr.migrateLegacy()

        XCTAssertFalse(FileManager.default.fileExists(atPath: oldDir.path),
                       "Phase 2：旧目录应被删")
        let records = try testTrustStore.list()
        XCTAssertFalse(records.contains { $0.pluginName == "builtin-translate" },
                       "Phase 2：旧 trust 应被删")
        XCTAssertTrue(records.contains { $0.pluginName == "translate" })
    }

    /// AT04 已完成（仅新 dir + 新 trust）→ no-op，状态不变
    func test_AT04_migrateLegacy_alreadyMigrated_noop() throws {
        let newDir = testPluginsDir.appending(path: "translate")
        try FileManager.default.createDirectory(at: newDir, withIntermediateDirectories: true)
        try minimalPluginJSON(name: "translate")
            .write(to: newDir.appending(path: "plugin.json"))
        try testTrustStore.addRecord(TrustRecord(
            trustKey: "prompt:xxxx",
            pluginName: "translate",
            approvedAt: Date(timeIntervalSince1970: 1_700_000_000)
        ))

        let mgr = makeManager()
        XCTAssertNoThrow(try mgr.migrateLegacy())

        let records = try testTrustStore.list()
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.pluginName, "translate")
    }

    /// AT05 trustKey 不变：迁移前后新 trustKey == 旧 trustKey
    func test_AT05_migrateLegacy_trustKeyPreserved() throws {
        let oldDir = testPluginsDir.appending(path: "builtin-translate")
        try FileManager.default.createDirectory(at: oldDir, withIntermediateDirectories: true)
        try legacyPluginJSON(name: "builtin-translate")
            .write(to: oldDir.appending(path: "plugin.json"))
        let originalKey = "prompt:fixedtrustkey1234567890abcdef"
        try testTrustStore.addRecord(TrustRecord(
            trustKey: originalKey,
            pluginName: "builtin-translate",
            approvedAt: Date(timeIntervalSince1970: 1_700_000_000)
        ))

        let mgr = makeManager()
        try mgr.migrateLegacy()

        let records = try testTrustStore.list()
        let newRecord = records.first { $0.pluginName == "translate" }
        XCTAssertNotNil(newRecord, "迁移后新 trust 应存在")
        XCTAssertEqual(newRecord?.trustKey, originalKey,
                       "trustKey 必须不变（prompt-mode 不依赖 pluginName）")
    }

    // MARK: ============ seedFromBundle 系列 ============

    /// AT06 首启：pluginsDir 不存在 → seed 后 pluginsDir + marketplace.json + 两 plugin 目录都存在
    func test_AT06_seedFromBundle_freshStart() async throws {
        XCTAssertFalse(FileManager.default.fileExists(atPath: testPluginsDir.path))

        let mgr = makeManager()
        try await mgr.seedFromBundle()

        XCTAssertTrue(FileManager.default.fileExists(atPath: testPluginsDir.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: testMarketplacePath.path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: testPluginsDir.appending(path: "hello/plugin.json").path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: testPluginsDir.appending(path: "translate/plugin.json").path))
    }

    /// AT07 幂等：调 2 次，plugin.json 数据不变
    func test_AT07_seedFromBundle_idempotent() async throws {
        let mgr = makeManager()
        try await mgr.seedFromBundle()
        let firstTranslate = try Data(contentsOf:
            testPluginsDir.appending(path: "translate/plugin.json"))
        let firstMarket = try Data(contentsOf: testMarketplacePath)

        try await mgr.seedFromBundle()
        let secondTranslate = try Data(contentsOf:
            testPluginsDir.appending(path: "translate/plugin.json"))
        let secondMarket = try Data(contentsOf: testMarketplacePath)

        XCTAssertEqual(firstTranslate, secondTranslate, "第二次 seed plugin.json 不应变")
        XCTAssertEqual(firstMarket, secondMarket, "第二次 seed marketplace.json 不应变")
    }

    /// AT08 保留 .disabled：手动放 .disabled，再 seed → 仍在
    func test_AT08_seedFromBundle_preservesDisabled() async throws {
        let mgr = makeManager()
        try await mgr.seedFromBundle()
        let disabledMark = testPluginsDir.appending(path: "translate/.disabled")
        try Data().write(to: disabledMark)

        // 模拟 bundle 内容变化：改 plugin.json 触发重 seed 路径
        let bundlePluginJSON = testBundleRoot
            .appending(path: "Marketplace/plugins/translate/plugin.json")
        let newJSON = try minimalPluginJSON(name: "translate")
        let mutated = String(data: newJSON, encoding: .utf8)!
            .replacingOccurrences(of: "\"version\":\"0.1.0\"", with: "\"version\":\"0.2.0\"")
        try mutated.data(using: .utf8)!.write(to: bundlePluginJSON)

        try await mgr.seedFromBundle()
        XCTAssertTrue(FileManager.default.fileExists(atPath: disabledMark.path),
                      ".disabled 标记应被保留")
    }

    // MARK: ============ syncFromRemote 系列 ============

    /// AT09 1h debounce：第 1 次 200 OK → 第 2 次立即不发 HTTP
    func test_AT09_syncFromRemote_debounce() async throws {
        let remote = URL(string: "https://example.test/marketplace.json")!
        MarketplaceMockURLProtocol.stub(url: remote, status: 200, data: minimalMarketplaceJSON())

        let fixedNow = Date(timeIntervalSince1970: 2_000_000_000)
        let mgr = makeManager(urlSession: makeMockSession(), remoteURL: remote,
                              now: { fixedNow })
        try await mgr.seedFromBundle()
        MarketplaceMockURLProtocol.resetCounter()

        await mgr.syncFromRemote()
        XCTAssertEqual(MarketplaceMockURLProtocol.requestCount, 1, "首次应发 1 次 HTTP")

        await mgr.syncFromRemote()
        XCTAssertEqual(MarketplaceMockURLProtocol.requestCount, 1, "debounce 内第 2 次不发 HTTP")
    }

    /// AT10 Malformed JSON：cache 不写 + failures+=1
    func test_AT10_syncFromRemote_malformed_failsAndCounterIncrements() async throws {
        let remote = URL(string: "https://example.test/marketplace.json")!
        MarketplaceMockURLProtocol.stub(url: remote, status: 200,
                             data: "not json".data(using: .utf8)!)

        let mgr = makeManager(urlSession: makeMockSession(), remoteURL: remote)
        // 不 seed，所以 testMarketplacePath 一开始不存在
        XCTAssertFalse(FileManager.default.fileExists(atPath: testMarketplacePath.path))

        await mgr.syncFromRemote()

        XCTAssertFalse(FileManager.default.fileExists(atPath: testMarketplacePath.path),
                       "malformed 不应写 cache")
        let inspection = try mgr.inspect()
        XCTAssertEqual(inspection.consecutiveSyncFailures, 1)
    }

    /// AT11 schemaVersion=99：cache 不写
    func test_AT11_syncFromRemote_schemaVersion99_rejected() async throws {
        let remote = URL(string: "https://example.test/marketplace.json")!
        MarketplaceMockURLProtocol.stub(url: remote, status: 200, data: schemaV99JSON())

        let mgr = makeManager(urlSession: makeMockSession(), remoteURL: remote)
        await mgr.syncFromRemote()

        XCTAssertFalse(FileManager.default.fileExists(atPath: testMarketplacePath.path),
                       "schemaVersion=99 不应写 cache")
        let inspection = try mgr.inspect()
        XCTAssertGreaterThanOrEqual(inspection.consecutiveSyncFailures, 1)
    }

    /// AT12 成功 update：translate version 0.2.0 → cache 写 + log 含 updated
    func test_AT12_syncFromRemote_successfulUpdate_writesCacheAndLog() async throws {
        let remote = URL(string: "https://example.test/marketplace.json")!
        let mgr = makeManager(urlSession: makeMockSession(), remoteURL: remote)
        try await mgr.seedFromBundle()

        // 现在远程返回更新版本
        MarketplaceMockURLProtocol.stub(url: remote, status: 200,
                             data: minimalMarketplaceJSON(translateVersion: "0.2.0"))
        await mgr.syncFromRemote()

        let cache = try Data(contentsOf: testMarketplacePath)
        let manifest = try JSONDecoder().decode(MarketplaceManifest.self, from: cache)
        let translate = manifest.plugins.first { $0.name == "translate" }
        XCTAssertEqual(translate?.version, "0.2.0", "cache 应反映远程 0.2.0")

        // 验证 sync log 写入；至少有一行 status 字段为 updated 或包含 translate
        XCTAssertTrue(FileManager.default.fileExists(atPath: testSyncLogPath.path),
                      "sync log 应存在")
        let logText = (try? String(contentsOf: testSyncLogPath, encoding: .utf8)) ?? ""
        XCTAssertTrue(logText.contains("updated") || logText.contains("translate"),
                      "log 应含 updated/translate，实际: \(logText.prefix(300))")
    }

    /// AT13 连续 3 次失败：consecutiveSyncFailures == 3
    func test_AT13_syncFromRemote_threeConsecutiveFailures() async throws {
        let remote = URL(string: "https://example.test/marketplace.json")!
        MarketplaceMockURLProtocol.stubError(url: remote,
                                  error: NSError(domain: "test", code: -1, userInfo: nil))

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

        await mgr.syncFromRemote()
        await mgr.syncFromRemote()
        await mgr.syncFromRemote()

        let inspection = try mgr.inspect()
        XCTAssertEqual(inspection.consecutiveSyncFailures, 3)
    }

    // MARK: ============ install / reseed / inspect 系列 ============

    /// AT14 install 不在 marketplace → throw pluginNotFound
    func test_AT14_install_unknownName_throwsPluginNotFound() async throws {
        let mgr = makeManager()
        try await mgr.seedFromBundle()
        do {
            try await mgr.install(name: "definitely-not-exist")
            XCTFail("应抛 pluginNotFound")
        } catch LauncherError.pluginNotFound(let name) {
            XCTAssertEqual(name, "definitely-not-exist")
        } catch {
            XCTFail("应抛 LauncherError.pluginNotFound，实际: \(error)")
        }
    }

    /// AT15 install conflict skip（B3 修复）：sideloaded translate 已存在 → 后台 sync
    /// 触发 added 路径走 installPlugin(replacing=false) → 不抛错 + sideloaded 目录不动 + log skip-conflict
    func test_AT15_install_conflictSkip_preservesSideloaded() async throws {
        // 先建 sideloaded "translate"（非 marketplace cache）
        let sideloadedDir = testPluginsDir.appending(path: "translate")
        try FileManager.default.createDirectory(at: sideloadedDir, withIntermediateDirectories: true)
        let sideloadedPluginJSON = #"{"name":"translate","sideloaded":true}"#.data(using: .utf8)!
        try sideloadedPluginJSON.write(to: sideloadedDir.appending(path: "plugin.json"))

        // marketplace cache 此刻不存在 → 远程 sync 把 translate 当 added
        let remote = URL(string: "https://example.test/marketplace.json")!
        MarketplaceMockURLProtocol.stub(url: remote, status: 200, data: minimalMarketplaceJSON())
        let mgr = makeManager(urlSession: makeMockSession(), remoteURL: remote)

        // syncFromRemote 永不抛错（行为契约）
        await mgr.syncFromRemote()

        // sideloaded 目录不被覆盖
        let post = try Data(contentsOf: sideloadedDir.appending(path: "plugin.json"))
        XCTAssertEqual(post, sideloadedPluginJSON, "sideloaded plugin.json 应保持原样")

        // log 应含 skip-conflict
        let logText = (try? String(contentsOf: testSyncLogPath, encoding: .utf8)) ?? ""
        XCTAssertTrue(logText.contains("skip-conflict"),
                      "应记录 skip-conflict，实际 log: \(logText.prefix(400))")
    }

    /// AT16 reseed 保留 .disabled
    func test_AT16_reseed_preservesDisabled() async throws {
        let mgr = makeManager()
        try await mgr.seedFromBundle()
        let disabledMark = testPluginsDir.appending(path: "translate/.disabled")
        try Data().write(to: disabledMark)

        try await mgr.reseed()

        XCTAssertTrue(FileManager.default.fileExists(atPath: disabledMark.path),
                      "reseed 应保留 .disabled 标记")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: testPluginsDir.appending(path: "translate/plugin.json").path),
            "reseed 应重建 plugin.json")
    }

    /// AT17 inspect 含 sideloaded（B4 修复）：weather sideloaded + seed → inspect.sideloadedPlugins 含 weather
    func test_AT17_inspect_sideloadedField() async throws {
        let mgr = makeManager()
        try await mgr.seedFromBundle()

        // 手建 sideloaded weather
        let weatherDir = testPluginsDir.appending(path: "weather")
        try FileManager.default.createDirectory(at: weatherDir, withIntermediateDirectories: true)
        try minimalPluginJSON(name: "weather").write(
            to: weatherDir.appending(path: "plugin.json"))

        let inspection = try mgr.inspect()
        XCTAssertTrue(inspection.sideloadedPlugins.contains { $0.name == "weather" },
                      "inspect.sideloadedPlugins 应含 weather")
        XCTAssertFalse(inspection.plugins.contains { $0.name == "weather" },
                       "inspect.plugins (marketplace 视角) 不应含 weather")
        XCTAssertTrue(inspection.plugins.contains { $0.name == "translate" },
                      "inspect.plugins 应含 marketplace 中的 translate")
    }

    /// AT18 inspect 反映 .disabled：plugin.enabled == false
    func test_AT18_inspect_disabled() async throws {
        let mgr = makeManager()
        try await mgr.seedFromBundle()
        let disabledMark = testPluginsDir.appending(path: "translate/.disabled")
        try Data().write(to: disabledMark)

        let inspection = try mgr.inspect()
        let translate = inspection.plugins.first { $0.name == "translate" }
        XCTAssertNotNil(translate)
        XCTAssertEqual(translate?.enabled, false, ".disabled 应让 enabled=false")
    }

    // MARK: ============ 静态契约 ============

    /// AT19 installBundledPlugins 已完全删除：方法定义+调用应消失（注释中的迁移说明豁免）
    func test_AT19_installBundledPlugins_isFullyRemoved() throws {
        let sourcesPath = URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Sources").path
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/grep")
        proc.arguments = ["-r", "-n", "installBundledPlugins", sourcesPath]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        try proc.run()
        proc.waitUntilExit()
        let raw = String(
            data: pipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        // 每行格式 "<file>:<lineno>:<content>"；过滤纯注释行（trim 后以 // 开头）
        let codeHits = raw.split(separator: "\n").filter { line in
            let parts = line.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3 else { return true }
            return !parts[2].trimmingCharacters(in: .whitespaces).hasPrefix("//")
        }
        XCTAssertTrue(codeHits.isEmpty,
                      "installBundledPlugins 应已删除（仅注释豁免）；实际代码命中:\n" +
                      codeHits.joined(separator: "\n"))
    }

    /// AT20 Package.swift .copy("Plugins") 已删 + Sources/ClaudeCodeBuddy/Plugins/ 目录已删
    func test_AT20_oldPluginsBundleResource_removed() throws {
        let packageSwift = URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Package.swift")
        let content = try String(contentsOf: packageSwift, encoding: .utf8)
        XCTAssertFalse(content.contains(".copy(\"Plugins\")"),
                       "Package.swift 应已删 .copy(\"Plugins\")")

        let oldPluginsDir = URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Sources/ClaudeCodeBuddy/Plugins")
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldPluginsDir.path),
                       "Sources/ClaudeCodeBuddy/Plugins/ 应已删除")
    }
}

// MARK: - StubResolver

/// 测试用 resolver：仅支持 localSubdir（bundle seed 唯一用法），把 bundleRoot+path 解析回去。
private final class StubResolver: PluginSourceResolving {
    func resolve(_ source: PluginSourceConfig, bundleRoot: URL?) async throws -> URL {
        switch source {
        case .localSubdir(let path):
            guard let bundleRoot else {
                throw LauncherError.pluginInvalid("StubResolver: missing bundleRoot")
            }
            let resolved = bundleRoot.appending(path: path)
            guard FileManager.default.fileExists(
                atPath: resolved.appending(path: "plugin.json").path
            ) else {
                throw LauncherError.pluginInvalid(
                    "StubResolver: plugin.json missing at \(resolved.path)")
            }
            return resolved
        case .file(let path):
            return URL(fileURLWithPath: path)
        case .gitURL, .gitSubdir:
            throw LauncherError.pluginInvalid("StubResolver: git source not supported in test")
        }
    }
}

// MARK: - BundleStub

/// 把 testBundleRoot 包装成 Bundle，让 url(forResource:withExtension:subdirectory:) 走文件系统映射。
/// Bundle 默认实现需要 bundle 结构；我们用一个 trick：把 testBundleRoot 直接作为 bundlePath
/// （Bundle(url:) 不要求严格 .bundle 后缀，只要目录存在即可加载）。
private enum BundleStub {
    static func make(rootURL: URL) -> Bundle {
        // Bundle(url:) on a plain directory 仍可工作：url(forResource:...) 会以 rootURL 为根扫描
        return Bundle(url: rootURL) ?? Bundle.main
    }
}

// MARK: - MarketplaceMockURLProtocol

/// 自包含 URLProtocol mock（30 行级别，独立于蓝队）。
final class MarketplaceMockURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var stubs: [URL: (data: Data?, status: Int, error: Error?)] = [:]
    private static var counter: Int = 0

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        stubs.removeAll()
        counter = 0
    }
    static func resetCounter() {
        lock.lock(); defer { lock.unlock() }
        counter = 0
    }
    static var requestCount: Int {
        lock.lock(); defer { lock.unlock() }
        return counter
    }
    static func stub(url: URL, status: Int, data: Data) {
        lock.lock(); defer { lock.unlock() }
        stubs[url] = (data, status, nil)
    }
    static func stubError(url: URL, error: Error) {
        lock.lock(); defer { lock.unlock() }
        stubs[url] = (nil, 0, error)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        Self.lock.lock()
        Self.counter += 1
        let stub = Self.stubs[url]
        Self.lock.unlock()

        if let stub {
            if let error = stub.error {
                client?.urlProtocol(self, didFailWithError: error)
                return
            }
            let response = HTTPURLResponse(
                url: url,
                statusCode: stub.status,
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
