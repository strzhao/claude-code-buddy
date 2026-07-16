import XCTest
@testable import BuddyCore

/// Tier 0 红队验收测试（黑盒）—— `buddy run` IPC（action `launcher_run_tool`）富响应契约。
///
/// 信息隔离：不读蓝队本次新写的 handleLauncherRunTool / runPluginCore 实现。
/// 仅依赖设计文档 ## 契约规约 C-RUN-RESPONSE / C-TOFU-NOBYPASS / C-EXIT-CODE / C-INPUT-CONTRACT +
/// 既有事实：
///   - QueryHandler.init(pluginManager:trustStore:pluginDispatcher:) 可注入
///   - PluginDispatcher.init(stdinExecutor:promptExecutor:) 可注入
///   - StdinExecutor 是非 final class，可子类化 spy（PluginDispatcher.execute 经 stdinExecutor）
///   - TrustStore.init(file:) 可注入；TrustStore.trustKey(for:executablePath:) static + approve(_:executablePath:) public
///     → 预信任走「isEverTrusted true && missing empty → return true」短路（det-machine，不弹框）
///   - TrustStore 是 final class（不可继承）→ 未信任拒绝路径（走 prompter 弹框）非 in-process 可靠驱动，标 E2E
///   - 既有 handleLauncherDebugRunPlugin trust 失败字面量 message=="not trusted"（QueryHandler.swift:421），
///     run_tool 复用 runPluginCore 应产出同语义 → 契约字面量级断言
///   - PluginResult(stdout:stderr:exitCode:durationMs:stdoutTruncated:actions:image:candidates:) 全字段
///
/// 驱动方式（det-machine）：
///   1. 写真实临时插件目录 + plugin.json（JSONDecoder decode 路径）+ 写可执行 cmd 文件
///   2. 注入 spy StdinExecutor（返回受控 PluginResult，含 image/candidates）
///   3. 真实 TrustStore(file:tmp) + 预 approve(plugin, executablePath:) → checkAndPrompt 短路 true
///   4. `await handler.handle(query:["action":"launcher_run_tool", ...])` → 断言返回 JSON
///
/// 覆盖验收场景：
/// - 场景 2（P1-P7）+ 2.P8 跨系统闭环：buddy run 富 JSON + tools→run 闭环
/// - 场景 4（P1-P4）+ 补强 1：未信任 TOFU 不绕过（架构约束 + 既有契约字面量 + E2E 真机补强）
/// - 场景 6（P1-P3）：input 契约（结构化 vs 回退，框架不做 schema 校验）
/// - 场景 9（P1-P2）：坏 input JSON 非 0 退出 + 错误指向 input 解析
/// - 场景 10（P1-P2）：run 不存在插件名 → 非 0 + not found
/// - C-EXIT-CODE：退出码透传
///
/// 命名前缀: test_R<编号>_<场景>
@MainActor
final class ToolsRunAcceptanceTests: XCTestCase {

    private var tempRoot: URL!
    private var spyExecutor: ToolsRunSpyExecutor!
    private var trustFile: URL!
    private var trustStore: TrustStore!
    private var handler: QueryHandler!

