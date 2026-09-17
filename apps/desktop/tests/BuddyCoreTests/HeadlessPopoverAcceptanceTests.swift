import XCTest
import AppKit
@testable import BuddyCore

// MARK: - HeadlessPopoverAcceptanceTests
//
// 红队验收测试 —— 冻结谓词 SSOT：`.autopilot/runtime/requirements/20260917-开始实现/state.md`
//
// 驱动方式 = 能力 1（XCTest in-process UI 驱动）：直接构造 SessionPopoverController +
// updateSessions（设计文档 §4 声明的接口名）+ 读 view 树断言，不经外部 AX。
//
// 覆盖谓词：
//   S3-P1 [det-machine] popover「后台任务」分组展示该会话条目（group_node exists && entries contains <bg-id>）
//   S3-P2 [det-machine] 该条目呈现 ⚙ 图标与 tokens 计数文本（icon_present && tokens_text matches 数字）
//   S3-P3 [det-machine] 状态迁移后条目状态文本同步更新且 tokens 单调不减
//   S4-P2 [det-machine] 点击「后台任务」分组条目 → 不触发终端跳转/激活
//                       （in-process 观测点 = onSessionClicked 对 headless 行零触发；
//                         真实「终端激活 tab」由 HeadlessAcceptanceE2EChecklist.sh 真机半场覆盖）
//   S7-P1/P2/P3 [det-machine] 6 交互 + 3 后台并存互不挤占；后台结束 → 分组减一上屏不变；
//                       交互结束 → 上屏减一分组不变
//   C-POPOVER-GROUP（契约）固定顺序 = 交互组在前 + headless 组在后；header 文案「后台任务 (N)」
//                       逐字一致；N=0 不渲染；headless 行首图标 ⚙
//
// TDD 红灯：分组/⚙/点击禁用落地前 S3-*/S4-P2/S7-* 断言失败是预期；编译只依赖既有符号
//（SessionPopoverController.updateSessions([SessionInfo])、SessionRowView.onClick 均为既有 API）。

@MainActor
final class HeadlessPopoverAcceptanceTests: XCTestCase {

    var scene: MockScene!
    var manager: SessionManager!
    var controller: SessionPopoverController!
    var fixtures: [RedTeamHeadlessFixture] = []
    var clickEvents: [SessionInfo] = []

    override func setUp() {
        super.setUp()
        scene = MockScene()
        manager = SessionManager(scene: scene)
        controller = SessionPopoverController()
        fixtures = []
        clickEvents = []
        controller.onSessionClicked = { [weak self] info in
            self?.clickEvents.append(info)
        }
        try? FileManager.default.removeItem(atPath: SessionManager.colorFilePath)
    }

    override func tearDown() {
        for fixture in fixtures { fixture.cleanup() }
        fixtures = []
        try? FileManager.default.removeItem(atPath: SessionManager.colorFilePath)
        super.tearDown()
    }

    // MARK: - Probe 结构（view 树行为快照）

    private struct RowInfo {
        let minY: CGFloat
        let texts: [String]
    }

    private struct PopoverProbe {
        let allTexts: [String]
        let headerText: String?
        let headerMinY: CGFloat?
        let rowsAboveHeader: [RowInfo]   // 视觉在 header 上方（AppKit Y 向上 → minY 更大）
        let rowsBelowHeader: [RowInfo]   // 视觉在 header 下方（headless 组）
    }

    /// 递归收集 container 视图树中的文本与 SessionRowView 行快照
    private func probe(_ target: NSView) -> PopoverProbe {
        let container = target
        container.layoutSubtreeIfNeeded()

        var allTexts: [String] = []
        var rows: [RowInfo] = []
        var headerText: String?
        var headerMinY: CGFloat?

        func collectTexts(in view: NSView, into out: inout [String]) {
            for sub in view.subviews {
                if let tf = sub as? NSTextField { out.append(tf.stringValue) }
                collectTexts(in: sub, into: &out)
            }
        }

        func walk(_ view: NSView) {
            for sub in view.subviews {
                if let tf = sub as? NSTextField {
                    allTexts.append(tf.stringValue)
                    if headerText == nil && tf.stringValue.hasPrefix("后台任务") {
                        headerText = tf.stringValue
                        headerMinY = tf.convert(tf.bounds, to: container).minY
                    }
                }
                if sub is SessionRowView {
                    let frame = sub.convert(sub.bounds, to: container)
                    var rowTexts: [String] = []
                    collectTexts(in: sub, into: &rowTexts)
                    rows.append(RowInfo(minY: frame.minY, texts: rowTexts))
                }
                walk(sub)
            }
        }
        walk(container)

        var above: [RowInfo] = []
        var below: [RowInfo] = []
        if let headerY = headerMinY {
            above = rows.filter { $0.minY > headerY }
            below = rows.filter { $0.minY < headerY }
        } else {
            above = rows
        }
        return PopoverProbe(allTexts: allTexts, headerText: headerText, headerMinY: headerMinY,
                            rowsAboveHeader: above, rowsBelowHeader: below)
    }

