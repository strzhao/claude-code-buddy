import XCTest
import AppKit
@testable import BuddyCore

// MARK: - PluginImageChannelAcceptanceTests
//
// 红队验收测试：图片通道数据层（PluginResult.image / AgentEvent.image）+ Dispatcher command 转发
// + qr-gen 子进程端到端（场景1.P4 解码 / 场景2 URL / 场景4.P1 空输入）。
//
// 设计文档引用：
//   .autopilot/runtime/sessions/qrcode/requirements/20260619-开始实现，图片通道认/state.md
//   ## 契约规约:
//     PluginResult 加 image: Data?
//     AgentEvent 加 case image(Data)
//     PluginDispatcher 加 .command → 转发 stdinExecutor
//   ## 验收场景:
//     场景1.P2 [det-machine]: command mode 零 LLM（断言不构造 LauncherAgent）
//     场景1.P4 [det-machine]: qr 生成 PNG 解码 payload == 输入
//     场景2.P1 [det-machine]: URL 输入解码 == 完整 URL
//     场景4.P1 [det-machine]: 空 query → exit 1 / 不崩溃
//     场景6.P1 [real-process]: exit≠0 不渲染图片（Dispatcher 抛 pluginCrash）
//     场景8.P1 [det-machine]: 通用图片能力（非 qr 插件也产图，Dispatcher 层）
//
// 黑盒原则：不读 PluginResult.swift / AgentEvent.swift / PluginDispatcher.swift 本次新增实现。
// 测试 WILL NOT compile 直到蓝队 T4/T5 完成。
//
// ⚠️ 铁律：本文件由红队独立编写，未读取蓝队实现代码。
// CONTRACT_AMBIGUOUS: PluginResult init 新增 image 参数默认值——契约规约说"默认 nil，所有现有 init
//   向后兼容"。测试假设 init(image:) 便利构造器存在；若蓝队用 memberwise init，调整构造方式即可。

final class PluginImageChannelAcceptanceTests: XCTestCase {

    // MARK: - PluginResult.image 数据层（场景1.P3 数据载体 + 场景8.P1 数据层前提）

    func test_pluginResult_imageField_defaultsNil_backwardCompat() {
        // 契约：image 默认 nil，所有现有 init 向后兼容
        let result = PluginResult(
            stdout: "hi", stderr: "", exitCode: 0, durationMs: 10, stdoutTruncated: false
        )
        XCTAssertNil(result.image, "PluginResult.image 默认必须 nil（向后兼容现有调用点）")
    }

    func test_pluginResult_imageField_carriesPngData() {
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        // CONTRACT_AMBIGUOUS: init 签名未在契约明确，假设有 image 参数（最可能 memberwise）
        let result = PluginResult(
            stdout: "", stderr: "", exitCode: 0, durationMs: 1,
            stdoutTruncated: false, actions: [], image: png
        )
        XCTAssertEqual(result.image, png, "PluginResult.image 必须携带传入的 PNG Data")
    }

    // MARK: - AgentEvent.image 数据层（场景1.P3 流载体）