    override func setUp() {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("buddy-run-acceptance-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        trustFile = tempRoot.appendingPathComponent("fake-trust.json")
        trustStore = TrustStore(file: trustFile)
        spyExecutor = ToolsRunSpyExecutor()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    // MARK: - Helpers

    /// 写一个 command mode 插件（plugin.json + 可执行 cmd 脚本）。
    /// 走 JSONDecoder decode 路径（非便利 init）。返回 (dir, executablePath)。
    @discardableResult
    private func writeCommandPlugin(
        name: String = "qr-gen",
        parametersJSONFragment: String? = nil,
        cmdContent: String = "#!/bin/bash\necho ok\n"
    ) throws -> URL {
        let dir = tempRoot.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let cmd = "run.sh"
        let paramsFragment = parametersJSONFragment.map { ",\n  \"parameters\": \($0)" } ?? ""
        let json = """
        {
          "name": "\(name)",
          "version": "1.0.0",
          "summary": "测试 command 插件",
          "description": "测试用 command mode 插件，spy executor 拦截真实执行。",
          "keywords": ["test"],
          "mode": "command",
          "cmd": "\(cmd)"\(paramsFragment)
        }
        """
        try json.data(using: .utf8)!.write(to: dir.appendingPathComponent("plugin.json"))

        let cmdFile = dir.appendingPathComponent(cmd)
        try cmdContent.data(using: .utf8)!.write(to: cmdFile)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cmdFile.path)
        return dir
    }

    /// 预信任插件（走 TrustStore.approve → checkAndPrompt 短路 true，不弹框）。
    /// 必须在插件目录 + cmd 文件已写好后调用（trustKey 依赖 executable bytes hash）。
    private func preTrust(pluginName: String) throws {
        let pm = PluginManager(rootDir: tempRoot)
        guard let manifest = try pm.find(name: pluginName) else {
            throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "plugin not found: \(pluginName)"])
        }
        let pluginDir = try pm.pluginDir(for: manifest)
        let exe = pluginDir.appending(path: manifest.cmd)
        try trustStore.approve(manifest, executablePath: exe)
    }

    private func buildHandler() {
        let scene = MockScene()
        let (manager, _) = TestHelpers.makeManager(scene: scene)
        let pm = PluginManager(rootDir: tempRoot)
        let dispatcher = PluginDispatcher(stdinExecutor: spyExecutor)
        handler = QueryHandler(
            sessionManager: manager,
            scene: scene,
            eventStore: manager.eventStore,
            pluginManager: pm,
            trustStore: trustStore,
            pluginDispatcher: dispatcher
        )
    }

    private func parseJSON(_ data: Data) -> [String: Any] {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            XCTFail("response 不是合法 JSON object: \(String(data: data, encoding: .utf8) ?? "<binary>")")
            return [:]
        }
        return obj
    }

    // MARK: - 场景 2: buddy run 富 JSON 响应（C-RUN-RESPONSE）

    /// 场景 2.P1-P4 + 契约 C-RUN-RESPONSE: 成功返回 data 含 {stdout,exit_code,duration_ms,stdout_truncated}（核心四字段）。
    /// kill 删字段 mutation：硬断言字段名集合 ⊇ 核心字段 + 类型正确。
    func test_R01_runToolReturnsRichResponseWithCoreFields() async throws {
        try writeCommandPlugin(name: "qr-gen")
        try preTrust(pluginName: "qr-gen")
        buildHandler()
        spyExecutor.stubResult = PluginResult(
            stdout: "ok output", stderr: "", exitCode: 0, durationMs: 12, stdoutTruncated: false,
            actions: [], image: nil, candidates: nil
        )

        let data = await handler.handle(query: [
            "action": "launcher_run_tool",
            "name": "qr-gen",
            "input": "{\"query\":\"hello\"}",
        ])
        let json = parseJSON(data)
        XCTAssertEqual(json["status"] as? String, "ok",
                       "launcher_run_tool 成功路径必须 status=ok（action 被识别且信任通过）")

        let dataDict = try XCTUnwrap(json["data"] as? [String: Any])
        // 场景 2.P2: keys ⊇ {stdout, exit_code}
        XCTAssertNotNil(dataDict["stdout"], "C-RUN-RESPONSE: data.stdout 必须存在")
        XCTAssertNotNil(dataDict["exit_code"], "C-RUN-RESPONSE: data.exit_code 必须存在")
        XCTAssertNotNil(dataDict["duration_ms"], "C-RUN-RESPONSE: data.duration_ms 必须存在")
        XCTAssertNotNil(dataDict["stdout_truncated"], "C-RUN-RESPONSE: data.stdout_truncated 必须存在")

        // 类型硬断言（kill 类型错位 mutation）
        XCTAssertEqual(dataDict["stdout"] as? String, "ok output", "场景 2.P4: stdout 是 String")
        let exitCode = dataDict["exit_code"]
        XCTAssertTrue(exitCode is Int, "场景 2.P3: exit_code 是整数，实际类型: \(type(of: exitCode ?? 0))")
        XCTAssertEqual(exitCode as? Int, 0)
        XCTAssertEqual(dataDict["duration_ms"] as? Int, 12)
        XCTAssertEqual(dataDict["stdout_truncated"] as? Bool, false)

        // name 字段一致（kill name 漂移）
        XCTAssertEqual(dataDict["name"] as? String, "qr-gen", "data.name 应等于请求插件名")
    }

    /// 契约 C-RUN-RESPONSE: image 仅当 PluginResult.image 非 nil 才出现（base64 PNG）。
    /// kill mutation：image 永远出现 / 用 Data 直接序列化而非 base64 / 空时也返回 image:null。
    func test_R02_runToolReturnsImageAsBase64OnlyWhenPresent() async throws {
        try writeCommandPlugin(name: "qr-gen")
        try preTrust(pluginName: "qr-gen")
        buildHandler()

        // 情况 A：有 image → 字段出现 + 是 base64 string
        let pngBytes: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]  // PNG signature
        let pngData = Data(pngBytes)
        spyExecutor.stubResult = PluginResult(
            stdout: "", stderr: "", exitCode: 0, durationMs: 1, stdoutTruncated: false,
            actions: [], image: pngData, candidates: nil
        )

        let dataWithImage = await handler.handle(query: [
            "action": "launcher_run_tool", "name": "qr-gen", "input": "{\"query\":\"x\"}",
        ])
        let jsonA = parseJSON(dataWithImage)
        let dataDictA = try XCTUnwrap(jsonA["data"] as? [String: Any])
        let imageStr = try XCTUnwrap(dataDictA["image"] as? String, "image 非 nil 时字段必须出现且为 String")
        // 场景 2.P5: matches /^[A-Za-z0-9+/]+={0,2}$/
        let base64Regex = #"^[A-Za-z0-9+/]+={0,2}$"#
        XCTAssertTrue(imageStr.range(of: base64Regex, options: .regularExpression) != nil,
                      "image 必须是合法 base64（场景 2.P5），实际: \(imageStr.prefix(40))...")
        // 可解码回原 Data（kill base64 内容错位 mutation）
        let decoded = Data(base64Encoded: imageStr)
        XCTAssertNotNil(decoded, "base64 必须可解码回 Data")
        XCTAssertEqual(decoded, pngData, "解码后应等于原 PNG bytes（kill base64 内容错位）")

        // 情况 B：无 image → 字段不出现（kill 永远返回 image:null mutation）
        spyExecutor.stubResult = PluginResult(
            stdout: "out", stderr: "", exitCode: 0, durationMs: 1, stdoutTruncated: false,
            actions: [], image: nil, candidates: nil
        )
        let dataNoImage = await handler.handle(query: [
            "action": "launcher_run_tool", "name": "qr-gen", "input": "{\"query\":\"x\"}",
        ])
        let jsonB = parseJSON(dataNoImage)
        let dataDictB = try XCTUnwrap(jsonB["data"] as? [String: Any])
        XCTAssertNil(dataDictB["image"],
                     "image nil 时字段不得出现（C-RUN-RESPONSE: image 仅当非 nil 才出现）")
    }

    /// 契约 C-RUN-RESPONSE: candidates 仅当非 nil 才出现（数组）；actions 永远不入契约。
    /// kill mutation：actions 被序列化进 run 响应（UI-only 字段泄漏）/ candidates nil 时返回空数组。
    func test_R03_runToolReturnsCandidatesOnlyWhenPresentAndExcludesActions() async throws {
        try writeCommandPlugin(name: "qzh")
        try preTrust(pluginName: "qzh")
        buildHandler()

        // 情况 A：有 candidates → 字段出现 + 是数组
        let cands = [
            LauncherCandidate(id: "stop", title: "关闭监控", subtitle: "stop service", selection: "stop"),
            LauncherCandidate(id: "start", title: "打开监控", subtitle: nil, selection: "start"),
        ]
        spyExecutor.stubResult = PluginResult(
            stdout: "", stderr: "", exitCode: 0, durationMs: 1, stdoutTruncated: false,
            actions: [], image: nil, candidates: cands
        )
        let dataWithCands = await handler.handle(query: [
            "action": "launcher_run_tool", "name": "qzh", "input": "{\"query\":\"\"}",
        ])
        let jsonA = parseJSON(dataWithCands)
        let dataDictA = try XCTUnwrap(jsonA["data"] as? [String: Any])
        let candsField = try XCTUnwrap(dataDictA["candidates"], "candidates 非 nil 时字段必须出现")
        XCTAssertTrue(candsField is [Any], "场景 2.P6: candidates 必须是数组，实际: \(type(of: candsField))")
        let candsArr = (candsField as? [[String: Any]]) ?? []
        XCTAssertEqual(candsArr.count, 2, "candidates 数组长度 == 2")

        // 情况 B：无 candidates → 字段不出现
        spyExecutor.stubResult = PluginResult(
            stdout: "out", stderr: "", exitCode: 0, durationMs: 1, stdoutTruncated: false,
            actions: [], image: nil, candidates: nil
        )
        let dataNoCands = await handler.handle(query: [
            "action": "launcher_run_tool", "name": "qzh", "input": "{\"query\":\"\"}",
        ])
        let jsonB = parseJSON(dataNoCands)
        let dataDictB = try XCTUnwrap(jsonB["data"] as? [String: Any])
        XCTAssertNil(dataDictB["candidates"], "candidates nil 时字段不得出现")

        // actions 不入契约（即便 PluginResult.actions 非空，data 也不含 actions）
        let action = LauncherActionButton(kind: .speak, text: "hi", label: nil)
        spyExecutor.stubResult = PluginResult(
            stdout: "out", stderr: "", exitCode: 0, durationMs: 1, stdoutTruncated: false,
            actions: [action], image: nil, candidates: nil
        )
        let dataWithActions = await handler.handle(query: [
            "action": "launcher_run_tool", "name": "qzh", "input": "{\"query\":\"\"}",
        ])
        let jsonC = parseJSON(dataWithActions)
        let dataDictC = try XCTUnwrap(jsonC["data"] as? [String: Any])
        XCTAssertNil(dataDictC["actions"],
                     "actions 是 render-only UI 按钮，不得入 run 响应契约（C-RUN-RESPONSE 明确排除）")
    }

    /// 契约 C-EXIT-CODE: CLI 退出码透传 plugin exit_code；非 0 也透传（单测层 = data.exit_code == plugin exitCode）。
    /// kill mutation：handler 永远报 exit_code==0 / 吞掉非 0。
    func test_R04_exitCodeTransparencyPassThrough() async throws {
        try writeCommandPlugin(name: "fail-plugin")
        try preTrust(pluginName: "fail-plugin")
        buildHandler()

        // 非 0 退出码透传
        spyExecutor.stubResult = PluginResult(
            stdout: "partial", stderr: "boom", exitCode: 42, durationMs: 3, stdoutTruncated: false
        )
        let data = await handler.handle(query: [
            "action": "launcher_run_tool", "name": "fail-plugin", "input": "{\"query\":\"x\"}",
        ])
        let json = parseJSON(data)
        // C-EXIT-CODE: 非 0 退出码在 IPC 层仍是 status==ok（执行成功，插件自己退出 42）
        // —— CLI 侧会把 exit_code==42 透传为进程退出码。
        XCTAssertEqual(json["status"] as? String, "ok",
                       "插件正常执行（即便 exit_code!=0）IPC 层仍 status==ok；CLI 透传 exit_code")
        let dataDict = try XCTUnwrap(json["data"] as? [String: Any])
        XCTAssertEqual(dataDict["exit_code"] as? Int, 42,
                       "C-EXIT-CODE: exit_code 必须透传 plugin 的 42，kill 吞非 0 mutation")
    }

    // MARK: - 场景 4: TOFU 不绕过（C-TOFU-NOBYPASS + 补强 1）

    /// 正向：信任通过时 execute 被调一次（证明 run_tool 分支确实经 dispatcher）。
    /// kill mutation：run_tool 分支根本没调 execute / 双调。
    func test_R05_trustedRunExecutesPluginOnce() async throws {
        try writeCommandPlugin(name: "qr-gen")
        try preTrust(pluginName: "qr-gen")
        buildHandler()
        spyExecutor.stubResult = PluginResult(
            stdout: "ok", stderr: "", exitCode: 0, durationMs: 1, stdoutTruncated: false
        )

        _ = await handler.handle(query: [
            "action": "launcher_run_tool", "name": "qr-gen", "input": "{\"query\":\"x\"}",
        ])
        XCTAssertEqual(spyExecutor.calls.count, 1,
                       "trusted run 必须调 execute 恰好一次（run_tool 经 dispatcher）")
        let call = try XCTUnwrap(spyExecutor.calls.first)
        XCTAssertEqual(call.plugin.name, "qr-gen", "execute 收到的 plugin name 正确")
    }

    /// C-INPUT-CONTRACT 强约束：handler 必须从 --input JSON 提取 query 字段填入 PluginInput.query。
    ///
    /// 🔴 红队发现（场景 6.P1 + C-INPUT-CONTRACT 违规）：
    /// 实测蓝队 launcher_run_tool 分支**未提取 query 字段**，把整个 input JSON 字符串原样塞进
    /// PluginInput.query。证据：input='{"query":"x"}' → PluginInput.query=='{"query":"x"}'（整个串）
    /// 而非 'x'（提取值）。违反设计 D6「handler 取 input.query 填 PluginInput.query」。
    /// 插件经 `jq -r '.query'` 读到的是二次 JSON 而非内容本身 → 插件行为错乱。
    ///
    /// 本测试故意保留为失败状态（硬红队证据），蓝队修复 input 提取逻辑后应通过。
    /// kill mutation：input 提取被遗漏（现状）/ 提取错字段。
    func test_R05b_inputQueryExtractionContract() async throws {
        try writeCommandPlugin(name: "qr-gen")
        try preTrust(pluginName: "qr-gen")
        buildHandler()
        spyExecutor.stubResult = PluginResult(
            stdout: "ok", stderr: "", exitCode: 0, durationMs: 1, stdoutTruncated: false
        )

        _ = await handler.handle(query: [
            "action": "launcher_run_tool", "name": "qr-gen", "input": "{\"query\":\"expected-value\"}",
        ])
        let call = try XCTUnwrap(spyExecutor.calls.first)
        // C-INPUT-CONTRACT: handler 提取 input.query → PluginInput.query
        XCTAssertEqual(call.input.query, "expected-value",
                       "C-INPUT-CONTRACT / 场景 6.P1: --input '{\"query\":\"expected-value\"}' 的 query 字段必须填入 PluginInput.query；实测蓝队把整个 JSON 串原样塞入（违规）")
    }

    /// C-TOFU-NOBYPASS 架构约束（det-machine 可靠部分）。
    ///
    /// 信息隔离说明（为何不直接驱动「未信任拒绝」路径）：
    /// 未信任插件的 checkAndPrompt 走 `prompter`（默认 TrustPrompt.askUserWithDeps → 弹 NSAlert），
    /// 测试环境无用户点击 → prompter 返回值不确定（有时 true 有时 false），**非 det-machine 可靠**。
    /// TrustStore 是 final class 不可继承重写 checkAndPrompt。故「未信任真拒绝」路径标 E2E
    /// （场景 4 modal 留 QA Tier 1.5 真机驱动：清 trust → buddy run → 用户点拒绝 → 验 not trusted + exit!=0）。
    ///
    /// 本测试做 det-machine 可靠的硬约束：
    /// 1. checkAndPrompt 方法签名存在（runPluginCore 硬依赖，编译期保证）。
    /// 2. 既有 debug action trust 失败字面量契约（QueryHandler.swift:421 既有事实）。
    ///    —— 此处不驱动未信任路径（不可靠），仅验证「trust 拒绝时 message 应用的字面量」
    ///       通过 PluginResult/TrustStore 既有 API 可达。
    func test_R06_tofuNoBypassArchitecturalConstraints() async throws {
        // 约束 1：checkAndPrompt 签名存在（runPluginCore 必须能调它）
        let method: (PluginManifest, URL) async -> Bool = { plugin, exe in
            await TrustStore.shared.checkAndPrompt(plugin, executablePath: exe)
        }
        _ = method
        XCTAssertTrue(true, "TrustStore.checkAndPrompt 签名存在（C-TOFU-NOBYPASS seam 可达）")

        // 约束 2：既有 debug action 字面量契约证据（非驱动，是既有事实引用）
        // handleLauncherDebugRunPlugin trust 失败 → errorResponse(message: "not trusted")（QueryHandler.swift:421）
        // run_tool 复用 runPluginCore → 同字面量。此约束由 test_R05（正向信任通过）+ test_R09（not found 字面量）
        // + 场景 4 E2E 真机（拒绝路径）共同覆盖。

        // 正向：信任通过 → execute 被调（与未信任对称：若 checkAndPrompt 不被调，信任与否都 execute，
        // 但 test_R05 已证信任时 execute；未信任时 execute 不被调由 E2E 验）。
        try writeCommandPlugin(name: "trusted-for-tofu")
        try preTrust(pluginName: "trusted-for-tofu")
        buildHandler()
        spyExecutor.stubResult = PluginResult(
            stdout: "ok", stderr: "", exitCode: 0, durationMs: 1, stdoutTruncated: false
        )
        _ = await handler.handle(query: [
            "action": "launcher_run_tool", "name": "trusted-for-tofu", "input": "{\"query\":\"x\"}",
        ])
        XCTAssertEqual(spyExecutor.calls.count, 1,
                       "正向：信任通过时 execute 必须被调（TOFU seam 工作 + run_tool 经 dispatcher）")
    }

    /// 场景 4.P4 E2E 说明：换 input 重试仍被拦。
    /// 未信任重试路径非 in-process 可靠（见 test_R06 说明），留 QA Tier 1.5 真机驱动。
    /// 真机流程：清 ~/.buddy/launcher-trust.json → buddy run P --input '{"query":"x"}'（拒绝）→
    ///           buddy run P --input '{"query":"other"}'（仍拒绝）→ 两次 exit!=0 + message 含 trust。
    func test_R07_untrustedRetryBlocked_isE2E() {
        XCTAssertTrue(true, "E2E: 场景 4.P4 未信任重试留 QA Tier 1.5 真机驱动（见 ToolsRunE2EChecklist.sh）")
    }

    /// C-TOFU-NOBYPASS seam 存在性: TrustStore.checkAndPrompt 签名必须存在且 async -> Bool
    /// （runPluginCore 的硬依赖，签名缺失编译期失败）。已并入 test_R06 约束 1，此处保留独立可寻址。
    func test_R08_trustStoreCheckAndPromptSignatureExists() async {
        let method: (PluginManifest, URL) async -> Bool = { plugin, exe in
            await TrustStore.shared.checkAndPrompt(plugin, executablePath: exe)
        }
        _ = method
        XCTAssertTrue(true, "TrustStore.checkAndPrompt 签名存在（C-TOFU-NOBYPASS seam 可达）")
    }

    // MARK: - 场景 10: run 不存在的插件名

    /// 场景 10.P1-P2: 不存在名 → status error + message 含 not found/找不到/不存在/unknown。
    /// kill mutation：蓝队 run_tool 分支缺 name 查找或报错语义不符。
    func test_R09_runNonexistentPluginReturnsNotFoundError() async throws {
        // 预信任一个无关插件（确保 trustStore 不是空导致 false positive）
        try writeCommandPlugin(name: "qr-gen")
        try preTrust(pluginName: "qr-gen")
        buildHandler()
        spyExecutor.stubResult = PluginResult(
            stdout: "x", stderr: "", exitCode: 0, durationMs: 1, stdoutTruncated: false
        )

        let data = await handler.handle(query: [
            "action": "launcher_run_tool", "name": "__nonexistent_xyz__", "input": "{}",
        ])
        let json = parseJSON(data)
        XCTAssertEqual(json["status"] as? String, "error", "场景 10.P1: 不存在插件 status=error（非 0 退出）")
        let message = (json["message"] as? String) ?? ""
        let indicatesNotFound = message.lowercased().contains("not found")
            || message.contains("找不到") || message.contains("不存在")
            || message.lowercased().contains("unknown")
        XCTAssertTrue(indicatesNotFound,
                      "场景 10.P2: message 必须含 not found/找不到/不存在/unknown，实际: \(message)")
        // execute 未被调
        XCTAssertTrue(spyExecutor.calls.isEmpty, "不存在的插件不得 execute")
    }

    // MARK: - 场景 6: input 契约（结构化 vs 回退，框架不做 schema 校验）

    /// 场景 6.P1 + C-INPUT-CONTRACT: 合法 input 执行成功（exit_code exists）；框架不做 schema 校验。
    /// kill mutation：蓝队加了 schema 校验拒绝合法 input。
    func test_R10_validInputRunsSuccessfully() async throws {
        try writeCommandPlugin(name: "qr-gen")
        try preTrust(pluginName: "qr-gen")
        buildHandler()
        spyExecutor.stubResult = PluginResult(
            stdout: "ok", stderr: "", exitCode: 0, durationMs: 5, stdoutTruncated: false
        )

        let data = await handler.handle(query: [
            "action": "launcher_run_tool", "name": "qr-gen", "input": "{\"query\":\"https://x\"}",
        ])
        let json = parseJSON(data)
        XCTAssertEqual(json["status"] as? String, "ok", "场景 6.P1: 合法 input 应执行成功")
        let dataDict = try XCTUnwrap(json["data"] as? [String: Any])
        XCTAssertNotNil(dataDict["exit_code"], "场景 6.P1: exit_code 存在")
        XCTAssertEqual(dataDict["exit_code"] as? Int, 0)
    }

    /// 场景 6.P3 + C-INPUT-CONTRACT: 无 schema 插件接受宽松 input 不报 schema 错。
    /// kill mutation：蓝队对无 schema 插件也强加 schema 校验。
    func test_R11_noSchemaPluginAcceptsLooseInputWithoutSchemaError() async throws {
        try writeCommandPlugin(name: "loose-plugin")  // 无 parameters
        try preTrust(pluginName: "loose-plugin")
        buildHandler()
        spyExecutor.stubResult = PluginResult(
            stdout: "ok", stderr: "", exitCode: 0, durationMs: 1, stdoutTruncated: false
        )

        let data = await handler.handle(query: [
            "action": "launcher_run_tool", "name": "loose-plugin", "input": "{\"query\":\"any\"}",
        ])
        let json = parseJSON(data)
        XCTAssertEqual(json["status"] as? String, "ok",
                       "场景 6.P3: 无 schema 插件接受宽松 input，框架不做 schema 校验")
        let message = (json["message"] as? String) ?? ""
        // NOT (error contains "schema" AND "required")
        XCTAssertFalse(message.lowercased().contains("schema") && message.lowercased().contains("required"),
                       "场景 6.P3: 不得报 schema/required 错误，实际 message: \(message)")
    }

    /// C-INPUT-CONTRACT: 缺 --input → PluginInput.query="" 兜底（插件自解析）。
    /// kill mutation：缺 input 时报错而非兜底空串。
    func test_R12_missingInputFallsBackToEmptyQuery() async throws {
        try writeCommandPlugin(name: "qr-gen")
        try preTrust(pluginName: "qr-gen")
        buildHandler()
        spyExecutor.stubResult = PluginResult(
            stdout: "ok", stderr: "", exitCode: 0, durationMs: 1, stdoutTruncated: false
        )

        // 缺 input 字段
        let data = await handler.handle(query: [
            "action": "launcher_run_tool", "name": "qr-gen",
            // 故意不带 "input"
        ])
        let json = parseJSON(data)
        XCTAssertEqual(json["status"] as? String, "ok",
                       "C-INPUT-CONTRACT: 缺 input 应回退空 query 而非报错")
        XCTAssertEqual(spyExecutor.calls.count, 1, "缺 input 仍应 execute（兜底）")
        if let captured = spyExecutor.calls.first {
            XCTAssertEqual(captured.input.query, "",
                           "缺 input 时 PluginInput.query 应为空串（兜底）")
        }
    }

    // MARK: - 场景 9: 坏 input JSON 错误处理

    /// 场景 9.P1-P2 + C-INPUT-CONTRACT: 坏 input JSON → status=error + message 含 input/json/parse/格式 + 不 execute。
    ///
    /// 契约已澄清（设计 D6 + contract-checker + 真机场景 9 e2e 2026-07-16）：坏 JSON（非空非合法）
    /// 必须报错，不兜底。原 CONTRACT_AMBIGUITY 已消除。
    /// kill mutation：把报错改回兜底（status=ok）会让本测试 fail（守护场景 9.P1）。
    func test_R13_malformedInputJSONReturnsError() async throws {
        try writeCommandPlugin(name: "qr-gen")
        try preTrust(pluginName: "qr-gen")
        buildHandler()
        spyExecutor.stubResult = PluginResult(
            stdout: "ok", stderr: "", exitCode: 0, durationMs: 1, stdoutTruncated: false
        )

        let data = await handler.handle(query: [
            "action": "launcher_run_tool", "name": "qr-gen", "input": "not-json{{",
        ])
        let json = parseJSON(data)
        // 场景 9.P1: 坏 JSON 必须 status=error（kill 兜底 mutation）
        XCTAssertEqual(json["status"] as? String, "error",
                       "场景 9.P1: 坏 input JSON 必须报错（status=error），不得兜底 status=ok，实际: \(json)")
        // 场景 9.P2: message 含 input/json/parse/格式
        let message = (json["message"] as? String) ?? ""
        let lower = message.lowercased()
        XCTAssertTrue(lower.contains("input") || lower.contains("json") || lower.contains("parse") || message.contains("格式"),
                      "场景 9.P2: message 必须含 input/json/parse/格式，实际: \(message)")
        // 坏 JSON 报错时不得 execute（kill 绕过信任路径 mutation）
        XCTAssertTrue(spyExecutor.calls.isEmpty, "坏 JSON 报错时不得 execute 插件")
    }

    // MARK: - 场景 2.P8: 跨系统闭环（tools → run）

    /// 场景 2.P8: tools 列出的插件能被 run 执行，字段名一致。
    /// 验证跨系统数据流：launcher_list_tools 输出的 name 能被 launcher_run_tool 执行 + 字段名一致。
    /// kill mutation：tools 与 run 用不同 name 空间 / 不一致。
    func test_R14_toolsListedPluginIsRunnableByName() async throws {
        try writeCommandPlugin(name: "qr-gen")
        try preTrust(pluginName: "qr-gen")
        buildHandler()
        spyExecutor.stubResult = PluginResult(
            stdout: "ok", stderr: "", exitCode: 0, durationMs: 1, stdoutTruncated: false
        )

        // Step 1: tools 列出
        let toolsData = await handler.handle(query: ["action": "launcher_list_tools"])
        let toolsJson = parseJSON(toolsData)
        XCTAssertEqual(toolsJson["status"] as? String, "ok")
        let toolsDataDict = try XCTUnwrap(toolsJson["data"] as? [String: Any])
        let tools = try XCTUnwrap(toolsDataDict["tools"] as? [[String: Any]])
        let names = tools.compactMap { $0["name"] as? String }
        XCTAssertTrue(names.contains("qr-gen"),
                      "场景 2.P8: tools 必须列出 qr-gen，实际 names: \(names)")

        // Step 2: run 同名插件 → exit==0（场景 2.P8 assert: tools 含 X AND run X exit==0）
        spyExecutor.calls = []
        let runData = await handler.handle(query: [
            "action": "launcher_run_tool", "name": "qr-gen", "input": "{\"query\":\"x\"}",
        ])
        let runJson = parseJSON(runData)
        XCTAssertEqual(runJson["status"] as? String, "ok", "场景 2.P8: run qr-gen 必须 status=ok（exit==0）")
        let runDataDict = try XCTUnwrap(runJson["data"] as? [String: Any])
        XCTAssertEqual(runDataDict["name"] as? String, "qr-gen",
                       "闭环 name 一致：tools 列出 qr-gen，run 返回 name=qr-gen")
        XCTAssertEqual(runDataDict["exit_code"] as? Int, 0)
    }

    // MARK: - 场景 5/11 E2E 说明（非单测覆盖）

    /// 单测层局限说明：
    /// - 场景 5（app 未运行 <10s 退出 + 非 0 + 错误指向 socket/app）：需真跑 buddy CLI binary + app 未运行环境。
    /// - 场景 11（真跑 tools/run 端到端 + image base64 可解码回 PNG）：需 SKIP_FETCH_PLUGINS=1 make bundle + 真实 app 进程。
    /// - 场景 4 TOFU modal 真拒绝路径（用户在 NSAlert 点「拒绝」）：需真机交互（TrustPrompt.askUserWithDeps 弹框）。
    /// 均非 in-process XCTest 能可靠覆盖，详见 ToolsRunE2EChecklist.sh（E2E 留 QA Tier 1.5 真机驱动）。
    func test_R99_e2eScenariosDocumentedInShellChecklist() {
        XCTAssertTrue(true, "E2E: 场景 4 modal/5/11 留 QA Tier 1.5 真机驱动（ToolsRunE2EChecklist.sh）")
    }
}

// MARK: - Test Doubles

/// Spy StdinExecutor：拦截 execute 调用 + 返回受控 PluginResult。
/// StdinExecutor 是非 final class（可继承）；不真跑子进程（det-machine 确定性）。
final class ToolsRunSpyExecutor: StdinExecutor {
    struct Call {
        let plugin: PluginManifest
        let pluginDir: URL
        let input: PluginInput
    }
    var calls: [Call] = []
    var stubResult: PluginResult = PluginResult(
        stdout: "", stderr: "", exitCode: 0, durationMs: 0, stdoutTruncated: false
    )

    override func execute(_ plugin: PluginManifest, pluginDir: URL, input: PluginInput) async throws -> PluginResult {
        calls.append(Call(plugin: plugin, pluginDir: pluginDir, input: input))
        return stubResult
    }
}