    /// 把 manager 当前会话喂给 popover 并重新探测（设计文档声明的接口：updateSessions）
    @discardableResult
    private func refreshPopover() -> PopoverProbe {
        controller.updateSessions(manager.sessions.values.sorted { $0.sessionId < $1.sessionId })
        return probe(controller.view)
    }

    /// 注册 n 个交互会话（无注册表文件 → fail-open interactive）并等其上屏
    @discardableResult
    private func registerInteractiveSessions(_ n: Int, prefix: String) -> [String] {
        var ids: [String] = []
        for i in 1...n {
            let sid = RedTeamAcceptance.uniqueSessionId("\(prefix)\(i)")
            ids.append(sid)
            manager.handle(message: RedTeamAcceptance.makeHookMessage(
                sessionId: sid, event: "session_start", cwd: "/projects/\(prefix)\(i)"))
        }
        XCTAssertTrue(
            RedTeamAcceptance.waitUntil(timeout: RedTeamAcceptance.failOpenTimeout) {
                self.scene.addCatCalls.count >= n
            },
            "前提：\(n) 个交互会话应全部上屏")
        return ids
    }

    /// 注册一个后台会话（真实 -p 进程 + 注册表文件）并等判型窗口过去
    private func registerBackgroundSession(prefix: String) throws -> String {
        let fixture = try RedTeamHeadlessFixture(
            sessionId: RedTeamAcceptance.uniqueSessionId(prefix), argvToken: "-p")
        fixtures.append(fixture)
        manager.handle(message: RedTeamAcceptance.makeHookMessage(
            sessionId: fixture.sessionId, event: "session_start", cwd: "/projects/\(prefix)"))
        Thread.sleep(forTimeInterval: RedTeamAcceptance.headlessVerdictWindow)
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        XCTAssertFalse(scene.addCatCalls.contains { $0.sessionId == fixture.sessionId },
                       "前提：后台会话不应上屏")
        return fixture.sessionId
    }

    // MARK: - S3-P1 后台任务分组展示

    /// 1 交互 + 1 后台：popover 出现「后台任务 (1)」header，且该分组下有 1 个条目行。
    func testS3P1_BackgroundGroupShownWithEntryBelowHeader() throws {
        registerInteractiveSessions(1, prefix: "s3p1i")
        let bgId = try registerBackgroundSession(prefix: "s3p1bg")

        let result = refreshPopover()

        XCTAssertEqual(result.headerText, "后台任务 (1)",
                       "分组 header 文案必须与 C-POPOVER-GROUP 逐字一致（N=1）")
        XCTAssertEqual(result.rowsBelowHeader.count, 1,
                       "「后台任务」分组下应有且仅有 1 个条目行")
        XCTAssertTrue(result.rowsBelowHeader.first?.texts.contains { !$0.isEmpty } == true,
                      "后台分组条目应渲染非空内容（entries contains <bg-id> 的呈现面）")
        _ = bgId
    }

    // MARK: - S3-P2 ⚙ 图标 + tokens 计数文本

    /// 后台条目行：含 ⚙ 图标文本 + 含数字的 tokens 计数文本；
    /// 对照组：交互行不含 ⚙（击杀「所有行都画 ⚙」突变）。
    func testS3P2_BackgroundRowShowsGearIconAndTokenCountText() throws {
        let bgId = try registerBackgroundSession(prefix: "s3p2bg")
        manager.handle(message: RedTeamAcceptance.makeHookMessage(
            sessionId: bgId, event: "set_tokens", totalTokens: 5_000_000))

        let interactiveId = registerInteractiveSessions(1, prefix: "s3p2i").first
        let result = refreshPopover()

        XCTAssertEqual(result.rowsBelowHeader.count, 1, "前提：后台分组恰 1 行")
        let bgRow = try XCTUnwrap(result.rowsBelowHeader.first)
        XCTAssertTrue(bgRow.texts.contains { $0.trimmingCharacters(in: .whitespaces) == "⚙" },
                      "后台条目行首必须呈现 ⚙ 图标（C-POPOVER-GROUP 逐字契约）；行文本 = \(bgRow.texts)")
        XCTAssertTrue(bgRow.texts.contains { $0.rangeOfCharacter(from: .decimalDigits) != nil },
                      "后台条目应呈现 tokens 计数文本（tokens_text matches 数字）；行文本 = \(bgRow.texts)")

        // 对照组：交互行不得出现 ⚙
        if let interactiveRow = result.rowsAboveHeader.first {
            XCTAssertFalse(interactiveRow.texts.contains { $0.contains("⚙") },
                           "交互行不得渲染 ⚙（颜色圆点是交互行标识）")
        }
        _ = interactiveId
    }

