import XCTest
import AppKit
@testable import BuddyCore

// MARK: - CommandAutoCopyExtAcceptanceTests
//
// 红队验收测试：扩展 A — command mode autoCopy（设计文档「形态1 所需架构扩展 A」）
//
// 本文件覆盖（det-machine 谓词，期望值逐字取自 state.md ## 验收场景 assert 列）：
//   AC-SNIP-01（autoCopy 相关切片）：command + autoCopy=true 时 stdout → 框架代写剪贴板
//   AC-SNIP-16（依赖扩展 A）：get 命中 → stdout 输出片段 + 框架 autoCopy 使 Cmd+V 可粘贴
//   契约 C3：get 命中 → stdout 输出片段 + 框架代写系统剪贴板；snip plugin.json 声明 autoCopyToClipboard:true
//   契约（扩展 A）：CommandConfig.autoCopyToClipboard: Bool（decodeIfPresent ?? false，向后兼容）
//   便利属性 commandConfig?.autoCopyToClipboard ?? false（对称 promptConfig.autoCopyToClipboard）
//
// 红队红线：
//   - 不读取 apps/desktop/Sources/ClaudeCodeBuddy/Launcher/Plugin/PluginManifest.swift 新写的实现逻辑
//   - 仅依据设计文档契约逐字断言（字段名/decodeIfPresent 边界/trustKey 不含 autoCopy）
//   - 强断言：注入隔离 NSPasteboard + CopyService，断言实际写入内容（反 no-op "copy 不抛错" 宽容断言）
//   - 向后兼容：旧 plugin.json 无 autoCopyToClipboard 字段 → command mode decode → false（行为不变）
//   - trustKey 不含 autoCopy 字段：改 autoCopy 不应失效旧 trust（声明性，靠 trustKey 公式 = SHA256(cmd+args+exe bytes) + mode 前缀）
//
// 测试 WILL NOT compile 直到蓝队合并实现 — 这是预期的 TDD 红灯。
//
// CONTRACT_AMBIGUOUS:
//   1. CopyService 注入方式：参考既有 CalculatorPlugin(copyService:) 模式 + CopyService(pasteboard:) 构造器。
//      submitCommandDirect 调 CopyService.shared.copy(stdout)（设计文档 T0），故断言实际写入路径：
//      a) PluginManifest decode 出 autoCopyToClipboard=true
//      b) submitCommandDirect 在 command+autoCopy+stdout 非空时调 CopyService.shared.copy
//      （蓝队需暴露注入点或测试以 spy 形式接入，类似 stdinExecutorOverride）
//   2. trustKey 公式：契约声明 trustKey = SHA256(cmd+args+exe bytes) + mode 前缀，**不含 autoCopy**。
//      测试以「同 cmd/args/exe/mode 但 autoCopy 字段不同 → trustKey 一致」断言（防 I4 退化）。
//      ⚠️ 若 TrustStore 未暴露 trustKey 计算函数（通常私有），此测试降级为契约注释（VISUAL_RESIDUE）。

@MainActor
final class CommandAutoCopyExtAcceptanceTests: XCTestCase {

    // MARK: - 扩展 A 契约：CommandConfig.autoCopyToClipboard 字段

    /// 扩展 A：plugin.json 含 `"autoCopyToClipboard": true` + mode=command → CommandConfig.autoCopyToClipboard == true
    ///
    /// Mutation-Survival 自检：
    /// - 字段名拼错 mutant（如 autoCopy 不带 ToClipboard）→ 不命中契约字段 → decode 后 false → 本断言失败（捕获）
    /// - decodeIfPresent 漏写 ?? false mutant → 字段缺失时 throw → 本断言失败（捕获）
    func test_extA_commandConfig_decodesAutoCopyTrue() throws {
        let json: [String: Any] = [
            "name": "snip",
            "version": "0.1.0",
            "description": "snip fixture",
            "keywords": ["snip"],
            "mode": "command",
            "cmd": "./snip.sh",
            "args": [] as [String],
            "env": NSNull(),
            "requiredPath": NSNull(),
            "timeout": 5,
            "autoCopyToClipboard": true
        ]
        let data = try JSONSerialization.data(withJSONObject: json)
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: data)

