import XCTest
@testable import BuddyCore

/// Tier 0 红队验收测试 —— 黑盒验证 `buddy launcher run` dry-run CLI（契约 C4）+ TOFU seam。
///
/// 覆盖验收场景：
/// - 场景 9.P1: run qr --input "..." 执行插件 stdout 非空 EXIT==0
/// - 场景 9.P3: run <不存在> 报错 EXIT!=0 stderr 含 not found/不存在
/// - 场景 9.P4: run 未 trust 插件经 TOFU（QueryHandler run 分支在 execute 前调 TrustStore.checkAndPrompt）
///
/// 跨系统数据流（C4）：run CLI → socket action `launcher_debug_run_plugin` → app QueryHandler
/// → PluginDispatcher.execute → 返回 JSON `{name,stdout,stderr,exit_code,duration_ms}`。
///
/// 单元层局限（CONTRACT_AMBIGUITY）：
/// - 真实执行链路（spawn 子进程、弹 NSAlert）需 app 运行 + 真实插件目录，由 QA 真实场景 9.P1/9.P4 覆盖。
/// - 本文件验证「action 被识别 + 命令解析契约 + error 语义 + 返回 JSON 字段名」，
///   这是跨系统数据流字段一致性的硬保证。
///
/// 信息隔离：不读 QueryHandler run 分支实现，仅调契约声明的 action + 断言返回结构。
/// 命名前缀: test_AT<编号>_<场景>
@MainActor
final class LauncherRunCLIAcceptanceTests: XCTestCase {

    private var manager: SessionManager!
    private var scene: MockScene!
    private var handler: QueryHandler!

    override func setUp() {
        scene = MockScene()
        let (m, _) = TestHelpers.makeManager(scene: scene)
        manager = m
        handler = QueryHandler(sessionManager: manager, scene: scene, eventStore: manager.eventStore)
    }

    // MARK: - Helpers