    // MARK: - S3-P3 状态文本同步更新 + tokens 单调不减

    /// 后台会话状态迁移（idle → thinking）后条目状态文本同步变化；
    /// set_tokens 后 tokens 单调不减（manager 层精确断言 + 行文本出现 tokens 计数）。
    func testS3P3_StateTextUpdatesAndTokensMonotonicallyNonDecreasing() throws {
        let bgId = try registerBackgroundSession(prefix: "s3p3bg")

        let before = refreshPopover()
        let tokensBefore = manager.sessions[bgId]?.totalTokens ?? 0

        // 状态迁移：idle → thinking
        manager.handle(message: RedTeamAcceptance.makeHookMessage(sessionId: bgId, event: "thinking"))
        // tokens 增长
        manager.handle(message: RedTeamAcceptance.makeHookMessage(
            sessionId: bgId, event: "set_tokens", totalTokens: 5_000_000))

        let after = refreshPopover()
        let tokensAfter = manager.sessions[bgId]?.totalTokens ?? -1

        XCTAssertNotEqual(after.headerText, nil, "前提：后台分组仍存在")
        let bgRow = try XCTUnwrap(after.rowsBelowHeader.first, "前提：后台条目行仍存在")
        let beforeRow = before.rowsBelowHeader.first

        XCTAssertNotEqual(bgRow.texts, beforeRow?.texts,
                          "状态/tokens 迁移后条目快照必须同步更新（state_after != state_before）")
        XCTAssertTrue(bgRow.texts.contains("thinking"),
                      "条目应呈现迁移后的状态文本 thinking")
        XCTAssertGreaterThanOrEqual(tokensAfter, tokensBefore,
                                    "tokens 必须单调不减（tokens_after >= tokens_before）")
        XCTAssertEqual(tokensAfter, 5_000_000, "set_tokens 后 totalTokens 应精确等于 5,000,000")
        XCTAssertTrue(bgRow.texts.contains { $0.rangeOfCharacter(from: .decimalDigits) != nil },
                      "tokens 增长后条目应呈现计数文本")
    }

    // MARK: - C-POPOVER-GROUP N=0 不渲染 header

    func testCPopoverGroup_NoHeaderWhenNoBackgroundSessions() {
        registerInteractiveSessions(1, prefix: "n0")

        let result = refreshPopover()

        XCTAssertFalse(result.allTexts.contains { $0.hasPrefix("后台任务") },
                       "后台任务数为 0 时不得渲染「后台任务」header；实际文本 = \(result.allTexts)")
        XCTAssertEqual(result.rowsAboveHeader.count, 1,
                       "仅交互组时应恰有 1 行")
    }

    // MARK: - S4-P2 点击后台条目不触发跳转

    /// 点击「后台任务」分组条目：onSessionClicked 零触发（headless 无终端可跳，
    /// activateTab 不可达）；对照组：点击交互行必须触发（击杀「点击全部禁用」突变）。
    func testS4P2_ClickingBackgroundRowDoesNotTriggerSessionClick() throws {
        let interactiveId = registerInteractiveSessions(1, prefix: "s4p2i").first
        let bgId = try registerBackgroundSession(prefix: "s4p2bg")

        let result = refreshPopover()

        // 点击全部后台行（行内已绑定的点击动作，等价用户点击；入口 = 既有公开 API onClick）
        let headerY = result.headerMinY
        let allRowViews = findRowViews(in: controller.view)
        let bgRowViews = allRowViews.filter {
            $0.convert($0.bounds, to: controller.view).minY < (headerY ?? -.greatestFiniteMagnitude)
        }
        XCTAssertEqual(bgRowViews.count, result.rowsBelowHeader.count,
                       "前提：header 下方行视图数与探测一致")
        for rowView in bgRowViews {
            rowView.onClick?()
        }
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        XCTAssertTrue(clickEvents.isEmpty,
                      "点击后台任务条目不得触发 onSessionClicked（不跳终端）；实际触发了 \(clickEvents.map(\.sessionId))")
        XCTAssertFalse(clickEvents.contains { $0.sessionId == bgId },
                       "后台会话 <bg-id> 不得出现在点击激活事件中")

        // 对照组（mutation control）：点击交互行必须触发 —— 证明「没触发」不是点击通道坏了
        guard let iid = interactiveId,
              let interactiveRow = allRowViews.first(where: {
                  $0.convert($0.bounds, to: controller.view).minY > (headerY ?? .greatestFiniteMagnitude)
              })
        else {
            XCTFail("前提：应存在交互行可点击")
            return
        }
        interactiveRow.onClick?()
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        XCTAssertTrue(clickEvents.contains { $0.sessionId == iid },
                      "对照组：点击交互行必须触发 onSessionClicked（证明断言通道有效）")
    }