        // 真实 API：PluginManifest 无 `mode` 属性，只有 `modeConfig`（枚举带 associated value）；
        // 用 `commandConfig != nil` 等价断言「mode == command」（访问器调整，期望值语义保留）。
        XCTAssertNotNil(manifest.commandConfig, "ext A precondition: mode 必须 == .command")
        XCTAssertEqual(manifest.commandConfig?.autoCopyToClipboard, true,
            "扩展 A (mutation-killer): plugin.json autoCopyToClipboard:true + mode=command → CommandConfig.autoCopyToClipboard 必须 == true")
    }

    /// 扩展 A 向后兼容：旧 plugin.json 无 autoCopyToClipboard 字段 + mode=command → decode 不抛错，CommandConfig.autoCopyToClipboard == false
    ///
    /// Mutation-Survival 自检：
    /// - 字段改成 required（非 decodeIfPresent）mutant → 旧 JSON 缺字段 decode 抛错 → 本断言失败（捕获）
    func test_extA_commandConfig_decodeIfPresent_backwardsCompat_false() throws {
        let json: [String: Any] = [
            "name": "snip-old",
            "version": "0.1.0",
            "description": "old command plugin no autoCopy",
            "keywords": ["snip-old"],
            "mode": "command",
            "cmd": "./snip-old.sh",
            "args": [] as [String],
            "env": NSNull(),
            "requiredPath": NSNull(),
            "timeout": 5
            // 故意不写 autoCopyToClipboard —— 模拟旧 plugin.json
        ]
        let data = try JSONSerialization.data(withJSONObject: json)

        // 旧 JSON decode 不应抛错
        let manifest = try XCTAssertNoThrowResult(
            try JSONDecoder().decode(PluginManifest.self, from: data),
            "扩展 A 向后兼容: 旧 plugin.json 无 autoCopyToClipboard 字段 decode 不应抛错"
        )

        XCTAssertNotNil(manifest.commandConfig, "ext A precondition: mode 必须 == .command")
        XCTAssertEqual(manifest.commandConfig?.autoCopyToClipboard, false,
            "扩展 A (mutation-killer): 旧 plugin.json 无 autoCopyToClipboard → CommandConfig.autoCopyToClipboard 必须 == false（decodeIfPresent ?? false）")
    }

    /// 扩展 A 便利属性：manifest.autoCopyToClipboard（对称 PromptConfig.autoCopyToClipboard）
    /// 对 command mode + autoCopyToClipboard:true 的 manifest，便利属性应返回 true
    ///
    /// 设计文档 T0：「便利属性（:313-320）扩展 commandConfig?.autoCopyToClipboard ?? false」
    ///
    /// Mutation-Survival 自检：
    /// - 便利属性仅查 promptConfig mutant（当前旧逻辑）→ command manifest 返回 false → 本断言失败（捕获）
    func test_extA_convenience_autoCopyToClipboard_returnsTrueForCommand() throws {
        let json: [String: Any] = [
            "name": "snip",
            "version": "0.1.0",
            "description": "snip",
            "keywords": ["snip"],
            "mode": "command",
            "cmd": "./snip.sh",
            "args": [] as [String],
            "env": NSNull(),
            "requiredPath": NSNull(),
            "timeout": 5,
            "autoCopyToClipboard": true
        ]
        let data = try JSONSerialization.data(withJSONObject: json)
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: data)

        // 便利属性（顶层 manifest.autoCopyToClipboard）必须覆盖 command case（设计文档 T0）
        XCTAssertEqual(manifest.autoCopyToClipboard, true,
            "扩展 A (mutation-killer): manifest.autoCopyToClipboard 便利属性对 command mode + autoCopyToClipboard:true 必须 == true（对称 prompt mode，不能仅查 promptConfig）")
    }

    /// 扩展 A 便利属性默认值：旧 command plugin.json 无字段 → manifest.autoCopyToClipboard == false
    func test_extA_convenience_autoCopyToClipboard_defaultFalse() throws {
        let json: [String: Any] = [
            "name": "snip-old",
            "version": "0.1.0",
            "description": "old",
            "keywords": ["snip-old"],
            "mode": "command",
            "cmd": "./snip-old.sh",
            "args": [] as [String],
            "env": NSNull(),
            "requiredPath": NSNull(),
            "timeout": 5
        ]
        let data = try JSONSerialization.data(withJSONObject: json)
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: data)

        XCTAssertEqual(manifest.autoCopyToClipboard, false,
            "扩展 A: 旧 command manifest.autoCopyToClipboard 必须 == false（向后兼容）")
    }

    // MARK: - 扩展 A 执行层：submitCommandDirect 在 command+autoCopy+stdout 非空时调 CopyService

    /// AC-SNIP-01 / AC-SNIP-16 切片（扩展 A）：command mode + autoCopy=true + stdout 非空
    /// → submitCommandDirect 必须调 CopyService.shared.copy(stdout)
    ///
    /// 设计文档 T0：「LauncherManager.submitCommandDirect 在 command + autoCopy + stdout 非空时调 CopyService.shared.copy(stdout)」
    ///
    /// 验证路径：注入 StdinExecutor spy 让 PluginResult.stdout="SPY_STDOUT"，调 submitCommandDirect，
    /// 断言 CopyService.shared（系统剪贴板）被写入 == "SPY_STDOUT"。
    ///
    /// ⚠️ 系统剪贴板有副作用，测试前后清理 + 用 sentinel 验证。
    /// ⚠️ 若蓝队未暴露 CopyService 注入点（copyServiceOverride），此测试需依赖系统剪贴板（CI 上可能受污染）；
    ///    CONTRACT_AMBIGUOUS：建议蓝队暴露 copyServiceOverride seam（对称 stdinExecutorOverride）。
    func test_AC_SNIP_01_extA_submitCommandDirect_autoCopy_writesToPasteboard() async throws {
        // 1. 系统剪贴板预埋 sentinel
        let sentinel = "ccb-snip-sentinel-\(UUID().uuidString)"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(sentinel, forType: .string)

        // 2. 构造 command + autoCopy=true 的 manifest
        let manifest = try makeCommandAutoCopyManifest(name: "snip", autoCopy: true)
        LauncherManager.shared.pluginsOverride = [manifest]

        // 2b. 测试基础设施 setup（让 submitCommandDirect 真到达 spy）：
        //   submitCommandDirect 内部 Task.detached 依次走 ① pluginManagerOverride.pluginDir(for:)
        //   （需 rootDir/<name> 目录存在，否则 pluginNotFound 提前退出）→ ② TrustStore.checkAndPrompt
        //   （未预置 trust 会弹 NSAlert 挂死测试，需 TrustStore.shared.approve 预置）→ ③ dispatcher.execute
        //   （此处接 stdinExecutorOverride spy）。缺任一 → spy 不会被调（executeCallCount == 0）。
        //   参考 CandidatesChannelAcceptanceTests.test_C5 的 setup 模式（makePlugin + approve + override）。
        let tmpRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccb-snip-autocopy-\(UUID().uuidString)")
        let pluginDir = tmpRoot.appendingPathComponent("snip")
        try FileManager.default.createDirectory(at: pluginDir, withIntermediateDirectories: true)
        // pluginDir 需有 plugin.json（pluginManagerOverride 扫描时校验）
        let manifestJSON = """
        {
          "name": "snip",
          "version": "0.1.0",
          "description": "autoCopy test fixture",
          "keywords": ["snip-kw"],
          "mode": "command",
          "cmd": "./snip.sh",
          "args": [],
          "env": null,
          "requiredPath": null,
          "timeout": 5,
          "autoCopyToClipboard": true
        }
        """
        try manifestJSON.write(to: pluginDir.appendingPathComponent("plugin.json"),
                              atomically: true, encoding: .utf8)
        // 占位脚本文件（trust 校验 executablePath 的 sha256，需文件存在；spy 接管后不会真执行）
        let placeholderScript = "#!/bin/bash\necho placeholder\n"
        let scriptURL = pluginDir.appendingPathComponent("snip.sh")
        try placeholderScript.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        // 预置 trust（避免 TOFU NSAlert 挂死测试）
        try TrustStore.shared.approve(manifest, executablePath: scriptURL)
        // 注入 pluginManagerOverride 指向 tmpRoot（pluginDir 解析 rootDir/snip 命中）
        LauncherManager.shared.pluginManagerOverride = PluginManager(rootDir: tmpRoot)
        LauncherManager.shared.resetSubmittingStateForTesting()
        defer {
            try? FileManager.default.removeItem(at: tmpRoot)
            LauncherManager.shared.pluginManagerOverride = nil
        }

        // 3. 注入 spy 让子进程返回 stdout="SNIP_AUTO_COPIED"
        let spy = SnipAutoCopySpyStdinExecutor()
        spy.resultFactory = { _ in
            PluginResult(stdout: "SNIP_AUTO_COPIED", stderr: "", exitCode: 0,
                         durationMs: 0, stdoutTruncated: false, image: nil, candidates: nil)
        }
        LauncherManager.shared.stdinExecutorOverride = spy
        defer {
            LauncherManager.shared.pluginsOverride = nil
            LauncherManager.shared.stdinExecutorOverride = nil
        }

        // 4. 调 submitCommandDirect（command 短路入口）
        let stream = LauncherManager.shared.submitCommandDirect(manifest, query: "sig")
        var events: [AgentEvent] = []
        for await ev in stream { events.append(ev) }

        // 5. 断言：spy 被调（证明走了 command 短路，非 LLM）
        XCTAssertEqual(spy.executeCallCount, 1,
            "AC-SNIP-01 / ext A: submitCommandDirect 必须 dispatch 1 次到 StdinExecutor（command 短路，零 LLM）")

        // 6. 断言：系统剪贴板被框架代写 == "SNIP_AUTO_COPIED"
        let actual = NSPasteboard.general.string(forType: .string)
        XCTAssertEqual(actual, "SNIP_AUTO_COPIED",
            "AC-SNIP-01 / AC-SNIP-16 (mutation-killer, 扩展 A): command+autoCopy+stdout 非空 → submitCommandDirect 必须调 CopyService.shared.copy 写入剪贴板 == \"SNIP_AUTO_COPIED\"，实际 \"\(actual ?? "nil")\"（若仍是 sentinel=\"\(sentinel)\" 则框架未 autoCopy）")
    }

    /// 扩展 A 反向：command + autoCopy=false（或旧插件无字段）+ stdout 非空 → 不动系统剪贴板
    ///
    /// Mutation-Survival 自检：
    /// - 不分 autoCopy 真假永远 copy mutant → autoCopy=false 时也写剪贴板 → sentinel 被覆盖 → 本断言失败（捕获）
    func test_extA_submitCommandDirect_autoCopyFalse_doesNotTouchPasteboard() async throws {
        let sentinel = "ccb-snip-false-\(UUID().uuidString)"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(sentinel, forType: .string)

        // autoCopy=false（模拟旧插件）
        let manifest = try makeCommandAutoCopyManifest(name: "snip-old", autoCopy: false)
        LauncherManager.shared.pluginsOverride = [manifest]

        let spy = SnipAutoCopySpyStdinExecutor()
        spy.resultFactory = { _ in
            PluginResult(stdout: "SHOULD_NOT_COPY", stderr: "", exitCode: 0,
                         durationMs: 0, stdoutTruncated: false, image: nil, candidates: nil)
        }
        LauncherManager.shared.stdinExecutorOverride = spy
        defer {
            LauncherManager.shared.pluginsOverride = nil
            LauncherManager.shared.stdinExecutorOverride = nil
        }

        let stream = LauncherManager.shared.submitCommandDirect(manifest, query: "x")
        for await _ in stream {}

        let actual = NSPasteboard.general.string(forType: .string)
        XCTAssertEqual(actual, sentinel,
            "扩展 A (mutation-killer): autoCopy=false → 框架不应动系统剪贴板，sentinel 必须 == \"\(sentinel)\"，实际 \"\(actual ?? "nil")\"")
    }

    /// 扩展 A 边缘：command + autoCopy=true + stdout 空 → 不调 copy（无内容可复制）
    ///
    /// Mutation-Survival 自检：
    /// - 不判 stdout 空就 copy mutant → 写空串到剪贴板 → sentinel 被覆盖 → 本断言失败（捕获）
    func test_extA_submitCommandDirect_emptyStdout_doesNotCopy() async throws {
        let sentinel = "ccb-snip-empty-\(UUID().uuidString)"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(sentinel, forType: .string)

        let manifest = try makeCommandAutoCopyManifest(name: "snip", autoCopy: true)
        LauncherManager.shared.pluginsOverride = [manifest]

        let spy = SnipAutoCopySpyStdinExecutor()
        spy.resultFactory = { _ in
            PluginResult(stdout: "", stderr: "", exitCode: 0,
                         durationMs: 0, stdoutTruncated: false, image: nil, candidates: nil)
        }
        LauncherManager.shared.stdinExecutorOverride = spy
        defer {
            LauncherManager.shared.pluginsOverride = nil
            LauncherManager.shared.stdinExecutorOverride = nil
        }

        let stream = LauncherManager.shared.submitCommandDirect(manifest, query: "x")
        for await _ in stream {}

        let actual = NSPasteboard.general.string(forType: .string)
        XCTAssertEqual(actual, sentinel,
            "扩展 A (mutation-killer): autoCopy=true 但 stdout 空 → 不应 copy（无内容可复制），sentinel 保留 == \"\(sentinel)\"，实际 \"\(actual ?? "nil")\"")
    }

    // MARK: - 扩展 A 候选回调路径：submitWithCandidate 在 command+autoCopy+stdout 非空时调 CopyService
    //
    // 对称 submitCommandDirect 的 autoCopy（修 snip bug：选中片段候选 → 复制内容，不再删除）。
    // 候选回调路径 submitWithCandidate 之前无 autoCopy，导致 snip 选中候选（selection=copy:<kw>）
    // 输出 content 后不写剪贴板。本测试守护该路径的 autoCopy。

    /// AC-SNIP-01 切片（候选回调路径）：command + autoCopy=true + stdout 非空 + 无候选产物
    /// → submitWithCandidate 必须调 CopyService.shared.copy(stdout) 写剪贴板。
    ///
    /// Mutation-Survival 自检：
    /// - submitWithCandidate 漏掉 autoCopy mutant → 剪贴板保留 sentinel → 本断言失败（捕获）
    func test_extA_submitWithCandidate_autoCopy_writesToPasteboard() async throws {
        let sentinel = "ccb-snip-cb-sentinel-\(UUID().uuidString)"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(sentinel, forType: .string)

        let manifest = try makeCommandAutoCopyManifest(name: "snip", autoCopy: true)
        LauncherManager.shared.pluginsOverride = [manifest]

        // setup 同 submitCommandDirect 测试：tmpDir + plugin.json + snip.sh + trust + override
        let tmpRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccb-snip-cb-\(UUID().uuidString)")
        let pluginDir = tmpRoot.appendingPathComponent("snip")
        try FileManager.default.createDirectory(at: pluginDir, withIntermediateDirectories: true)
        let manifestJSON = """
        {
          "name": "snip",
          "version": "0.1.0",
          "description": "submitWithCandidate autoCopy fixture",
          "keywords": ["snip-kw"],
          "mode": "command",
          "cmd": "./snip.sh",
          "args": [],
          "env": null,
          "requiredPath": null,
          "timeout": 5,
          "autoCopyToClipboard": true
        }
        """
        try manifestJSON.write(to: pluginDir.appendingPathComponent("plugin.json"),
                              atomically: true, encoding: .utf8)
        let placeholderScript = "#!/bin/bash\necho placeholder\n"
        let scriptURL = pluginDir.appendingPathComponent("snip.sh")
        try placeholderScript.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        try TrustStore.shared.approve(manifest, executablePath: scriptURL)
        LauncherManager.shared.pluginManagerOverride = PluginManager(rootDir: tmpRoot)
        LauncherManager.shared.resetSubmittingStateForTesting()
        defer {
            try? FileManager.default.removeItem(at: tmpRoot)
            LauncherManager.shared.pluginManagerOverride = nil
        }

        // spy 返回 stdout="SNIP_CB_CONTENT" + candidates=nil（满足 autoCopy 条件）
        let spy = SnipAutoCopySpyStdinExecutor()
        spy.resultFactory = { _ in
            PluginResult(stdout: "SNIP_CB_CONTENT", stderr: "", exitCode: 0,
                         durationMs: 0, stdoutTruncated: false, image: nil, candidates: nil)
        }
        LauncherManager.shared.stdinExecutorOverride = spy
        defer {
            LauncherManager.shared.pluginsOverride = nil
            LauncherManager.shared.stdinExecutorOverride = nil
        }

        // 调 submitWithCandidate（候选回调入口，模拟用户选中片段候选 selection=copy:sig）
        let stream = LauncherManager.shared.submitWithCandidate(
            manifest, selection: "copy:sig", query: "snip"
        )
        for await _ in stream {}

        // 断言：spy 被调 1 次 + selection 透传给插件
        XCTAssertEqual(spy.executeCallCount, 1,
            "submitWithCandidate 必须 dispatch 1 次到 StdinExecutor（command 回调，零 LLM）")
        XCTAssertEqual(spy.capturedInputs.first?.selection, "copy:sig",
            "submitWithCandidate 必须把 selection 透传给插件 PluginInput.selection == \"copy:sig\"")

        // 断言：剪贴板被框架代写 == "SNIP_CB_CONTENT"
        let actual = NSPasteboard.general.string(forType: .string)
        XCTAssertEqual(actual, "SNIP_CB_CONTENT",
            "submitWithCandidate autoCopy (mutation-killer): command+autoCopy+stdout 非空 → 必须调 CopyService.shared.copy 写剪贴板 == \"SNIP_CB_CONTENT\"，实际 \"\(actual ?? "nil")\"（若仍是 sentinel=\"\(sentinel)\" 则候选回调路径未 autoCopy）")
    }

    /// 扩展 A 候选回调路径反向：autoCopy=true 但子进程返回候选产物（result.candidates 非空）
    /// → 不 autoCopy（候选场景由用户后续选中决定，避免列候选时污染剪贴板）。
    ///
    /// Mutation-Survival 自检：
    /// - 不判 candidates 非空就 copy mutant → 列候选时污染剪贴板 → sentinel 被覆盖 → 本断言失败
    func test_extA_submitWithCandidate_candidatesReturned_doesNotAutoCopy() async throws {
        let sentinel = "ccb-snip-cb-cand-\(UUID().uuidString)"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(sentinel, forType: .string)

        let manifest = try makeCommandAutoCopyManifest(name: "snip", autoCopy: true)
        LauncherManager.shared.pluginsOverride = [manifest]

        let tmpRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccb-snip-cb-cand-\(UUID().uuidString)")
        let pluginDir = tmpRoot.appendingPathComponent("snip")
        try FileManager.default.createDirectory(at: pluginDir, withIntermediateDirectories: true)
        let manifestJSON = """
        {"name":"snip","version":"0.1.0","description":"cand fixture","keywords":["snip-kw"],
         "mode":"command","cmd":"./snip.sh","args":[],"env":null,"requiredPath":null,
         "timeout":5,"autoCopyToClipboard":true}
        """
        try manifestJSON.write(to: pluginDir.appendingPathComponent("plugin.json"),
                              atomically: true, encoding: .utf8)
        let scriptURL = pluginDir.appendingPathComponent("snip.sh")
        try "#!/bin/bash\necho placeholder\n".write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        try TrustStore.shared.approve(manifest, executablePath: scriptURL)
        LauncherManager.shared.pluginManagerOverride = PluginManager(rootDir: tmpRoot)
        LauncherManager.shared.resetSubmittingStateForTesting()
        defer {
            try? FileManager.default.removeItem(at: tmpRoot)
            LauncherManager.shared.pluginManagerOverride = nil
        }

        // spy 返回 stdout 非空 + candidates 非空（候选场景）
        let spy = SnipAutoCopySpyStdinExecutor()
        spy.resultFactory = { _ in
            PluginResult(stdout: "候选列表", stderr: "", exitCode: 0, durationMs: 0,
                         stdoutTruncated: false, image: nil,
                         candidates: [LauncherCandidate(id: "x", title: "x", subtitle: nil, selection: "copy:x")])
        }
        LauncherManager.shared.stdinExecutorOverride = spy
        defer {
            LauncherManager.shared.pluginsOverride = nil
            LauncherManager.shared.stdinExecutorOverride = nil
        }

        let stream = LauncherManager.shared.submitWithCandidate(
            manifest, selection: "copy:sig", query: "snip"
        )
        for await _ in stream {}

        let actual = NSPasteboard.general.string(forType: .string)
        XCTAssertEqual(actual, sentinel,
            "submitWithCandidate (mutation-killer): autoCopy=true 但 candidates 非空 → 不应 autoCopy（候选场景由后续选中决定），sentinel 保留 == \"\(sentinel)\"，实际 \"\(actual ?? "nil")\"")
    }

    // MARK: - 扩展 A trustKey 不含 autoCopy（I4 声明）

    /// AC-SNIP-12 信任流相关切片 / 契约 trustKey 不含 autoCopy：
    /// 同 cmd/args/exe/mode 但 autoCopy 字段不同 → trustKey 应一致（改 autoCopy 不失效旧 trust）
    ///
    /// 设计文档 T0 / I4 声明：「trustKey 不含 autoCopy 字段（I4 声明：改 autoCopy 不失效旧 trust）」
    ///
    /// ⚠️ TrustStore 通常不暴露 trustKey 计算函数（私有）。CONTRACT_AMBIGUOUS：
    ///    若蓝队暴露了 `TrustStore.trustKey(for: PluginManifest)` 静态/实例方法，本测试可断言。
    ///    否则降级为 VISUAL_RESIDUE（留 QA 真机核对：改 plugin.json 的 autoCopy 字段后 inspect trust 不应弹 TOFU）。
    ///
    /// VISUAL_RESIDUE: 留 QA 真机判定（若 TrustStore 未暴露 trustKey API）
    func test_extA_trustKey_excludesAutoCopyField() throws {
        let m1 = try makeCommandAutoCopyManifest(name: "snip", autoCopy: false)
        let m2 = try makeCommandAutoCopyManifest(name: "snip", autoCopy: true)

        // 同 cmd/args/exe/mode，仅 autoCopy 不同
        XCTAssertEqual(m1.cmd, m2.cmd, "ext A precondition: cmd 一致")
        XCTAssertEqual(m1.args, m2.args, "ext A precondition: args 一致")
        XCTAssertNotNil(m1.commandConfig, "ext A precondition: m1 mode == .command")
        XCTAssertNotNil(m2.commandConfig, "ext A precondition: m2 mode == .command")

        // CONTRACT_AMBIGUOUS: 若 TrustStore 暴露 trustKey API：
        // let key1 = TrustStore.shared.trustKey(for: m1)
        // let key2 = TrustStore.shared.trustKey(for: m2)
        // XCTAssertEqual(key1, key2, "扩展 A / I4 (mutation-killer): trustKey 不含 autoCopy 字段，改 autoCopy 不应失效旧 trust")

        // 当前降级为 schema 一致性断言（可机器验证的部分）：
        // cmd/args/exe/mode 一致 → 若 trustKey 公式仅基于这些（设计文档声明），则 autoCopy 字段差异不应影响 trustKey。
        // VISUAL_RESIDUE: 留 QA 真机判定（改 autoCopy 后 inspect trust 状态）
    }
}