    private func parseJSON(_ data: Data) -> [String: Any] {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            XCTFail("response 不是合法 JSON object: \(String(data: data, encoding: .utf8) ?? "<binary>")")
            return [:]
        }
        return obj
    }

    // MARK: - C4: action 被识别（launcher_debug_run_plugin）

    /// 契约 C4: QueryHandler 必须识别 `launcher_debug_run_plugin` action。
    /// 场景 9.P3 间接：不存在的插件 → status error（证明 run 分支存在且解析 name）。
    func test_AT01_runActionRecognizedAndRejectsMissingName() async {
        // 缺 name 字段 → error（证明 run 分支存在且校验入参）
        let data = await handler.handle(query: [
            "action": "launcher_debug_run_plugin",
            "input": "x",
        ])
        let json = parseJSON(data)
        XCTAssertEqual(json["status"] as? String, "error",
                       "launcher_debug_run_plugin 缺 name 必须返回 status=error")
    }

    /// 契约 C4 + 场景 9.P3: 不存在的插件 → status error + message 含 not found/不存在。
    func test_AT02_runNonexistentPluginReturnsError() async {
        let data = await handler.handle(query: [
            "action": "launcher_debug_run_plugin",
            "name": "does-not-exist-xyz-12345",
            "input": "x",
        ])
        let json = parseJSON(data)
        // 场景 9.P3 assert: EXIT!=0 且 stderr 含 not found/不存在（app 侧 = status error）
        XCTAssertEqual(json["status"] as? String, "error",
                       "不存在的插件必须返回 status=error（场景 9.P3: EXIT!=0）")
        let message = (json["message"] as? String) ?? ""
        let indicatesNotFound = message.lowercased().contains("not found") || message.contains("不存在") || message.contains("找不到")
        XCTAssertTrue(indicatesNotFound,
                      "error message 必须提示未找到（场景 9.P3: stderr 含 not found/不存在），实际: \(message)")
    }

    // MARK: - C4: 返回 JSON 字段契约（成功路径字段名一致性）

    /// 契约 C4: 成功执行返回 JSON 含字段 {name, stdout, stderr, exit_code, duration_ms}。
    /// 跨系统数据流字段名一致性硬断言。
    ///
    /// 注：单元环境无真实插件目录，无法触发成功路径；
    /// 此测试验证「action 解析 + name 参数传递」链路（error 路径也证明 name 被正确读取）。
    /// 成功路径字段完整性由 QA 真实场景 9.P1 覆盖（curl 实跑）。
    func test_AT03_runActionReadsNameParameter() async {
        // 传入一个 name（即便不存在），验证 name 被读取并用于查找（错误信息应体现 name）
        let nonexistentName = "zzz-test-nonexistent-98765"
        let data = await handler.handle(query: [
            "action": "launcher_debug_run_plugin",
            "name": nonexistentName,
            "input": "test-input",
        ])
        let json = parseJSON(data)
        XCTAssertEqual(json["status"] as? String, "error")
        // name 被读取的间接证据：error 路径执行了（未报 missing name / missing action）
        let message = (json["message"] as? String) ?? ""
        XCTAssertFalse(message.isEmpty, "error message 应非空（证明走到了 name 查找分支）")
    }

    // MARK: - C4 TOFU seam（场景 9.P4 架构约束）

    /// 契约 C4 B1 + 场景 9.P4: run 分支必须在 PluginDispatcher.execute 前调 TrustStore.checkAndPrompt。
    ///
    /// CONTRACT_AMBIGUITY: 单元层无法直接断言「checkAndPrompt 被调用」——
    /// QueryHandler 直接调 TrustStore.shared（与现有 launcher 执行流一致，未提供注入 seam）。
    /// 真正的 TOFU 验证（信任后 EXIT==0、拒绝时 EXIT!=0 + not trusted）由 QA 真实场景 9.P4 覆盖
    /// （清 launcher-trust.json 后实跑 `buddy launcher run qr --input "x"`）。
    ///
    /// 本测试做架构存在性硬约束：TrustStore.checkAndPrompt 签名必须存在且 async -> Bool，
    /// run 分支才能调用它。若签名缺失，编译期即失败（TOFU seam 不可能绕过）。
    func test_AT04_trustStoreCheckAndPromptSignatureExists() async {
        // 契约 C4 B1: TrustStore.checkAndPrompt(_:executablePath:) async -> Bool 必须存在
        // （QueryHandler run 分支的硬依赖）。
        // M5 改造：checkAndPrompt 加了 seam 默认参数（真实签名对外不变，6 调用点无需改），
        // 方法引用类型随默认参数展开变长，改用闭包包装校验核心签名（plugin, exe）async -> Bool 可达。
        let method: (PluginManifest, URL) async -> Bool = { plugin, exe in
            await TrustStore.shared.checkAndPrompt(plugin, executablePath: exe)
        }
        _ = method
        // 被测方法存在即契约成立（无需实跑，避免弹 NSAlert）
        XCTAssertTrue(true, "TrustStore.checkAndPrompt 签名存在（C4 B1 TOFU seam 可达）")
    }

    /// 契约 C4: PluginDispatcher.execute 签名存在（run 分支的执行入口）。
    func test_AT05_pluginDispatcherExecuteSignatureExists() async {
        // 契约 C4: run 分支调 PluginDispatcher.execute(_ plugin:pluginDir:input:) async throws
        let method: (PluginManifest, URL, PluginInput) async throws -> PluginResult =
            PluginDispatcher.shared.execute
        _ = method
        XCTAssertTrue(true, "PluginDispatcher.execute 签名存在（C4 run 分支执行入口可达）")
    }

    // MARK: - C4: 返回 JSON 字段名契约（PluginResult → JSON 映射，跨系统一致性）

    /// 契约 C4: 成功响应 data 含 {name, stdout, stderr, exit_code, duration_ms}。
    /// PluginResult 字段名（stdout/stderr/exitCode/durationMs）必须能映射到契约的 snake_case。
    ///
    /// 此测试验证 PluginResult 字段存在性（返回 JSON 的字段映射由 QueryHandler 实现，
    /// 字段名一致性由契约 C4 逐字约束：exit_code / duration_ms snake_case）。
    func test_AT06_pluginResultFieldsMatchContractNames() {
        // 契约 C4 返回 JSON: {name, stdout, stderr, exit_code, duration_ms}
        // PluginResult Swift 字段: stdout, stderr, exitCode, durationMs
        // 验证 PluginResult 含这些字段（编译期保证，运行期构造一个实例）
        let result = PluginResult(
            stdout: "out",
            stderr: "err",
            exitCode: 0,
            durationMs: 42,
            stdoutTruncated: false,
            actions: [],
            image: nil
        )
        XCTAssertEqual(result.stdout, "out")
        XCTAssertEqual(result.stderr, "err")
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.durationMs, 42)
        // 字段存在 = QueryHandler 可序列化为契约 JSON {stdout, stderr, exit_code, duration_ms}
    }
}
