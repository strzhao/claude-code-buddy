import XCTest
@testable import BuddyCore

// MARK: - StdinExecutorCardChannelAcceptanceTests
//
// 红队验收测试（TDD 红灯）：W3 BUDDY_OUTPUT_CARD 卡片通道（镜像 StdinExecutorImageOutputAcceptanceTests 先例）
//
// 谓词映射（SSOT: state.md ## 验收场景）：
//   s7p1 [real-process] readCardOutputSafely 三变体：超限(>262_144 bytes)/畸形 JSON/resolvedPath 逃逸
//        → 均得 nil 且不影响 stdout 兜底文本路径 ｜ artifact: /tmp/autopilot-artifacts/s7p1.out
//   s7p4 [real-process] entries>32 fixture → Swift 解码侧截断保留前 32 且不弃整卡
//        ｜ artifact: /tmp/autopilot-artifacts/s7p4.out
//
// 契约逐字一致（## 契约规约 / ## 数据结构）：
//   LauncherConstants.cardMaxBytes == 262_144（W3 #1）
//   StdinExecutor 注入 env BUDDY_OUTPUT_CARD=<tmp>/buddy-plugin-<uuid>.card.json
//   超限/解码失败/resolvedPath 逃逸 → card=nil；finally 删临时文件
//   entries > 32 → 截断保留前 32（防御性降级，不弃整卡）
//   percent clamp：Swift PluginCard 解码侧再 clamp（percent 120→100 / -5→0）
//   card JSON schema：{"title","entries":[{name,level,badge,windows:[{label,percent,reset}]}]}
//
// 黑盒策略：真实 Process 跑 shell/python 脚本，脚本向 $BUDDY_OUTPUT_CARD 写文件；
// 不 mock StdinExecutor 内部，验完整 env 注入 → 子进程写 → 框架安全读 → PluginResult.card 流。
// result.card / LauncherConstants.cardMaxBytes 未实现时编译失败＝预期 TDD 红灯。
// 注：s7p1 的「readCardOutputSafely 单测」按其 observe（测试进程 exit==0 失败数 0）以
// StdinExecutor 全链路黑盒等价驱动——方法本身为实现内部名，黑盒注入点 = 契约声明的 env 键。

final class StdinExecutorCardChannelAcceptanceTests: XCTestCase {

    private var tmpDir: URL!
    private let executor = StdinExecutor.shared

