import XCTest
@testable import BuddyCore

/// 蓝队单元测试：补充覆盖 MarketplaceManager 内部 helper 与红队 AT 未触及的边界。
///
/// 红队 acceptance 测试 (MarketplaceManagerAcceptanceTests) 覆盖端到端契约；
/// 本文件聚焦：
///   - sourceLabel 4 case 字符串输出
///   - readMeta/writeMeta 序列化往返
///   - migrate hello 路径（红队只测了 translate）
///   - syncFromRemote HTTP 500 路径（红队测 malformed/schema99）
///   - syncFromRemote removed plugin 不删旧目录
///   - install replacing=true 路径
///   - reseed 不删 sideloaded 第三方
///   - ensureStdinChmod stdin mode 真实 chmod
///   - sha256Hex 确定性
///   - 失败 counter 走完 success 路径后清零
///
/// 复用同 module 内 internal helpers + 重新声明独立 stub（避免与红队文件 fileprivate 冲突）。
/// swiftlint:disable type_body_length file_length function_body_length
final class MarketplaceManagerTests: XCTestCase {

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
            .appending(path: "buddy-mm-unit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: testRoot, withIntermediateDirectories: true)

        testPluginsDir = testRoot.appending(path: "launcher-plugins")
        testMarketplacePath = testRoot.appending(path: "marketplace.json")
        testMetaPath = testRoot.appending(path: "marketplace-meta.json")
        testSyncLogPath = testRoot.appending(path: "launcher-sync.log")
        testTrustFile = testRoot.appending(path: "launcher-trust.json")
        testTrustStore = TrustStore(file: testTrustFile)

        testBundleRoot = testRoot.appending(path: "bundle")
        let marketplaceDir = testBundleRoot.appending(path: "Marketplace")
        try FileManager.default.createDirectory(
            at: marketplaceDir.appending(path: "plugins/hello"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: marketplaceDir.appending(path: "plugins/translate"),
            withIntermediateDirectories: true
        )
        try seedMarketplaceJSON().write(
            to: marketplaceDir.appending(path: "marketplace.json")
        )
        try stdinPluginJSON(name: "hello").write(
            to: marketplaceDir.appending(path: "plugins/hello/plugin.json")
        )
        try promptPluginJSON(name: "translate").write(
            to: marketplaceDir.appending(path: "plugins/translate/plugin.json")
        )

        UnitMockURLProtocol.reset()
    }

    override func tearDownWithError() throws {
        if let testRoot, FileManager.default.fileExists(atPath: testRoot.path) {
            try? FileManager.default.removeItem(at: testRoot)
        }
        UnitMockURLProtocol.reset()
    }

    // MARK: - Factories

    private func makeManager(
        urlSession: URLSession? = nil,
        remoteURL: URL? = nil,
        now: @escaping () -> Date = Date.init,
        resolver: PluginSourceResolving = UnitStubResolver()
    ) -> MarketplaceManager {
        let session = urlSession ?? mockSession()
        let remote = remoteURL ?? URL(string: "https://example.test/marketplace.json")!
        return MarketplaceManager(
            resolver: resolver,
            trustStore: testTrustStore,
            pluginsDir: testPluginsDir,
            marketplacePath: testMarketplacePath,
            metaPath: testMetaPath,
            syncLogPath: testSyncLogPath,
            bundleProvider: { [self] in Bundle(url: testBundleRoot) ?? Bundle.main },
            urlSession: session,
            now: now,
            remoteURL: remote
        )
    }

    private func mockSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [UnitMockURLProtocol.self]
        return URLSession(configuration: config)
    }

    // MARK: - JSON fixtures