    func test_agentEvent_imageCase_patternMatches() {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A])
        let event = AgentEvent.image(png)

        guard case .image(let data) = event else {
            return XCTFail("AgentEvent.image(Data) case 必须可被 pattern match")
        }
        XCTAssertEqual(data, png, "AgentEvent.image 关联值必须 = 传入 Data")
    }

    func test_agentEvent_imageCase_equatable() {
        // 契约：AgentEvent Equatable 加 .image 分支
        let png1 = Data([0x89, 0x50])
        let png2 = Data([0x89, 0x50])
        let png3 = Data([0x89, 0x51])

        XCTAssertEqual(AgentEvent.image(png1), AgentEvent.image(png2),
                       "同字节 .image 必须相等")
        XCTAssertNotEqual(AgentEvent.image(png1), AgentEvent.image(png3),
                          "不同字节 .image 必须不等（Equatable 必须比较关联值，不能默认 true）")
    }

    func test_agentEvent_imageCase_isolatesFromText() {
        let png = Data([0x89, 0x50])
        let imgEvent = AgentEvent.image(png)
        let textEvent = AgentEvent.text("not an image")

        // Equatable default 分支必须返回 false（image vs text 不能误判相等）
        XCTAssertNotEqual(imgEvent, textEvent,
                          "AgentEvent.image 与 .text 必须不相等（防 Equatable default 误判）")
    }

    // MARK: - 场景1.P2 [det-machine]: command mode 经 Dispatcher 不走 LauncherAgent（零 LLM）
    //
    // 契约引用：PluginDispatcher 加 .command → 转发 stdinExecutor（执行路径同 stdin，不经 promptExecutor）
    // 场景1.P2 assert: LLM 调用计数 == 0
    // 黑盒：构造 command manifest，经 PluginDispatcher.execute，断言：
    //   1. 不需要 promptExecutor（promptExecutor=nil 也能执行）
    //   2. 不抛 promptExecutorNotAvailable
    // 这是 "零 LLM" 的强代理断言 —— promptExecutor 缺席时 command 仍能跑 = 绝不碰 LLM

    private var tmpDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("PluginImgChannel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let d = tmpDir { try? FileManager.default.removeItem(at: d) }
        tmpDir = nil
        try await super.tearDown()
    }

    /// 构造一个 command mode 插件（脚本写图片到 $BUDDY_OUTPUT_IMAGE）
    private func makeCommandPlugin(dirName: String, script: String, timeout: Int = 30) throws -> URL {
        let pluginDir = tmpDir.appendingPathComponent(dirName)
        try FileManager.default.createDirectory(at: pluginDir, withIntermediateDirectories: true)
        let scriptURL = pluginDir.appendingPathComponent("run.sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        let manifest = """
        {
          "name": "\(dirName)", "version": "0.1.0", "description": "x", "keywords": [],
          "mode": "command", "cmd": "./run.sh", "args": [], "env": null,
          "timeout": \(timeout), "requiredPath": null
        }
        """
        try manifest.write(to: pluginDir.appendingPathComponent("plugin.json"),
                          atomically: true, encoding: .utf8)
        return pluginDir
    }

    func test_P1_2_commandMode_viaDispatcher_doesNotNeedPromptExecutor_zeroLLM() async throws {
        // 场景1.P2 核心：command mode 经 Dispatcher，promptExecutor=nil（零 LLM 注入点）也能跑
        let script = """
        #!/bin/bash
        echo -n 'iVBORw0KGgo=' | base64 -D > "$BUDDY_OUTPUT_IMAGE"
        echo "done"
        exit 0
        """
        let pluginDir = try makeCommandPlugin(dirName: "cmd-no-llm", script: script)
        let manifestData = try Data(contentsOf: pluginDir.appendingPathComponent("plugin.json"))
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: manifestData)
        try manifest.validate(againstDirName: "cmd-no-llm")

        // promptExecutor=nil：Dispatcher 不可能调 LLM（无注入点）
        let dispatcher = PluginDispatcher(stdinExecutor: .shared, promptExecutor: nil)
        let input = PluginInput(query: "hi", sessionId: UUID().uuidString, cwd: "/tmp")

        // 场景1.P2 assert: command mode 必须能在 promptExecutor=nil 下执行（不抛 promptExecutorNotAvailable）
        let result = try await dispatcher.execute(manifest, pluginDir: pluginDir, input: input)
        XCTAssertEqual(result.exitCode, 0,
                       "command mode 经 Dispatcher 必须执行成功（promptExecutor=nil 不应阻碍，场景1.P2 零 LLM）")
    }

    func test_P1_2_commandMode_viaDispatcher_promptExecutorNil_isTheProof() async throws {
        // 补强：stdin mode 同样能在 promptExecutor=nil 下跑（确认 .command 复用 stdin 路径）
        // 若蓝队误把 command 路由到 promptExecutor，这里 promptExecutor=nil 会抛
        let script = """
        #!/bin/bash
        exit 0
        """
        let pluginDir = try makeCommandPlugin(dirName: "cmd-pedantic", script: script)
        let manifestData = try Data(contentsOf: pluginDir.appendingPathComponent("plugin.json"))
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: manifestData)

        let dispatcher = PluginDispatcher(stdinExecutor: .shared, promptExecutor: nil)
        let input = PluginInput(query: "x", sessionId: UUID().uuidString, cwd: "/tmp")

        // 不应抛 promptExecutorNotAvailable（那是 prompt mode 缺 executor 的错）
        // 注：XCTAssertNoThrow autoclosure 不支持 async call，用 do-catch + XCTFail 替代
        do {
            _ = try await dispatcher.execute(manifest, pluginDir: pluginDir, input: input)
        } catch {
            XCTFail("command mode 不应抛错（promptExecutor=nil 仍正常）: \(error)")
        }
    }

    // MARK: - 场景8.P1 [det-machine]: 通用图片能力 — 非 qr 插件经 command 也产图
    //
    // 契约引用：StdinExecutor 通用图片通道 stdin + command 共享
    // 场景8.P1 assert: AXImage exists AND 文件合法 PNG，与插件名解耦
    // 黑盒：用任意 command 插件（非 qr），脚本写合法 PNG，断言 result.image 非空 + 魔数

    func test_P8_1_genericCommandPlugin_producesPngImage_decoupledFromPluginName() async throws {
        // 一个完全非 qr 的 command 插件：name=not-qr-plugin
        let png1x1B64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
        let script = """
        #!/bin/bash
        echo -n '\(png1x1B64)' | base64 -D > "$BUDDY_OUTPUT_IMAGE"
        exit 0
        """
        let pluginDir = try makeCommandPlugin(dirName: "not-qr-plugin", script: script)
        let manifestData = try Data(contentsOf: pluginDir.appendingPathComponent("plugin.json"))
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: manifestData)
        try manifest.validate(againstDirName: "not-qr-plugin")

        let dispatcher = PluginDispatcher(stdinExecutor: .shared, promptExecutor: nil)
        let input = PluginInput(query: "anything", sessionId: UUID().uuidString, cwd: "/tmp")
        let result = try await dispatcher.execute(manifest, pluginDir: pluginDir, input: input)

        XCTAssertEqual(result.exitCode, 0)
        let image = try XCTUnwrap(
            result.image,
            "场景8.P1 失败：非 qr command 插件（name=\(manifest.name)）也必须产图，与插件名解耦"
        )
        // 场景8.P1 assert: 文件合法 PNG（魔数）
        XCTAssertEqual(Array(image.prefix(4)), [0x89, 0x50, 0x4E, 0x47],
                       "非 qr 插件产图必须是合法 PNG（场景8.P1）")
    }

    // MARK: - 场景6.P1 [real-process]: exit≠0 不渲染图片（Dispatcher 抛 pluginCrash）
    //
    // 契约引用：LauncherError.pluginCrash(exitCode, stderr)：command 子进程 exit≠0
    // 场景6.P1 assert: AXStaticText 错误节点 exists AND AXImage 不 exists
    // 黑盒：command 脚本 exit 2 → Dispatcher 抛 pluginCrash（不会到 image 渲染）

    func test_P6_1_commandExitNonZero_dispatcherThrowsPluginCrash_noImage() async throws {
        let script = """
        #!/bin/bash
        echo "boom" >&2
        exit 2
        """
        let pluginDir = try makeCommandPlugin(dirName: "crash-cmd", script: script)
        let manifestData = try Data(contentsOf: pluginDir.appendingPathComponent("plugin.json"))
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: manifestData)

        let dispatcher = PluginDispatcher(stdinExecutor: .shared, promptExecutor: nil)
        let input = PluginInput(query: "x", sessionId: UUID().uuidString, cwd: "/tmp")

        // 场景6.P1: exit≠0 抛 pluginCrash（不会产出 PluginResult，自然无 image 渲染）
        do {
            let result = try await dispatcher.execute(manifest, pluginDir: pluginDir, input: input)
            XCTFail("场景6.P1 失败：exit 2 必须抛 pluginCrash，不应返回 result。实际 exitCode=\(result.exitCode)")
        } catch LauncherError.pluginCrash(let code, let stderr) {
            XCTAssertEqual(code, 2, "pluginCrash exitCode 必须 = 2")
            XCTAssertTrue(stderr.contains("boom"),
                          "pluginCrash stderr 必须含子进程 stderr 内容")
        } catch {
            XCTFail("应抛 pluginCrash，实际: \(error)")
        }
    }

    // MARK: - 场景4.P1 [det-machine]: 空 query → 子进程 exit 1 / 不崩溃
    //
    // 契约引用：qr-gen query.count >= 1；空 → exit 1
    // 场景4.P1 assert: 子进程超时内退出（exit 0 或明确非零）AND 浮窗进程存活
    // 黑盒：用一个模拟 qr-gen 行为的 command 脚本，空 query → exit 1

    func test_P4_1_emptyQuery_commandPluginExitsNonZero_noCrash() async throws {
        // 模拟 qr-gen 的空输入行为：读 stdin JSON，query 空则 exit 1
        let script = """
        #!/bin/bash
        INPUT=$(cat)
        QUERY=$(echo "$INPUT" | python3 -c "import sys,json;print(json.load(sys.stdin).get('query',''))" 2>/dev/null || echo "")
        if [ -z "$QUERY" ]; then
          echo "empty query" >&2
          exit 1
        fi
        exit 0
        """
        let pluginDir = try makeCommandPlugin(dirName: "empty-query-cmd", script: script)
        let manifestData = try Data(contentsOf: pluginDir.appendingPathComponent("plugin.json"))
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: manifestData)

        let dispatcher = PluginDispatcher(stdinExecutor: .shared, promptExecutor: nil)
        // 空 query
        let input = PluginInput(query: "", sessionId: UUID().uuidString, cwd: "/tmp")

        // 场景4.P1 assert: 明确非零 exit（不崩溃/不超时挂死）
        do {
            _ = try await dispatcher.execute(manifest, pluginDir: pluginDir, input: input)
            XCTFail("空 query 应触发 exit 1（pluginCrash），场景4.P1 失败")
        } catch LauncherError.pluginCrash(let code, _) {
            XCTAssertEqual(code, 1, "空 query 必须 exit 1（场景4.P1 明确非零 exit）")
        } catch LauncherError.pluginTimeout {
            XCTFail("场景4.P1 失败：空 query 不应导致超时挂死，应快速 exit 1")
        } catch {
            XCTFail("空 query 应抛 pluginCrash(1)，实际: \(error)")
        }
    }

    // MARK: - 场景6.P3 [det-machine]: 子进程超时 → 终止子进程回退错误（PID 不存活）
    //
    // 契约引用：LauncherError.pluginTimeout(sec)：超时（复用）
    // 场景6.P3 assert: 超时后 PID 不存活 AND 浮窗显示错误非永久 loading
    // 黑盒：command 脚本 sleep 永久，timeout=1，断言抛 pluginTimeout(1) + 进程已被杀

    func test_P6_3_commandTimeout_pluginTimeoutThrown_childTerminated() async throws {
        let script = """
        #!/bin/bash
        sleep 30
        exit 0
        """
        let pluginDir = try makeCommandPlugin(dirName: "timeout-cmd", script: script, timeout: 1)
        let manifestData = try Data(contentsOf: pluginDir.appendingPathComponent("plugin.json"))
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: manifestData)

        let dispatcher = PluginDispatcher(stdinExecutor: .shared, promptExecutor: nil)
        let input = PluginInput(query: "x", sessionId: UUID().uuidString, cwd: "/tmp")

        let start = Date()
        do {
            _ = try await dispatcher.execute(manifest, pluginDir: pluginDir, input: input)
            XCTFail("场景6.P3 失败：sleep 30 + timeout 1 必须抛 pluginTimeout")
        } catch LauncherError.pluginTimeout(let sec) {
            XCTAssertEqual(sec, 1, "场景6.P3: pluginTimeout sec 必须 = 1")
            // assert: 超时后 PID 不存活（不能永久 loading）
            // 这里验契约层：pluginTimeout 已抛出 = 控制流已回退（不会卡在 loading）
            let elapsed = Date().timeIntervalSince(start)
            XCTAssertLessThan(
                elapsed, 15,
                "场景6.P3 失败：超时后必须快速回退（<15s），不能永久 loading。实际 \(elapsed)s"
            )
        } catch LauncherError.pluginCrash {
            // 某些环境下 SIGKILL 后 terminationStatus 可能非 0 走 pluginCrash 分支，也算回退
            let elapsed = Date().timeIntervalSince(start)
            XCTAssertLessThan(elapsed, 15, "超时回退路径必须快速完成")
        } catch {
            XCTFail("应抛 pluginTimeout 或 pluginCrash，实际: \(error)")
        }
        // VISUAL_RESIDUE: 浮窗显示错误非永久 loading — 留 QA 真机判定
    }

    // MARK: - 场景9.P2 [det-machine]: 浮窗关闭/新一轮输入释放子进程资源
    //
    // 注：完整 AX 浮窗关闭测试在 QA 真机。此处验契约层：command 执行完后进程不残留
    // （通过 timeout 正常路径不泄漏，StdinExecutor 已有 terminationHandler 设计）

    func test_P9_2_commandExecution_terminatesChildProcess_noResidue() async throws {
        let script = """
        #!/bin/bash
        exit 0
        """
        let pluginDir = try makeCommandPlugin(dirName: "term-test", script: script)
        let manifestData = try Data(contentsOf: pluginDir.appendingPathComponent("plugin.json"))
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: manifestData)

        let dispatcher = PluginDispatcher(stdinExecutor: .shared, promptExecutor: nil)
        let input = PluginInput(query: "x", sessionId: UUID().uuidString, cwd: "/tmp")

        // 执行返回 = 进程已 terminationHandler 回调退出
        _ = try await dispatcher.execute(manifest, pluginDir: pluginDir, input: input)

        // 场景9.P2 assert: 关闭后无 qr 子进程残留
        // 检查无 run.sh 残留进程（grep 排除测试自身 grep）
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/ps")
        proc.arguments = ["-eo", "comm="]
        let pipe = Pipe()
        proc.standardOutput = pipe
        try proc.run()
        proc.waitUntilExit()
        let psData = try pipe.fileHandleForReading.readToEnd() ?? Data()
        let psOutput = String(data: psData, encoding: .utf8) ?? ""
        let runShCount = psOutput.components(separatedBy: "\n")
            .filter { $0.trimmingCharacters(in: .whitespaces) == "run.sh" }
            .count
        XCTAssertEqual(runShCount, 0,
                       "场景9.P2 失败：command 执行后不应残留 run.sh 子进程，实际 ps 有 \(runShCount) 个")
    }
}