    override func setUp() async throws {
        try await super.setUp()
        tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("StdinCardAcceptance-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let dir = tmpDir { try? FileManager.default.removeItem(at: dir) }
        tmpDir = nil
        try await super.tearDown()
    }

    // MARK: - helpers

    private func writeArtifact(_ name: String, _ lines: [String]) {
        let dir = "/tmp/autopilot-artifacts"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let content = ([name] + lines).joined(separator: "\n") + "\n"
        try? content.write(toFile: dir + "/" + name, atomically: true, encoding: .utf8)
    }

    /// 设计 ## 数据结构 card JSON（示例逐字：kimi ok 12%/45% + 第二条目）
    private func designCardJSON(entries: [[String: Any]]? = nil, title: String? = nil) -> String {
        let body: [String: Any] = [
            "title": title ?? "gcli 套餐限额 · 2 个",
            "entries": entries ?? [
                ["name": "kimi", "level": "ok", "badge": "使用中", "windows": [
                    ["label": "5h", "percent": 12, "reset": "3h20m"],
                    ["label": "周窗", "percent": 45, "reset": "2d4h"],
                ]],
                ["name": "glm", "level": "warn", "badge": "", "windows": [
                    ["label": "5h", "percent": 66, "reset": "1h5m"],
                ]],
            ]
        ]
        let data = try! JSONSerialization.data(withJSONObject: body)
        return String(data: data, encoding: .utf8)!
    }

    /// 生成 stdin mode 插件：scriptBody 里可用 $BUDDY_OUTPUT_CARD（框架注入）
    private func makeStdinPlugin(dirName: String, scriptBody: String, timeout: Int = 30) throws -> (URL, PluginManifest) {
        let pluginDir = tmpDir.appendingPathComponent(dirName)
        try FileManager.default.createDirectory(at: pluginDir, withIntermediateDirectories: true)
        let script = "#!/bin/bash\n\(scriptBody)\nexit 0\n"
        let scriptURL = pluginDir.appendingPathComponent("run.sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        let manifestJSON = """
        { "name": "\(dirName)", "version": "0.1.0", "description": "card channel test",
          "keywords": [], "mode": "stdin", "cmd": "./run.sh", "args": [], "env": null,
          "timeout": \(timeout), "requiredPath": null }
        """
        try manifestJSON.write(to: pluginDir.appendingPathComponent("plugin.json"),
                               atomically: true, encoding: .utf8)
        let manifest = try JSONDecoder().decode(PluginManifest.self,
                                                from: Data(contentsOf: pluginDir.appendingPathComponent("plugin.json")))
        return (pluginDir, manifest)
    }

    private func execute(_ manifest: PluginManifest, pluginDir: URL, query: String) async throws -> PluginResult {
        try await executor.execute(manifest, pluginDir: pluginDir,
                                   input: PluginInput(query: query, sessionId: UUID().uuidString, cwd: "/tmp"))
    }

    private func countCardTempFiles() throws -> Int {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: "/tmp")) ?? []
        return files.filter { $0.hasPrefix("buddy-plugin-") && $0.hasSuffix(".card.json") }.count
    }

    // MARK: - 契约常量：cardMaxBytes == 262_144（W3 #1，防写错常量值）

    func test_contract_cardMaxBytes_equals262144() {
        XCTAssertEqual(LauncherConstants.cardMaxBytes, 262_144,
            "契约：LauncherConstants.cardMaxBytes 必须 == 262_144，实际 \(LauncherConstants.cardMaxBytes)")
    }

    // MARK: - env 注入契约：BUDDY_OUTPUT_CARD 键 + 路径格式

    /// 契约：env 键 BUDDY_OUTPUT_CARD，值 <tmp>/buddy-plugin-<uuid>.card.json
    func test_envContainsBuddyOutputCardKey_pathFormat() async throws {
        let (pluginDir, manifest) = try makeStdinPlugin(dirName: "card-env-printer", scriptBody: """
            echo "CARD=${BUDDY_OUTPUT_CARD:-MISSING}"
            """)
        let result = try await execute(manifest, pluginDir: pluginDir, query: "x")

        let line = result.stdout.split(separator: "\n").first { $0.hasPrefix("CARD=") }
        let value = try XCTUnwrap(line, "子进程必须读到 CARD= 行。实际 stdout: \(result.stdout)")
        let path = String(value.dropFirst("CARD=".count))
        XCTAssertFalse(path.contains("MISSING"), "BUDDY_OUTPUT_CARD 必须被注入（不能 MISSING）")
        XCTAssertTrue(path.hasPrefix("/tmp/buddy-plugin-"),
                      "card 路径必须 hasPrefix '/tmp/buddy-plugin-'，实际: \(path)")
        XCTAssertTrue(path.hasSuffix(".card.json"),
                      "card 路径必须 hasSuffix '.card.json'，实际: \(path)")
    }

    // MARK: - 正向控制组（kill No-op）：合法 card → PluginResult.card 解码成功

    /// 无此正向用例则「通道整体 no-op（永远 nil）」的 mutation 不可杀死。
    func test_validCard_decodedIntoResult_withDesignSchema() async throws {
        let (pluginDir, manifest) = try makeStdinPlugin(dirName: "card-valid", scriptBody: """
            cat > "$BUDDY_OUTPUT_CARD" <<'CARD_EOF'
            \(designCardJSON())
            CARD_EOF
            echo "gcli 套餐限额（兜底文本）"
            """)
        let result = try await execute(manifest, pluginDir: pluginDir, query: "x")
        XCTAssertEqual(result.exitCode, 0)

        let card = try XCTUnwrap(result.card, "合法 card JSON 必须解码进 PluginResult.card")
        XCTAssertEqual(card.entries.count, 2, "示例 card 应有 2 条目")
        XCTAssertEqual(card.entries.first?.name, "kimi")
        XCTAssertEqual(card.entries.first?.windows.first?.percent, 12, "kimi 5h 窗 percent == 12（设计示例逐字）")
        XCTAssertEqual(card.entries.first?.windows.count, 2, "kimi 双窗")
    }

    // MARK: - s7p1 三变体：超限 / 畸形 JSON / resolvedPath 逃逸 → 均 nil ∧ stdout 兜底不受影响

    func test_s7p1_threeVariants_allNil_stdoutFallbackIntact() async throws {
        let marker = "S7P1_FALLBACK_MARKER"
        var evidence: [String] = ["cardMaxBytes=\(LauncherConstants.cardMaxBytes)"]

        // 变体 1：超限 —— 262_145 bytes（> cardMaxBytes，设计边界值逐字）→ nil
        let overBytes = LauncherConstants.cardMaxBytes + 1
        let (dir1, m1) = try makeStdinPlugin(dirName: "card-oversize", scriptBody: """
            head -c \(overBytes) /dev/zero > "$BUDDY_OUTPUT_CARD"
            echo "\(marker)"
            """)
        let r1 = try await execute(m1, pluginDir: dir1, query: "x")
        evidence.append("variant=oversize bytes=\(overBytes) card=\(r1.card == nil ? "nil" : "non-nil") stdoutHasMarker=\(r1.stdout.contains(marker))")
        XCTAssertNil(r1.card, "s7p1 变体1：card 文件 \(overBytes) bytes（>262_144）必须降级 nil")
        XCTAssertTrue(r1.stdout.contains(marker), "s7p1 变体1：stdout 兜底文本路径必须不受影响")

        // 变体 2：畸形 JSON → nil
        let (dir2, m2) = try makeStdinPlugin(dirName: "card-malformed", scriptBody: """
            printf 'not-json{{{' > "$BUDDY_OUTPUT_CARD"
            echo "\(marker)"
            """)
        let r2 = try await execute(m2, pluginDir: dir2, query: "x")
        evidence.append("variant=malformed card=\(r2.card == nil ? "nil" : "non-nil") stdoutHasMarker=\(r2.stdout.contains(marker))")
        XCTAssertNil(r2.card, "s7p1 变体2：畸形 JSON 必须降级 nil")
        XCTAssertTrue(r2.stdout.contains(marker), "s7p1 变体2：stdout 兜底文本路径必须不受影响")

        // 变体 3：resolvedPath 逃逸 —— 注入路径被换成指向「合法 card JSON」的 symlink；
        // 目标必须是合法 card：若框架不校验 resolvedPath 而直接读，会解码成功 → 断言可区分逃逸拒绝与解码失败
        let outsideCard = tmpDir.appendingPathComponent("outside-valid.card.json")
        try designCardJSON().write(to: outsideCard, atomically: true, encoding: .utf8)
        let (dir3, m3) = try makeStdinPlugin(dirName: "card-symlink", scriptBody: """
            rm -f "$BUDDY_OUTPUT_CARD"
            ln -s '\(outsideCard.path)' "$BUDDY_OUTPUT_CARD"
            echo "\(marker)"
            """)
        let r3 = try await execute(m3, pluginDir: dir3, query: "x")
        evidence.append("variant=symlink-escape card=\(r3.card == nil ? "nil" : "non-nil") stdoutHasMarker=\(r3.stdout.contains(marker))")
        XCTAssertNil(r3.card, "s7p1 变体3：resolvedPath 逃逸（symlink 指向合法 card）必须拒绝 → nil")
        XCTAssertTrue(r3.stdout.contains(marker), "s7p1 变体3：stdout 兜底文本路径必须不受影响")

        evidence.append("PASS")
        writeArtifact("s7p1.out", evidence)
    }

    // MARK: - 边界补集：恰好 == cardMaxBytes（≤ 上限）必须仍被接受（防 >= 误写）

    func test_exactMaxBytes_stillAccepted() async throws {
        // 合法 card JSON 用空白 padding 补齐到恰好 cardMaxBytes bytes
        let (pluginDir, manifest) = try makeStdinPlugin(dirName: "card-exact-max", scriptBody: """
            /usr/bin/python3 - "$BUDDY_OUTPUT_CARD" <<'PY_EOF'
            import json, sys
            card = {"title": "gcli 套餐限额 · 1 个", "entries": [
                {"name": "kimi", "level": "ok", "badge": "", "windows": [
                    {"label": "5h", "percent": 12, "reset": "3h20m"}]}]}
            raw = json.dumps(card, ensure_ascii=False).encode("utf-8")
            pad = \(LauncherConstants.cardMaxBytes) - len(raw)
            assert pad >= 0, "fixture 本身超限"
            with open(sys.argv[1], "wb") as f:
                f.write(raw + b" " * pad)
            PY_EOF
            echo done
            """)
        let result = try await execute(manifest, pluginDir: pluginDir, query: "x")
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertNotNil(result.card,
            "恰好 == cardMaxBytes（\(LauncherConstants.cardMaxBytes)）的 card 必须被接受（超限指 > 上限）")
    }

    // MARK: - s7p4：entries>32 → 截断保留前 32 且不弃整卡

    func test_s7p4_over32Entries_truncatedToFirst32_cardKept() async throws {
        // 40 条目 fixture（每条目 1 窗）
        var entries: [[String: Any]] = []
        for i in 0..<40 {
            entries.append(["name": "entry-\(i)", "level": "ok", "badge": "", "windows": [
                ["label": "5h", "percent": i, "reset": ""],
            ]])
        }
        let (pluginDir, manifest) = try makeStdinPlugin(dirName: "card-over32", scriptBody: """
            cat > "$BUDDY_OUTPUT_CARD" <<'CARD_EOF'
            \(designCardJSON(entries: entries, title: "gcli 套餐限额 · 40 个"))
            CARD_EOF
            echo "fallback"
            """)
        let result = try await execute(manifest, pluginDir: pluginDir, query: "x")
        XCTAssertEqual(result.exitCode, 0)

        let card = try XCTUnwrap(result.card, "s7p4：entries>32 必须截断而非弃整卡（card 不得为 nil）")
        XCTAssertEqual(card.entries.count, 32,
            "s7p4：40 条目必须截断保留前 32，实际 \(card.entries.count)")
        XCTAssertEqual(card.entries.first?.name, "entry-0", "截断必须保留前 32（首条目在）")
        XCTAssertEqual(card.entries.last?.name, "entry-31", "截断边界：第 32 条目保留、entry-32 起丢弃")

        writeArtifact("s7p4.out", [
            "fixture entries=40",
            "decoded entries=\(card.entries.count) (expect 32)",
            "first=\(card.entries.first?.name ?? "<nil>") last=\(card.entries.last?.name ?? "<nil>")",
            "cardNotNil=true stdoutFallback=\(result.stdout.contains("fallback"))",
            "PASS",
        ])
    }

    // MARK: - 契约（clamp/校验归属）：Swift 解码侧 percent 再 clamp 120→100 / -5→0

    func test_swiftDecodeSide_percentClamped() async throws {
        let entries: [[String: Any]] = [
            ["name": "over", "level": "danger", "badge": "", "windows": [
                ["label": "5h", "percent": 120, "reset": ""],
            ]],
            ["name": "under", "level": "ok", "badge": "", "windows": [
                ["label": "5h", "percent": -5, "reset": ""],
            ]],
        ]
        let (pluginDir, manifest) = try makeStdinPlugin(dirName: "card-clamp", scriptBody: """
            cat > "$BUDDY_OUTPUT_CARD" <<'CARD_EOF'
            \(designCardJSON(entries: entries, title: "clamp fixture"))
            CARD_EOF
            echo done
            """)
        let result = try await execute(manifest, pluginDir: pluginDir, query: "x")
        let card = try XCTUnwrap(result.card, "clamp fixture 必须解码成功")
        XCTAssertEqual(card.entries[0].windows[0].percent, 100,
            "契约：解码侧 percent 120 必须 clamp 到 100，实际 \(card.entries[0].windows[0].percent)")
        XCTAssertEqual(card.entries[1].windows[0].percent, 0,
            "契约：解码侧 percent -5 必须 clamp 到 0，实际 \(card.entries[1].windows[0].percent)")
    }

    // MARK: - 副作用：finally 删临时文件（多次执行后 /tmp 不累积 *.card.json）

    func test_tempCardFilesCleaned_afterMultipleRuns() async throws {
        let baseline = try countCardTempFiles()
        let (pluginDir, manifest) = try makeStdinPlugin(dirName: "card-cleanup", scriptBody: """
            cat > "$BUDDY_OUTPUT_CARD" <<'CARD_EOF'
            \(designCardJSON())
            CARD_EOF
            echo done
            """)
        for i in 0..<3 {
            _ = try await execute(manifest, pluginDir: pluginDir, query: "round-\(i)")
        }
        let after = try countCardTempFiles()
        XCTAssertLessThanOrEqual(after, baseline + 1,
            "3 次执行后 /tmp/buddy-plugin-*.card.json 数 \(after) 必须有界（基准 \(baseline)）——finally 清理缺失则 +3")
    }
}