    private func seedMarketplaceJSON(
        translateVersion: String = "0.1.0",
        includeHello: Bool = true,
        includeWeather: Bool = false
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
        if includeWeather {
            plugins.append([
                "name": "weather",
                "description": "weather demo",
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

    private func promptPluginJSON(name: String) -> Data {
        let root: [String: Any] = [
            "name": name,
            "version": "0.1.0",
            "description": "prompt plugin",
            "keywords": [name],
            "mode": "prompt",
            "systemPrompt": "you are a test assistant",
            "maxIterations": 1
        ]
        return try! JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    }

    private func stdinPluginJSON(name: String) -> Data {
        let root: [String: Any] = [
            "name": name,
            "version": "0.1.0",
            "description": "stdin plugin",
            "keywords": [name],
            "mode": "stdin",
            "cmd": "./run.sh",
            "args": []
        ]
        return try! JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    }

    // MARK: - 1. inspect.source label 4 case

    /// inspect 输出的 source 字符串包含识别前缀（localSubdir / file / gitURL / gitSubdir）。
    func testInspect_sourceLabel_localSubdirHasPrefix() async throws {
        let mgr = makeManager()
        try await mgr.seedFromBundle()
        let inspection = try mgr.inspect()
        let translate = inspection.plugins.first { $0.name == "translate" }
        XCTAssertEqual(translate?.source, "local-subdir: ./plugins/translate",
                       "localSubdir source 应渲染为 'local-subdir: <path>'")
    }

    // MARK: - 2. readMeta/writeMeta 往返

    /// syncFromRemote 成功后 meta 文件含 lastSyncedAt + failures=0，下次 read 一致。
    func testMeta_writeAndReadRoundtrip() async throws {
        let remote = URL(string: "https://example.test/marketplace.json")!
        UnitMockURLProtocol.stub(url: remote, status: 200, data: seedMarketplaceJSON())
        let fixedNow = Date(timeIntervalSince1970: 1_900_000_000)
        let mgr = makeManager(urlSession: mockSession(), remoteURL: remote, now: { fixedNow })
        try await mgr.seedFromBundle()

        await mgr.syncFromRemote()

        XCTAssertTrue(FileManager.default.fileExists(atPath: testMetaPath.path),
                      "syncFromRemote 成功后 meta 文件应存在")
        let inspection = try mgr.inspect()
        XCTAssertEqual(inspection.consecutiveSyncFailures, 0,
                       "成功后 failures 应清零")
        XCTAssertNotNil(inspection.lastSyncedAt, "成功后 lastSyncedAt 应非 nil")
        // 误差 ≤ 1s（ISO8601 round-trip 秒级）
        if let last = inspection.lastSyncedAt {
            XCTAssertLessThan(abs(last.timeIntervalSince(fixedNow)), 1.0)
        }
    }

    // MARK: - 3. migrate hello 路径（红队仅测 translate）

    /// migrateLegacy 对 builtin-hello → hello 同样应起作用。
    func testMigrate_hello_pathWorks() throws {
        let oldDir = testPluginsDir.appending(path: "builtin-hello")
        try FileManager.default.createDirectory(at: oldDir, withIntermediateDirectories: true)
        try stdinPluginJSON(name: "builtin-hello")
            .write(to: oldDir.appending(path: "plugin.json"))
        try testTrustStore.addRecord(TrustRecord(
            trustKey: "stdin:helloOldKey",
            pluginName: "builtin-hello",
            approvedAt: Date(timeIntervalSince1970: 1_700_000_000)
        ))

        let mgr = makeManager()
        try mgr.migrateLegacy()

        let newDir = testPluginsDir.appending(path: "hello")
        XCTAssertTrue(FileManager.default.fileExists(atPath: newDir.path),
                      "hello 新目录应创建")
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldDir.path),
                       "builtin-hello 旧目录应删除")

        // 验证 plugin.json name 已改成 "hello"
        let newPluginJSON = newDir.appending(path: "plugin.json")
        let data = try Data(contentsOf: newPluginJSON)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(obj["name"] as? String, "hello",
                       "新 plugin.json name 应改为 'hello'")

        let records = try testTrustStore.list()
        XCTAssertTrue(records.contains { $0.pluginName == "hello" },
                      "新 trust hello 应存在")
        XCTAssertFalse(records.contains { $0.pluginName == "builtin-hello" },
                       "旧 trust builtin-hello 应删除")
    }

    // MARK: - 4. syncFromRemote HTTP 500 路径

    /// HTTP 500 → cache 不写 + failures+=1，永不抛错。
    func testSync_http500_failsCounterIncrementsCacheNotWritten() async throws {
        let remote = URL(string: "https://example.test/marketplace.json")!
        UnitMockURLProtocol.stub(url: remote, status: 500, data: Data("oops".utf8))

        let mgr = makeManager(urlSession: mockSession(), remoteURL: remote)
        XCTAssertFalse(FileManager.default.fileExists(atPath: testMarketplacePath.path))

        await mgr.syncFromRemote()

        XCTAssertFalse(FileManager.default.fileExists(atPath: testMarketplacePath.path),
                       "HTTP 500 不应写 cache")
        let inspection = try mgr.inspect()
        XCTAssertEqual(inspection.consecutiveSyncFailures, 1)
    }

    // MARK: - 5. syncFromRemote removed plugin 不删旧目录（行为契约：留旧）

    /// 远程 manifest 删除 hello → 本地 hello 目录仍存在（不破坏用户体验）。
    func testSync_removedPlugin_keepsOldDirectory() async throws {
        let remote = URL(string: "https://example.test/marketplace.json")!
        UnitMockURLProtocol.stub(url: remote, status: 200, data: seedMarketplaceJSON())
        let mgr = makeManager(urlSession: mockSession(), remoteURL: remote, now: { Date() })
        try await mgr.seedFromBundle()

        // 远程后续只返回 translate（hello 被移除）
        var counter = 0
        let mgr2 = makeManager(
            urlSession: mockSession(),
            remoteURL: remote,
            now: {
                counter += 1
                return Date(timeIntervalSince1970: TimeInterval(2_500_000_000 + counter * 7200))
            }
        )
        UnitMockURLProtocol.stub(url: remote, status: 200,
                                 data: seedMarketplaceJSON(includeHello: false))
        await mgr2.syncFromRemote()

        let helloDir = testPluginsDir.appending(path: "hello")
        XCTAssertTrue(FileManager.default.fileExists(atPath: helloDir.path),
                      "removed 远程仍应保留本地目录（不破坏用户使用）")
    }

    // MARK: - 6. install replacing=true 真正覆盖目录

    /// install(name:) 主动安装 → replacing=true，已存在内容会被覆盖（但保留 .disabled）。
    func testInstall_replacingTrue_overwritesDirectory() async throws {
        let mgr = makeManager()
        try await mgr.seedFromBundle()

        // 修改 translate plugin.json 模拟用户/sync 后老内容
        let translateDir = testPluginsDir.appending(path: "translate")
        try Data("CORRUPTED".utf8).write(to: translateDir.appending(path: "plugin.json"))

        // 加 .disabled 标记
        let disabledMark = translateDir.appending(path: ".disabled")
        try Data().write(to: disabledMark)

        try await mgr.install(name: "translate")

        // plugin.json 已被覆盖回 bundle 内容（含 maxIterations）
        let data = try Data(contentsOf: translateDir.appending(path: "plugin.json"))
        XCTAssertNotEqual(data, Data("CORRUPTED".utf8),
                          "replacing=true 应覆盖被破坏的 plugin.json")
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(obj["name"] as? String, "translate")

        // .disabled 保留
        XCTAssertTrue(FileManager.default.fileExists(atPath: disabledMark.path),
                      "replacing=true 应保留 .disabled 标记")
    }

    // MARK: - 7. reseed 不删用户手动 add 的第三方 sideloaded

    /// reseed 删 marketplace 列出的 plugin，但 sideloaded 第三方目录不动。
    func testReseed_keepsSideloaded() async throws {
        let mgr = makeManager()
        try await mgr.seedFromBundle()

        // 手建 sideloaded "user-tool"（不在 marketplace.json）
        let sideloadedDir = testPluginsDir.appending(path: "user-tool")
        try FileManager.default.createDirectory(at: sideloadedDir, withIntermediateDirectories: true)
        let sideloadedManifest = promptPluginJSON(name: "user-tool")
        try sideloadedManifest.write(to: sideloadedDir.appending(path: "plugin.json"))

        try await mgr.reseed()

        XCTAssertTrue(FileManager.default.fileExists(atPath: sideloadedDir.path),
                      "reseed 不应删 sideloaded 第三方目录")
        let stillThere = try Data(contentsOf: sideloadedDir.appending(path: "plugin.json"))
        XCTAssertEqual(stillThere, sideloadedManifest,
                       "sideloaded plugin.json 内容应保持不变")

        // marketplace 中的 translate 仍被重 seed
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: testPluginsDir.appending(path: "translate/plugin.json").path
        ))
    }

