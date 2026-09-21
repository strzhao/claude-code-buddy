import XCTest
@testable import BuddyCore

// MARK: - StdinExecutorCardOutputTests
//
// 蓝队单测：StdinExecutor 通用卡片通道（W3，BUDDY_OUTPUT_CARD）—— stdin + command mode 共享
//
// 契约引用（state.md ## 契约规约 + 边界值 + 错误契约 + 副作用清单）：
//   env["BUDDY_OUTPUT_CARD"] = "/tmp/buddy-plugin-<UUID>.card.json"
//   exit 0 后读文件 → JSON 解码 PluginCard → PluginResult.card
//   读前 resolvedPath == expectedPath 校验（防 symlink）+ count ≤ cardMaxBytes(262_144) + 解码
//   任何失败（超限/畸形/symlink/缺失）→ card = nil（降级，不报错，stdout 文本兜底不受影响）
//   finally 删临时文件（副作用清单）
//   解码侧：percent clamp [0,100] / entries>32 截断保留前 32（clamp/校验归属：框架侧防御）

final class StdinExecutorCardOutputTests: XCTestCase {

    private var tmpDir: URL!
    private let executor = StdinExecutor.shared

    override func setUp() {
        super.setUp()
        tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("StdinExecutorCard-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmpDir)
        super.tearDown()
    }

    // MARK: - 场景 1：子进程写合法 card JSON → result.card 非空且字段解码

    func test_cardChannel_childWritesValidJson_resultCardDecoded() async throws {
        let script = """
        #!/bin/bash
        cat > "$BUDDY_OUTPUT_CARD" <<'EOF'
        {"title":"gcli 套餐限额 · 2 个","entries":[
          {"name":"kimi","level":"ok","badge":"使用中",
           "windows":[{"label":"5h","percent":12,"reset":"3h20m"},
                      {"label":"周窗","percent":45,"reset":"2d4h"}]},
          {"name":"glm-4.6","level":"danger","badge":"",
           "windows":[{"label":"5h","percent":91,"reset":"1h05m"}]}]}
        EOF
        echo "text fallback"
        exit 0
        """
        let (result, _) = try await runScript(script, dirName: "card-ok")
        XCTAssertEqual(result.exitCode, 0)
        let card = try XCTUnwrap(result.card, "子进程写合法 card JSON 后 result.card 必须非空")
        XCTAssertEqual(card.title, "gcli 套餐限额 · 2 个")
        XCTAssertEqual(card.entries.count, 2)
        XCTAssertEqual(card.entries[0].name, "kimi")
        XCTAssertEqual(card.entries[0].level, "ok")
        XCTAssertEqual(card.entries[0].badge, "使用中")
        XCTAssertEqual(card.entries[0].windows.count, 2)
        XCTAssertEqual(card.entries[0].windows[0].label, "5h")
        XCTAssertEqual(card.entries[0].windows[0].percent, 12)
        XCTAssertEqual(card.entries[0].windows[0].reset, "3h20m")
        // stdout 兜底文本不受 card 通道影响（错误契约）
        XCTAssertTrue(result.stdout.contains("text fallback"), "stdout 恒有兜底文本")
    }

    // MARK: - 场景 2：子进程不写文件 → card = nil（不报错）

    func test_cardChannel_childDoesNotWriteFile_resultCardNil() async throws {
        let script = """
        #!/bin/bash
        echo "text only"
        exit 0
        """
        let (result, _) = try await runScript(script, dirName: "card-none")
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertNil(result.card, "子进程未写文件时 result.card 必须为 nil（降级非报错）")
        XCTAssertTrue(result.stdout.contains("text only"))
    }

    // MARK: - 场景 3：card 文件超限（> 262_144 bytes）→ nil（边界值反例）

    func test_cardChannel_oversizedCard_droppedToNil() async throws {
        // 写 300KB（> 262_144 上限）
        let script = """
        #!/bin/bash
        head -c 307200 /dev/zero > "$BUDDY_OUTPUT_CARD"
        exit 0
        """
        let (result, _) = try await runScript(script, dirName: "card-big")
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertNil(result.card, "card 文件 > cardMaxBytes(262_144) 必须丢弃为 nil")
    }

    // MARK: - 场景 4：畸形 JSON → nil（stdout 兜底不受影响，s7p1 变体 2）

    func test_cardChannel_malformedJson_droppedToNil_stdoutIntact() async throws {
        let script = """
        #!/bin/bash
        echo "not-json{{{" > "$BUDDY_OUTPUT_CARD"
        echo "fallback text here"
        exit 0
        """
        let (result, _) = try await runScript(script, dirName: "card-bad")
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertNil(result.card, "畸形 JSON 必须降级为 nil")
        XCTAssertTrue(result.stdout.contains("fallback text here"), "stdout 兜底文本不受影响")
    }

    // MARK: - 场景 5：resolvedPath 逃逸（symlink 篡改）→ nil（s7p1 变体 3）

    func test_cardChannel_symlinkEscape_droppedToNil() async throws {
        // 在注入路径上放 symlink 指向 /etc/hosts → resolvedPath != expectedPath → 丢弃
        let script = """
        #!/bin/bash
        ln -s /etc/hosts "$BUDDY_OUTPUT_CARD"
        exit 0
        """
        let (result, _) = try await runScript(script, dirName: "card-symlink")
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertNil(result.card, "symlink 篡改路径必须丢弃为 nil（/tmp 防御）")
    }

    // MARK: - 场景 6：执行完成后 card 临时文件已删除（副作用清单）

    func test_cardChannel_tempFileCleanedUpAfterExecution() async throws {
        let script = """
        #!/bin/bash
        printf '{"title":"t","entries":[]}' > "$BUDDY_OUTPUT_CARD"
        exit 0
        """
        _ = try await runScript(script, dirName: "card-cleanup")
        let tmpContents = (try? FileManager.default.contentsOfDirectory(atPath: "/tmp")) ?? []
        let leftover = tmpContents.filter { $0.hasPrefix("buddy-plugin-") && $0.hasSuffix(".card.json") }
        XCTAssertTrue(leftover.isEmpty, "card 临时文件必须被 finally 清理，残留: \(leftover)")
    }

    // MARK: - 场景 7：env 注入路径格式符合契约

    func test_cardChannel_envPathFormat() async throws {
        let script = """
        #!/bin/bash
        echo "CARD=$BUDDY_OUTPUT_CARD"
        exit 0
        """
        let (result, _) = try await runScript(script, dirName: "card-env")
        guard let range = result.stdout.range(of: "CARD=") else {
            return XCTFail("stdout 应含 CARD= 行: \(result.stdout)")
        }
        let path = String(result.stdout[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertTrue(path.hasPrefix("/tmp/buddy-plugin-"), "BUDDY_OUTPUT_CARD 必须以 /tmp/buddy-plugin- 开头，实际: \(path)")
        XCTAssertTrue(path.hasSuffix(".card.json"), "BUDDY_OUTPUT_CARD 必须以 .card.json 结尾，实际: \(path)")
    }

    // MARK: - 常量契约

    func test_cardMaxBytes_constant() {
        XCTAssertEqual(LauncherConstants.cardMaxBytes, 262_144,
                       "cardMaxBytes 必须为 262_144（256 KiB，契约边界值）")
    }

    // MARK: - 解码侧防御：percent clamp [0,100]（双侧防御的框架侧）

    func test_decode_percentClampedBothWays() throws {
        let json = #"{"title":"t","entries":[{"name":"a","windows":[{"label":"5h","percent":120}]}]}"#
        let card = try JSONDecoder().decode(PluginCard.self, from: Data(json.utf8))
        XCTAssertEqual(card.entries[0].windows[0].percent, 100, "percent=120 → clamp 100")

        let jsonNeg = #"{"title":"t","entries":[{"name":"a","windows":[{"label":"5h","percent":-5}]}]}"#
        let cardNeg = try JSONDecoder().decode(PluginCard.self, from: Data(jsonNeg.utf8))
        XCTAssertEqual(cardNeg.entries[0].windows[0].percent, 0, "percent=-5 → clamp 0")
    }

    // MARK: - 解码侧防御：entries > 32 截断保留前 32（不弃整卡，s7p4）

    func test_decode_entriesOver32_truncatedToFirst32() throws {
        let entries = (0..<40).map { #"{"name":"e\#($0)","windows":[]}"# }.joined(separator: ",")
        let json = #"{"title":"t","entries":[\#(entries)]}"#
        let card = try JSONDecoder().decode(PluginCard.self, from: Data(json.utf8))
        XCTAssertEqual(card.entries.count, 32, "entries>32 解码侧截断保留前 32")
        XCTAssertEqual(card.entries.first?.name, "e0", "保留前 32（保序）")
        XCTAssertEqual(card.entries.last?.name, "e31")
    }

    // MARK: - 必填字段缺失 → 整卡 nil（对称 candidates 通道降级）

    func test_decode_missingRequiredField_throws() {
        // windows[].percent 必填：缺失 → 解码抛错 → readCardOutputSafely 得 nil
        let json = #"{"title":"t","entries":[{"name":"a","windows":[{"label":"5h"}]}]}"#
        XCTAssertThrowsError(try JSONDecoder().decode(PluginCard.self, from: Data(json.utf8)),
                             "percent 缺失必须抛 decodingError（→ 卡片降级 nil）")
    }

    // MARK: - AgentEvent.card == 分支（C3 纪律）

    func test_agentEventCard_equatable() {
        let a = PluginCard(title: "t", entries: [CardEntry(name: "x")])
        let b = PluginCard(title: "t", entries: [CardEntry(name: "x")])
        let c = PluginCard(title: "t", entries: [CardEntry(name: "y")])
        XCTAssertEqual(AgentEvent.card(a), AgentEvent.card(b), "同内容 card 事件必须相等")
        XCTAssertNotEqual(AgentEvent.card(a), AgentEvent.card(c), "不同内容 card 事件必须不等")
        XCTAssertNotEqual(AgentEvent.card(a), AgentEvent.text("t"), "不同 case 不等")
    }

    // MARK: - Helpers（镜像 StdinExecutorImageOutputTests）

    @discardableResult
    private func runScript(_ script: String, dirName: String) async throws -> (PluginResult, URL) {
        let pluginDir = try makeScriptPlugin(dirName: dirName, manifestName: dirName, script: script)
        let manifest = try loadManifest(from: pluginDir, dirName: dirName)
        let input = PluginInput(query: "x", sessionId: UUID().uuidString, cwd: "/tmp")
        let result = try await executor.execute(manifest, pluginDir: pluginDir, input: input)
        return (result, pluginDir)
    }

    private func makeScriptPlugin(
        dirName: String,
        manifestName: String,
        script: String,
        timeout: Int = 10
    ) throws -> URL {
        let pluginDir = tmpDir.appendingPathComponent(dirName)
        try FileManager.default.createDirectory(at: pluginDir, withIntermediateDirectories: true)

        let scriptURL = pluginDir.appendingPathComponent("run.sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        let manifestJSON = """
        {
          "name": "\(manifestName)",
          "version": "0.1.0",
          "description": "test",
          "keywords": [],
          "cmd": "./run.sh",
          "args": [],
          "env": null,
          "timeout": \(timeout),
          "requiredPath": null
        }
        """
        try manifestJSON.write(to: pluginDir.appendingPathComponent("plugin.json"),
                               atomically: true, encoding: .utf8)
        return pluginDir
    }

    private func loadManifest(from pluginDir: URL, dirName: String) throws -> PluginManifest {
        let data = try Data(contentsOf: pluginDir.appendingPathComponent("plugin.json"))
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: data)
        try manifest.validate(againstDirName: dirName)
        return manifest
    }
}
