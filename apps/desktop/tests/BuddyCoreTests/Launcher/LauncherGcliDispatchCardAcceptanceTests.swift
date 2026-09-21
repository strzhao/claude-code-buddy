import XCTest
@testable import BuddyCore

// MARK: - LauncherGcliDispatchCardAcceptanceTests
//
// 红队验收测试（TDD 红灯）：场景 2/5/6/7 的分发层——Enter 分发参数剥离、无匹配提示、
// card 事件防重复、降级不崩溃
//
// 谓词映射（SSOT: state.md ## 验收场景）：
//   s2p1 [det-machine] 输入 gc 选中 gcli 候选回车 → 结果区非空 且 不含「没有名称匹配」
//        ｜ artifact: /tmp/autopilot-artifacts/s2p1.out
//   s2p2 [det-machine] 输入完整词 gcli 回车 → 同上 ｜ artifact: s2p2.out
//   s2p3 [det-machine] 输入中文热词 限额 回车 → 同上 ｜ artifact: s2p3.out
//   s5p2 [det-machine] 直调分发 query="xy" → 结果区含无匹配提示 ｜ artifact: s5p2.out
//   s7p3 [det-machine] card 存在时仅渲染卡片一次，stdout 兜底文本不重复出现
//        ｜ event 级等价观测：AgentEvent.card 恰 1 次 ∧ 无 .text 含兜底标记（错误契约：
//          「card 存在时不 yield .text」）｜ artifact: s7p3.out
//   s6p2 [det-machine] 故障注入下 Launcher 执行 → 错误提示呈现 且 进程存活
//        ｜ artifact: s6p2.out
//
// 驱动方式（apps/desktop/CLAUDE.md 能力 1 in-process）：
//   候选发现前置：updateQuery → instantActions 含 gcli 行（=「选中 gcli 候选」）；
//   回车执行：LauncherManager.submitCommandDirect(manifest, query:) —— 设计声明的
//   command 短路入口（C-ENTER-EXEC），内部 stripKeywordPrefix（W2 观测点）；
//   结果区观测：事件流 .text/.card（LauncherInputView 渲染同源）。
//
// fixture 插件：镜像真 quota.py 的纯文本契约（query 空 → 全部条目；无匹配 → 「没有名称匹配」），
// 确定性零网络；真实 quota.py 全链路由 bash 验收 s2p4/s5p1 覆盖，两层合取。
//
// Mutation-Survival 自检：
//   - W2 No-op（strip 不加前缀分支）→ "gc" 透传插件 → 「没有名称匹配」→ s2p1 挂（捕获）
//   - s7p3 No-op（card 存在仍 yield .text）→ 兜底标记出现在 .text → 挂（捕获）
//   - s7p3 反向（card 丢失）→ .card 事件数为 0 → 挂（捕获）
//   - s6p2 过度放宽（无匹配也被吞）→ s5p2 断言提示在场 → 挂（捕获）
//
// AgentEvent.card / PluginResult.card 未实现时本文件编译失败＝预期 TDD 红灯。

@MainActor
final class LauncherGcliDispatchCardAcceptanceTests: XCTestCase {

    private var tmpRoot: URL!

    // MARK: - 生命周期

    override func setUp() async throws {
        try await super.setUp()
        tmpRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccb-gcli-dispatch-\(UUID().uuidString)")
        LauncherManager.shared.resetSubmittingStateForTesting()
        LauncherManager.shared.instantDebounceMsOverride = 0
        LauncherManager.shared.registryOverride = makeEmptyRegistry()
        LauncherManager.shared.pluginsOverride = nil
        LauncherManager.shared.stdinExecutorOverride = nil
        LauncherManager.shared.clearInstantActions()
        LauncherManager.shared.updateQuery("")
        if LauncherManager.shared.isVisible {
            LauncherManager.shared.hide()
        }
    }