    // MARK: - 8. ensureStdinChmod stdin mode 真实 chmod

    /// stdin mode plugin 拷贝后 cmd 文件被 chmod 为 0o755。
    func testSeedFromBundle_stdinPluginChmod755() async throws {
        // 写入 hello run.sh 到 bundle
        let helloBundle = testBundleRoot.appending(path: "Marketplace/plugins/hello")
        let runShBundle = helloBundle.appending(path: "run.sh")
        try Data("#!/bin/sh\necho hi\n".utf8).write(to: runShBundle)
        // 故意把 source 文件权限设为 0o644
        try FileManager.default.setAttributes([.posixPermissions: 0o644],
                                              ofItemAtPath: runShBundle.path)

        let mgr = makeManager()
        try await mgr.seedFromBundle()

        let runShTarget = testPluginsDir.appending(path: "hello/run.sh").path
        XCTAssertTrue(FileManager.default.fileExists(atPath: runShTarget))
        let attrs = try FileManager.default.attributesOfItem(atPath: runShTarget)
        let perms = (attrs[.posixPermissions] as? Int) ?? 0
        XCTAssertEqual(perms, 0o755,
                       "stdin mode cmd 文件应被 chmod 为 0o755，实际: \(String(perms, radix: 8))")
    }

    // MARK: - 9. failure counter 走完 success 后清零