    private func findRowViews(in view: NSView) -> [SessionRowView] {
        var found: [SessionRowView] = []
        for sub in view.subviews {
            if let row = sub as? SessionRowView { found.append(row) }
            found.append(contentsOf: findRowViews(in: sub))
        }
        return found
    }

    // MARK: - S7-P1 + P2 + P3 混合共存互不挤占

    /// 6 交互 + 3 后台并存：
    ///   P1: 上屏集合 == 交互集（6）、后台分组 == 3、交集为空
    ///   P2: 某后台结束（session_end）→ 分组 == 2、上屏不变（6）
    ///   P3: 某交互结束 → 上屏 == 5、分组仍 == 2
    func testS7_MixedInteractiveAndBackgroundCoexistWithoutDisplacement() throws {
        // P1：并存
        let interactiveIds = registerInteractiveSessions(6, prefix: "s7i")
        var bgIds: [String] = []
        for i in 1...3 {
            bgIds.append(try registerBackgroundSession(prefix: "s7bg\(i)"))
        }

        var result = refreshPopover()

        let onScreen = Set(scene.addCatCalls.map(\.sessionId))
        let interactiveSet = Set(interactiveIds)
        let bgSet = Set(bgIds)
        XCTAssertEqual(onScreen, interactiveSet,
                       "P1: 上屏集合必须等于交互集（onscreen_count == 6）")
        XCTAssertEqual(onScreen.intersection(bgSet), [],
                       "P1: 上屏集合与后台集交集必须为空")
        XCTAssertEqual(result.headerText, "后台任务 (3)", "P1: 后台分组 header 应为「后台任务 (3)」")
        XCTAssertEqual(result.rowsBelowHeader.count, 3, "P1: 后台分组条目数应为 3")
        XCTAssertEqual(scene.addCatCalls.count, 6, "P1: 上屏猫数应为 6")

        // P2：某后台任务结束 → 移出分组，上屏猫数不变
        manager.handle(message: RedTeamAcceptance.makeHookMessage(
            sessionId: bgIds[0], event: "session_end"))
        result = refreshPopover()

        XCTAssertNil(manager.sessions[bgIds[0]], "P2: 结束的后台会话应移出 registered")
        XCTAssertEqual(result.headerText, "后台任务 (2)", "P2: 后台分组应减为「后台任务 (2)」")
        XCTAssertEqual(result.rowsBelowHeader.count, 2, "P2: 后台分组条目数应为 2")
        XCTAssertEqual(scene.addCatCalls.count, 6, "P2: 上屏猫数必须保持 6（后台结束不挤占交互位）")

        // P3：某交互会话结束 → 移出上屏集合，后台分组数不变
        manager.handle(message: RedTeamAcceptance.makeHookMessage(
            sessionId: interactiveIds[0], event: "session_end"))
        result = refreshPopover()

        XCTAssertNil(manager.sessions[interactiveIds[0]], "P3: 结束的交互会话应移出 registered")
        XCTAssertTrue(scene.removeCatCalls.contains(interactiveIds[0]),
                      "P3: 交互会话结束应下屏（removeCat）")
        XCTAssertEqual(scene.addCatCalls.count, 6, "P3: addCat 累计不变（下屏走 removeCat）")
        // 当前在屏集合 = 累计 add − 累计 remove（addCatCalls 是调用日志，非当前状态；
        // 对从未上屏的后台会话做集合差不受防御性 removeCat 影响）
        let currentOnScreen = Set(scene.addCatCalls.map(\.sessionId)).subtracting(scene.removeCatCalls)
        XCTAssertEqual(currentOnScreen.count, 5, "P3: 当前在屏猫数应减为 5")
        XCTAssertFalse(currentOnScreen.contains(interactiveIds[0]),
                       "P3: onscreen_count 应减为 5（<session-id> 已移出上屏集合）")
        XCTAssertEqual(result.headerText, "后台任务 (2)", "P3: 后台分组必须保持 2（交互结束不影响后台组）")
        XCTAssertEqual(result.rowsBelowHeader.count, 2, "P3: 后台分组条目数保持 2")
    }
}