// MARK: - Helpers

/// 构造 command mode + autoCopyToClipboard 的 PluginManifest fixture
@MainActor
private func makeCommandAutoCopyManifest(name: String, autoCopy: Bool) throws -> PluginManifest {
    let json: [String: Any] = [
        "name": name,
        "version": "0.1.0",
        "description": "command autoCopy fixture",
        "keywords": ["\(name)-kw"],
        "mode": "command",
        "cmd": "./\(name).sh",
        "args": [] as [String],
        "env": NSNull(),
        "requiredPath": NSNull(),
        "timeout": 5,
        "autoCopyToClipboard": autoCopy
    ]
    let data = try JSONSerialization.data(withJSONObject: json)
    return try JSONDecoder().decode(PluginManifest.self, from: data)
}

/// XCTest XCTAssertNoThrowResult helper —— 返回表达式结果（既有风格简化）
private func XCTAssertNoThrowResult<T>(_ expression: @autoclosure () throws -> T,
                                        _ message: String = "",
                                        file: StaticString = #file, line: UInt = #line) throws -> T {
    do {
        return try expression()
    } catch {
        XCTFail("\(message) — 抛错: \(error)", file: file, line: line)
        throw error
    }
}

/// spy：StdinExecutor 子类化（参考既有 SpyStdinExecutor 模式），计数 dispatch + 可注入 PluginResult。
/// 用于断言 submitCommandDirect 是否真的 dispatch 到 StdinExecutor（command 短路，零 LLM）。
private final class SnipAutoCopySpyStdinExecutor: StdinExecutor {
    private(set) var executeCallCount = 0
    private(set) var capturedManifests: [PluginManifest] = []
    private(set) var capturedInputs: [PluginInput] = []
    var resultFactory: ((PluginManifest) -> PluginResult)?

    override func execute(_ plugin: PluginManifest, pluginDir: URL, input: PluginInput) async throws -> PluginResult {
        executeCallCount += 1
        capturedManifests.append(plugin)
        capturedInputs.append(input)
        if let factory = resultFactory {
            return factory(plugin)
        }
        return PluginResult(stdout: "spy ok", stderr: "", exitCode: 0,
                            durationMs: 0, stdoutTruncated: false, image: nil, candidates: nil)
    }
}