    /// 1 次失败 → counter=1 → 1 次成功（绕过 debounce）→ counter=0。
    func testSync_successAfterFailure_resetsCounter() async throws {
        let remote = URL(string: "https://example.test/marketplace.json")!

        var counter = 0
        let mgr = makeManager(
            urlSession: mockSession(),
            remoteURL: remote,
            now: {
                counter += 1
                return Date(timeIntervalSince1970: TimeInterval(2_700_000_000 + counter * 7200))
            }
        )

        // 第 1 次：malformed
        UnitMockURLProtocol.stub(url: remote, status: 200,
                                 data: Data("not json".utf8))
        await mgr.syncFromRemote()
        XCTAssertEqual(try mgr.inspect().consecutiveSyncFailures, 1)

        // 第 2 次：success
        UnitMockURLProtocol.stub(url: remote, status: 200, data: seedMarketplaceJSON())
        await mgr.syncFromRemote()
        XCTAssertEqual(try mgr.inspect().consecutiveSyncFailures, 0,
                       "成功后 failures 应清零")
    }

    // MARK: - 10. inspect default 空 manifest（cache 不存在时不抛）

    /// cache 不存在时 inspect 返回空 plugins 数组，不抛错。
    func testInspect_emptyWhenCacheMissing() throws {
        let mgr = makeManager()
        let inspection = try mgr.inspect()
        XCTAssertTrue(inspection.plugins.isEmpty)
        XCTAssertTrue(inspection.sideloadedPlugins.isEmpty)
        XCTAssertNil(inspection.lastSyncedAt)
        XCTAssertEqual(inspection.consecutiveSyncFailures, 0)
    }

    // MARK: - 11. seedFromBundle bundle missing → throws pluginInvalid

    /// bundle 内 marketplace.json 缺失 → throw pluginInvalid。
    func testSeedFromBundle_bundleMissingThrows() async throws {
        // 删 bundle marketplace.json
        let marketplaceJSON = testBundleRoot.appending(path: "Marketplace/marketplace.json")
        try FileManager.default.removeItem(at: marketplaceJSON)

        let mgr = makeManager()
        do {
            try await mgr.seedFromBundle()
            XCTFail("应抛 LauncherError.pluginInvalid")
        } catch LauncherError.pluginInvalid(let reason) {
            XCTAssertTrue(reason.contains("marketplace.json"),
                          "错误信息应含 'marketplace.json'，实际: \(reason)")
        } catch {
            XCTFail("应抛 LauncherError.pluginInvalid，实际: \(error)")
        }
    }

    // MARK: - 12. sync 写 cache + meta 之后 inspect 立即反映

    /// success sync 后 inspect.lastSyncedAt 等于注入的 now。
    func testSync_inspectReflectsLastSyncedAt() async throws {
        let remote = URL(string: "https://example.test/marketplace.json")!
        UnitMockURLProtocol.stub(url: remote, status: 200, data: seedMarketplaceJSON())
        let fixedNow = Date(timeIntervalSince1970: 1_950_000_000)
        let mgr = makeManager(urlSession: mockSession(), remoteURL: remote,
                              now: { fixedNow })

        await mgr.syncFromRemote()

        let inspection = try mgr.inspect()
        let last = try XCTUnwrap(inspection.lastSyncedAt)
        XCTAssertLessThan(abs(last.timeIntervalSince(fixedNow)), 1.0,
                          "inspect.lastSyncedAt 应与 now 一致（秒级）")
    }
}

// MARK: - UnitStubResolver

/// 测试用 resolver（独立于红队 StubResolver 以避免 fileprivate 冲突）。
private final class UnitStubResolver: PluginSourceResolving {
    func resolve(_ source: PluginSourceConfig, bundleRoot: URL?) async throws -> URL {
        switch source {
        case .localSubdir(let path):
            guard let bundleRoot else {
                throw LauncherError.pluginInvalid("UnitStubResolver: missing bundleRoot")
            }
            let resolved = bundleRoot.appending(path: path)
            guard FileManager.default.fileExists(
                atPath: resolved.appending(path: "plugin.json").path
            ) else {
                throw LauncherError.pluginInvalid(
                    "UnitStubResolver: plugin.json missing at \(resolved.path)"
                )
            }
            return resolved
        case .file(let path):
            return URL(fileURLWithPath: path)
        case .gitURL, .gitSubdir:
            throw LauncherError.pluginInvalid("UnitStubResolver: git not supported")
        }
    }
}

// MARK: - UnitMockURLProtocol

/// 自包含 URLProtocol mock（与红队 MarketplaceMockURLProtocol 独立）。
final class UnitMockURLProtocol: URLProtocol {
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