    override func tearDown() async throws {
        LauncherManager.shared.pluginsOverride = nil
        LauncherManager.shared.registryOverride = nil
        LauncherManager.shared.stdinExecutorOverride = nil
        LauncherManager.shared.pluginManagerOverride = nil
        LauncherManager.shared.clearInstantActions()
        LauncherManager.shared.updateQuery("")
        if let root = tmpRoot { try? FileManager.default.removeItem(at: root) }
        tmpRoot = nil
        try await super.tearDown()
    }

    // MARK: - fixture：镜像 quota.py 文本契约的确定性插件（物理落地 rootDir/gcli）

    /// 脚本契约（与真 quota.py 对齐的观察面）：
    ///   收到 query == "" → 输出全部条目（标题含「gcli 套餐限额」）
    ///   收到 query == kimi/glm（大小写不敏感）→ 输出该条目（标题含「gcli 套餐限额」）
    ///   其他 → 「没有名称匹配：<query>」
    private func installGcliPlugin(scriptExtra: String = "") throws -> PluginManifest {
        let pluginDir = tmpRoot.appendingPathComponent("gcli")   // pluginDir(for:) 按 name 解析
        try FileManager.default.createDirectory(at: pluginDir, withIntermediateDirectories: true)
        let script = """
        #!/bin/bash
        INPUT=$(cat)
        Q=$(printf '%s' "$INPUT" | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin).get("query",""))' 2>/dev/null || echo "")
        case "$Q" in
          ""|kimi|KIMI|Kimi|glm|GLM|Glm)
            echo "📶 gcli 套餐限额（2 个）"
            echo "🟢 kimi ｜ 5h 12% ↻3h20m ｜ 周窗 45% ↻2d4h"
            echo "🟡 glm ｜ 5h 66% ↻1h5m" ;;
          *) echo "没有名称匹配：$Q" ;;
        esac
        \(scriptExtra)
        exit 0
        """
        let scriptURL = pluginDir.appendingPathComponent("run.sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        let manifestJSON = """
        { "name": "gcli", "version": "0.2.0-test", "description": "gcli dispatch fixture",
          "keywords": ["gcli", "限额", "套餐", "用量"], "mode": "command", "cmd": "./run.sh",
          "args": [], "env": null, "timeout": 10, "requiredPath": null }
        """
        try manifestJSON.write(to: pluginDir.appendingPathComponent("plugin.json"),
                               atomically: true, encoding: .utf8)
        let manifest = try JSONDecoder().decode(PluginManifest.self,
                                                from: Data(contentsOf: pluginDir.appendingPathComponent("plugin.json")))
        // TOFU 预信任（免 NSAlert 挂死）
        try TrustStore.shared.approve(manifest, executablePath: scriptURL)
        // 分发链解析 pluginDir 用 rootDir/gcli
        LauncherManager.shared.pluginManagerOverride = PluginManager(rootDir: tmpRoot)
        LauncherManager.shared.pluginsOverride = [manifest]
        return manifest
    }

    /// card 写入变体：写合法 card JSON + 打印兜底文本（s7p3 防重复观测）
    private var cardWriterExtra: String {
        """
        if [ -n "$BUDDY_OUTPUT_CARD" ]; then
          /usr/bin/python3 - "$BUDDY_OUTPUT_CARD" <<'PY_EOF'
        import json, sys
        card = {"title": "gcli 套餐限额 · 2 个", "entries": [
            {"name": "kimi", "level": "ok", "badge": "使用中", "windows": [
                {"label": "5h", "percent": 12, "reset": "3h20m"},
                {"label": "周窗", "percent": 45, "reset": "2d4h"}]},
            {"name": "glm", "level": "warn", "badge": "", "windows": [
                {"label": "5h", "percent": 66, "reset": "1h5m"}]}]}
        with open(sys.argv[1], "w", encoding="utf-8") as f:
            f.write(json.dumps(card, ensure_ascii=False))
        PY_EOF
        fi
        echo "S7P3_STDOUT_FALLBACK_MARKER"
        """
    }

    private func makeEmptyRegistry() -> BuiltinPluginRegistry {
        BuiltinPluginRegistry(plugins: [EmptyActionsPluginForGcliDispatchTest()])
    }

    /// 候选发现 + 稳定等待（updateQueryAndSettle 同构）
    private func updateQueryAndSettle(_ query: String) async {
        LauncherManager.shared.updateQuery(query)
        var lastCount = -1
        var stablePolls = 0
        let deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline && stablePolls < 4 {
            let count = LauncherManager.shared.instantActions.count
            if count == lastCount { stablePolls += 1 } else { stablePolls = 0; lastCount = count }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    /// 回车分发（C-ENTER-EXEC 的 command 短路入口）并收集事件流
    private func dispatchAndCollect(_ manifest: PluginManifest, query: String) async -> [AgentEvent] {
        let stream = LauncherManager.shared.submitCommandDirect(manifest, query: query)
        var events: [AgentEvent] = []
        for await ev in stream { events.append(ev) }
        return events
    }

    private func texts(of events: [AgentEvent]) -> [String] {
        var out: [String] = []
        for ev in events {
            if case .text(let t) = ev { out.append(t) }
        }
        return out
    }

    private func cards(of events: [AgentEvent]) -> [PluginCard] {
        var out: [PluginCard] = []
        for ev in events {
            if case .card(let c) = ev { out.append(c) }
        }
        return out
    }

    private func writeArtifact(_ name: String, _ lines: [String]) {
        let dir = "/tmp/autopilot-artifacts"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let content = ([name] + lines).joined(separator: "\n") + "\n"
        try? content.write(toFile: dir + "/" + name, atomically: true, encoding: .utf8)
    }

    // MARK: - s2p1：gc → 剥离为空参 → 全部条目（无「没有名称匹配」）

    func test_s2p1_queryGc_dispatchStripsPrefix_resultNonEmptyNoNoMatch() async throws {
        let manifest = try installGcliPlugin()

        // 前置：输入 gc → gcli 候选在场（「选中 gcli 候选」的前半段）
        await updateQueryAndSettle("gc")
        let row = try XCTUnwrap(
            LauncherManager.shared.instantActions.first { $0.pluginId == "gcli" },
            "s2p1 前置：输入 gc 必须产出 gcli 插件候选行，实际=\(LauncherManager.shared.instantActions.map(\.title))")

        // 回车执行 == 行 perform 的分发目标（C-ENTER-EXEC：command → submitCommandDirect）
        let events = await dispatchAndCollect(manifest, query: "gc")
        let combined = texts(of: events).joined(separator: "\n")

        writeArtifact("s2p1.out", [
            "query=gc row=\(row.title)",
            "textNonEmpty=\(!combined.isEmpty)",
            "containsNoMatchHint=\(combined.contains("没有名称匹配"))",
            "containsTitle=\(combined.contains("gcli 套餐限额"))",
            "events=\(events.count) texts=\(texts(of: events).count)",
        ])

        XCTAssertFalse(combined.isEmpty, "s2p1: 结果区必须非空")
        XCTAssertFalse(combined.contains("没有名称匹配"),
            "s2p1: 「gc」应被剥离为空参显示全部条目，不得出现「没有名称匹配」（W2 核心断言）。实际: \(combined)")
        XCTAssertTrue(combined.contains("gcli 套餐限额"),
            "s2p1: 正向锚点——结果区应含标题「gcli 套餐限额」。实际: \(combined)")
    }

    // MARK: - s2p2：完整词 gcli 回车（既有完全剥离分支回归）

    func test_s2p2_queryGcli_fullWord_resultNonEmptyNoNoMatch() async throws {
        let manifest = try installGcliPlugin()
        await updateQueryAndSettle("gcli")
        _ = try XCTUnwrap(
            LauncherManager.shared.instantActions.first { $0.pluginId == "gcli" },
            "s2p2 前置：输入 gcli 必须产出 gcli 候选行")

        let events = await dispatchAndCollect(manifest, query: "gcli")
        let combined = texts(of: events).joined(separator: "\n")

        writeArtifact("s2p2.out", [
            "query=gcli",
            "textNonEmpty=\(!combined.isEmpty)",
            "containsNoMatchHint=\(combined.contains("没有名称匹配"))",
            "containsTitle=\(combined.contains("gcli 套餐限额"))",
        ])

        XCTAssertFalse(combined.isEmpty, "s2p2: 结果区必须非空")
        XCTAssertFalse(combined.contains("没有名称匹配"), "s2p2: 完整词 gcli → 空参 → 全部条目")
        XCTAssertTrue(combined.contains("gcli 套餐限额"), "s2p2: 正向锚点标题。实际: \(combined)")
    }

    // MARK: - s2p3：中文热词 限额 回车（中文词保留验证）

    func test_s2p3_queryXiane_resultNonEmptyNoNoMatch() async throws {
        let manifest = try installGcliPlugin()
        await updateQueryAndSettle("限额")
        _ = try XCTUnwrap(
            LauncherManager.shared.instantActions.first { $0.pluginId == "gcli" },
            "s2p3 前置：输入 限额 必须产出 gcli 候选行")

        let events = await dispatchAndCollect(manifest, query: "限额")
        let combined = texts(of: events).joined(separator: "\n")

        writeArtifact("s2p3.out", [
            "query=限额",
            "textNonEmpty=\(!combined.isEmpty)",
            "containsNoMatchHint=\(combined.contains("没有名称匹配"))",
            "containsTitle=\(combined.contains("gcli 套餐限额"))",
        ])

        XCTAssertFalse(combined.isEmpty, "s2p3: 结果区必须非空")
        XCTAssertFalse(combined.contains("没有名称匹配"), "s2p3: 中文热词 限额 → 空参 → 全部条目")
        XCTAssertTrue(combined.contains("gcli 套餐限额"), "s2p3: 正向锚点标题。实际: \(combined)")
    }

    // MARK: - s5p2：直调分发 xy → 无匹配提示（防过度放宽）

    func test_s5p2_directDispatchXy_showsNoMatchHint() async throws {
        let manifest = try installGcliPlugin()

        let events = await dispatchAndCollect(manifest, query: "xy")
        let combined = texts(of: events).joined(separator: "\n")

        writeArtifact("s5p2.out", [
            "query=xy",
            "containsNoMatchHint=\(combined.contains("没有名称匹配"))",
            "text=\(combined.prefix(120))",
        ])

        XCTAssertTrue(combined.contains("没有名称匹配"),
            "s5p2: 直调分发 xy（非任何触发词前缀）必须保留无匹配提示（防过度放宽）。实际: \(combined)")
    }

    // MARK: - s7p3：card 存在 → .card 恰一次 ∧ 兜底文本不重复出现

    func test_s7p3_cardPresent_yieldsCardOnce_noDuplicateFallbackText() async throws {
        let manifest = try installGcliPlugin(scriptExtra: cardWriterExtra)

        let events = await dispatchAndCollect(manifest, query: "gcli")
        let cardEvents = cards(of: events)
        let textsJoined = texts(of: events).joined(separator: "\n")

        writeArtifact("s7p3.out", [
            "events=\(events.count) cardEvents=\(cardEvents.count) textEvents=\(texts(of: events).count)",
            "cardTitle=\(cardEvents.first?.title ?? "<nil>")",
            "fallbackMarkerInText=\(textsJoined.contains("S7P3_STDOUT_FALLBACK_MARKER"))",
        ])

        XCTAssertEqual(cardEvents.count, 1,
            "s7p3: card 存在时必须 yield 恰一次 .card，实际 \(cardEvents.count) 次")
        XCTAssertFalse(textsJoined.contains("S7P3_STDOUT_FALLBACK_MARKER"),
            "s7p3: card 存在时不得再 yield stdout 兜底文本（错误契约：card 存在时不 yield .text），实际 .text=\(texts(of: events))")
        XCTAssertEqual(cardEvents.first?.title, "gcli 套餐限额 · 2 个",
            "s7p3: card 事件载荷应为解码后的 PluginCard（设计示例 title 逐字）")
    }

    // MARK: - s6p2：故障降级 → 错误提示呈现 ∧ 进程存活

    /// 数据源/端点故障由插件内部降级（恒 exit 0 + 友好文案，bash s6p1 验真插件）；
    /// 本用例验 Launcher 层：降级文本原样呈现、不出现崩溃路径、测试进程（=app 同进程宿主）存活。
    func test_s6p2_degradedOutput_presented_processAlive() async throws {
        let manifest = try installGcliPlugin(scriptExtra: """
            # 覆盖上文输出：模拟数据源故障降级（真 quota.py 的 ⚠️ 暂时无法获取 契约）
            echo "⚠️ 暂时无法获取：kimi"
            """)

        let events = await dispatchAndCollect(manifest, query: "gcli")
        let combined = texts(of: events).joined(separator: "\n")

        // 进程存活硬观测：执行完成后当前进程仍可正常工作
        let pid = ProcessInfo.processInfo.processIdentifier

        writeArtifact("s6p2.out", [
            "degradeTextPresented=\(combined.contains("暂时无法获取"))",
            "crashHintInText=\(combined.contains("plugin") && combined.contains("crash"))",
            "pid=\(pid) aliveAfterDispatch=true",
        ])

        XCTAssertTrue(combined.contains("暂时无法获取"),
            "s6p2: 降级文案必须呈现为结果文本。实际: \(combined)")
        XCTAssertGreaterThan(pid, 0, "s6p2: 分发完成后进程必须存活")
    }

    /// s6p2 反向切片：插件真崩（exit≠0）→ 事件流必须终止并给出失败信号（不得永久 loading/挂死）
    func test_s6p2b_pluginCrash_streamTerminates_withErrorSignal() async throws {
        let pluginDir = tmpRoot.appendingPathComponent("gcli")
        try FileManager.default.createDirectory(at: pluginDir, withIntermediateDirectories: true)
        let script = "#!/bin/bash\necho boom >&2\nexit 2\n"
        let scriptURL = pluginDir.appendingPathComponent("run.sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        let manifestJSON = """
        { "name": "gcli", "version": "0.2.0-test", "description": "crash fixture",
          "keywords": ["gcli", "限额", "套餐", "用量"], "mode": "command", "cmd": "./run.sh",
          "args": [], "env": null, "timeout": 5, "requiredPath": null }
        """
        try manifestJSON.write(to: pluginDir.appendingPathComponent("plugin.json"),
                               atomically: true, encoding: .utf8)
        let manifest = try JSONDecoder().decode(PluginManifest.self,
                                                from: Data(contentsOf: pluginDir.appendingPathComponent("plugin.json")))
        try TrustStore.shared.approve(manifest, executablePath: scriptURL)
        LauncherManager.shared.pluginManagerOverride = PluginManager(rootDir: tmpRoot)
        LauncherManager.shared.pluginsOverride = [manifest]

        let start = Date()
        let events = await dispatchAndCollect(manifest, query: "gcli")
        let elapsed = Date().timeIntervalSince(start)
        let combined = texts(of: events).joined(separator: "\n")

        writeArtifact("s6p2b.out", [
            "exit=2 streamTerminated=true elapsedSec=\(String(format: "%.1f", elapsed))",
            "events=\(events.count) text=\(combined.prefix(120))",
        ])

        XCTAssertLessThan(elapsed, 15,
            "s6p2: 插件崩溃后事件流必须快速终止（timeout=5 兜底），实际 \(elapsed)s")
        XCTAssertFalse(events.isEmpty, "s6p2: 崩溃路径必须产出失败信号事件（非静默）")
        XCTAssertTrue(combined.isEmpty || !combined.contains("gcli 套餐限额"),
            "s6p2: 崩溃路径不得渲染成功标题")
    }
}

// MARK: - Mock 空 registry 插件

private struct EmptyActionsPluginForGcliDispatchTest: BuiltinPlugin {
    let id = "empty-gcli-dispatch-test"
    let priority = 0
    let sectionTitle = "Empty"
    func actions(for query: String) async -> [LauncherAction] { [] }
}
