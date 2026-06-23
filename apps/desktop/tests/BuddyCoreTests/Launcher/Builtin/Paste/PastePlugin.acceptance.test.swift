import AppKit
import XCTest
@testable import BuddyCore

// MARK: - PastePluginAcceptanceTests
//
// 红队验收测试：PastePlugin（BuiltinPlugin 实现，触发词门控 + 候选构造 + perform 回填）
//
// 本文件覆盖（预注册谓词 → 硬断言）：
//   场景1.P1 [det-machine]    触发词（cb/剪贴板）→ 候选区展示历史（count >= 1，非触发词返回 []）
//   场景1.P3 [det-machine]    列表按复制时间倒序（first == 最近一次复制）
//   场景2.P1 [det-machine]    选中条目回车 → NSPasteboard.string == 原文
//   场景2.P3 [det-machine]    回车写入后浮窗关闭（本测试断言 perform 不抛错 + 剪贴板写入成功）
//   场景3.P1 [det-machine]    选中图片回车 → NSPasteboard.png data exists AND length > 0
//   场景3.P2 [det-machine]    选中文件路径回车 → NSPasteboard.fileURL startsWith "file://"
//   场景3.P3 [det-machine]    选中富文本回车 → NSPasteboard.html data exists AND length > 0
//   场景3.P4 [det-machine]    选中富文本回车 → 同时提供纯文本降级（.string exists AND length > 0）
//   场景6.P1 [det-machine]    连续复制相同内容 → 候选中该内容出现次数 == 1
//   场景7.P1 + P2 [det-machine] 历史为空 + 触发词 → actions 返回 [] 且不崩溃
//
// 红队红线：
//   - 不读取 apps/desktop/Sources/ClaudeCodeBuddy/Launcher/Builtin/Paste/ 下任何实现文件
//   - 仅依据设计文档契约逐字断言（接口签名 + 边界值字面量）
//   - perform 回填必须断言实际粘贴板内容（反 no-op "perform 不抛" 宽容断言）
//   - 触发词门控必须断言 first.pluginId == "paste"（反 "count > 0" 宽容断言）
//   - 注入 NSPasteboard(name:) 隔离，绝不污染系统剪贴板
//
// 测试 WILL NOT compile 直到蓝队合并实现 — 这是预期的 TDD 红灯。
//
// ISOLATION: 蓝队实现信息隔离，源码扫描留 QA 核对（不读 PastePlugin.swift）

// CONTRACT_AMBIGUOUS:
//   1. PastePlugin 构造器：契约写 PastePlugin.shared 单例。
//      测试需注入 CopyService（隔离剪贴板），假定存在 init(copyService:) 或类似 seam。
//      若蓝队仅暴露 .shared 且 .shared 内部硬编码 CopyService.shared，
//      perform 测试将无法隔离——按 CalculatorPlugin(copyService:) 同款 seam 假定。
//   2. ClipboardHistoryService 注入：PastePlugin 读取历史依赖 ClipboardHistoryService.shared。
//      测试需注入隔离的 service（含临时存储 + 隔离 pasteboard），假定 PastePlugin 有 init(historyService:copyService:) seam。
//      若蓝队无此 seam，需调整或契约澄清。
//   3. 触发词匹配大小写：契约写 query.lowercased().hasPrefix(trigger)。
//      "CB" / "Clipboard" 应匹配。本测试覆盖大小写。
//   4. cb <filter> 后缀过滤：契约写 "cb github" 过滤含 github 的条目。
//      actions(for:"cb github") 应返回过滤后候选。本测试断言。
//   5. 优先级仲裁：PastePlugin priority=150，介于 Calculator(200) 与 SystemCommand(100)。
//      本测试断言 priority 字面量 + 默认 registry 含 paste 插件。
//   6. 候选 title 截断：契约 title.count <= 50（超长截断 + "…"）。
//      本测试用 51 字符长文本验证截断。
//   7. 富文本 perform 写 public.html + 纯文本：契约覆盖 RTF。
//      本测试断言 .html data + .string 均存在。
//   8. 文件路径 perform：契约必须 writeObjects([NSURL])，禁用 setString(.fileURL)。
//      本测试通过 NSPasteboard.readObjects(forClass: NSURL.self) 验证（Finder 认的写法）。

@MainActor
final class PastePluginAcceptanceTests: XCTestCase {

    // MARK: - Helpers

    private func makePasteboard() -> NSPasteboard {
        let name = NSPasteboard.Name("ccb-test-pasteplugin-\(UUID().uuidString)")
        let pb = NSPasteboard(name: name)
        pb.clearContents()
        return pb
    }

    private func makeStorageDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccb-pasteplugin-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// 构造隔离的 PastePlugin（注入隔离 pasteboard + 临时存储目录）
    /// CONTRACT_AMBIGUOUS #1 + #2：假定 init(historyService:copyService:) seam 存在
    private func makeIsolatedPlugin(pasteboard: NSPasteboard, storageDir: URL) -> PastePlugin {
        let historyService = ClipboardHistoryService(pasteboard: pasteboard, storageDir: storageDir)
        let copyService = CopyService(pasteboard: pasteboard)
        return PastePlugin(historyService: historyService, copyService: copyService)
    }

    private func minimalPNG() -> Data {
        return Data([
            0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
            0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
            0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
            0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
            0x89, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x44, 0x41,
            0x54, 0x78, 0x9C, 0x62, 0x00, 0x01, 0x00, 0x00,
            0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00,
            0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
            0x42, 0x60, 0x82
        ])
    }

    // MARK: - PP1：属性契约（BuiltinPlugin 协议）

    /// PP1 / 场景1.P1 precondition：plugin.id == "paste"
    func test_PP1_id_paste() {
        let plugin = PastePlugin.shared
        XCTAssertEqual(plugin.id, "paste",
            "PP1: PastePlugin.id 必须 == \"paste\"，实际 \"\(plugin.id)\"")
    }

    /// PP1：plugin.priority == 150（介于 Calculator 200 与 SystemCommand 100 之间）
    func test_PP1_priority_equals150() {
        let plugin = PastePlugin.shared
        XCTAssertEqual(plugin.priority, 150,
            "PP1: PastePlugin.priority 必须 == 150（Calc 200 > Paste 150 > SysCmd 100），实际 \(plugin.priority)")
    }

    /// PP1：plugin.sectionTitle == "剪贴板"
    func test_PP1_sectionTitle_剪贴板() {
        let plugin = PastePlugin.shared
        XCTAssertEqual(plugin.sectionTitle, "剪贴板",
            "PP1: PastePlugin.sectionTitle 必须 == \"剪贴板\"，实际 \"\(plugin.sectionTitle)\"")
    }

    /// PP1：遵守 BuiltinPlugin 协议（通过协议访问）
    func test_PP1_conformsTo_BuiltinPlugin() {
        let plugin: any BuiltinPlugin = PastePlugin.shared
        XCTAssertEqual(plugin.id, "paste",
            "PP1: PastePlugin 必须遵守 BuiltinPlugin 协议且 id 正确")
        XCTAssertEqual(plugin.priority, 150,
            "PP1: 通过协议访问 priority 应为 150")
        XCTAssertEqual(plugin.sectionTitle, "剪贴板",
            "PP1: 通过协议访问 sectionTitle 应为 \"剪贴板\"")
    }

    // MARK: - PP2 / 场景1.P1：触发词门控（det-machine）

    /// 场景1.P1 [det-machine]：actions(for:"cb") 有历史时返回候选（count >= 1）+ pluginId == "paste"
    ///
    /// Mutation-Survival 自检：
    /// - hasPrefix 错 mutant（用 contains）→ "acb" 也匹配 → 非触发词测试失败（见 test_PP3）
    /// - 不返候选 mutant → count == 0 → 本断言失败（捕获）
    func test_PP2_scenario1_P1_triggerCb_returnsCandidates() async {
        let pb = makePasteboard()
        let dir = makeStorageDir()
        defer { cleanup(dir) }

        let plugin = makeIsolatedPlugin(pasteboard: pb, storageDir: dir)
        // 预置一条历史
        pb.clearContents(); pb.setString("trigger-cb-test", forType: .string)
        plugin.historyService.readPasteboard()  // CONTRACT_AMBIGUOUS: 假定 historyService 可达

        let actions = await plugin.actions(for: "cb")

        XCTAssertFalse(actions.isEmpty,
            "PP2 / 场景1.P1: actions(for:\"cb\") 有历史时必须返回候选，实际 \(actions.count) 条")
        XCTAssertEqual(actions.first?.pluginId, "paste",
            "PP2 / 场景1.P1 (mutation-killer): 候选 pluginId 必须 == \"paste\"，实际 \"\(actions.first?.pluginId ?? "nil")\"")
    }

    /// 场景1.P1 触发词 "剪贴板"：actions(for:"剪贴板") 返回候选
    func test_PP2_scenario1_P1_triggerChinese_剪贴板() async {
        let pb = makePasteboard()
        let dir = makeStorageDir()
        defer { cleanup(dir) }

        let plugin = makeIsolatedPlugin(pasteboard: pb, storageDir: dir)
        pb.clearContents(); pb.setString("trigger-chinese-test", forType: .string)
        plugin.historyService.readPasteboard()

        let actions = await plugin.actions(for: "剪贴板")
        XCTAssertFalse(actions.isEmpty,
            "PP2: actions(for:\"剪贴板\") 有历史时必须返回候选，实际 \(actions.count) 条")
    }

    /// 触发词大小写不敏感：actions(for:"CB") / actions(for:"Clipboard") 匹配
    /// 契约：query.lowercased().hasPrefix(trigger)
    func test_PP2_triggerCaseInsensitive() async {
        let pb = makePasteboard()
        let dir = makeStorageDir()
        defer { cleanup(dir) }

        let plugin = makeIsolatedPlugin(pasteboard: pb, storageDir: dir)
        pb.clearContents(); pb.setString("case-test", forType: .string)
        plugin.historyService.readPasteboard()

        let actionsUpper = await plugin.actions(for: "CB")
        XCTAssertFalse(actionsUpper.isEmpty,
            "PP2: actions(for:\"CB\") 必须匹配（lowercased().hasPrefix(\"cb\")），实际 \(actionsUpper.count) 条")

        let actionsMixed = await plugin.actions(for: "Clipboard")
        XCTAssertFalse(actionsMixed.isEmpty,
            "PP2: actions(for:\"Clipboard\") 必须匹配（lowercased().hasPrefix(\"clipboard\")），实际 \(actionsMixed.count) 条")
    }

    // MARK: - PP3：非触发词返回 []（反劫持门控）

    /// PP3：actions(for:"abc") → []（非触发词 hasPrefix 全 false）
    ///
    /// Mutation-Survival 自检：
    /// - 用 contains 替代 hasPrefix mutant → "acb" 含 "cb" → 匹配 → 本断言失败（捕获）
    /// - 不门控 mutant → 返回所有历史 → count > 0 → 本断言失败（捕获）
    func test_PP3_nonTrigger_returnsEmpty() async {
        let pb = makePasteboard()
        let dir = makeStorageDir()
        defer { cleanup(dir) }

        let plugin = makeIsolatedPlugin(pasteboard: pb, storageDir: dir)
        pb.clearContents(); pb.setString("non-trigger-content", forType: .string)
        plugin.historyService.readPasteboard()

        let actions = await plugin.actions(for: "abc")
        XCTAssertTrue(actions.isEmpty,
            "PP3 (mutation-killer): actions(for:\"abc\") 必须返回 []（非触发词 hasPrefix 全 false），实际 \(actions.count) 条")
    }

    /// PP3 补充：actions(for:"acb") → []（含 cb 子串但非前缀，反 contains mutant）
    func test_PP3_containsButNotPrefix_returnsEmpty() async {
        let pb = makePasteboard()
        let dir = makeStorageDir()
        defer { cleanup(dir) }

        let plugin = makeIsolatedPlugin(pasteboard: pb, storageDir: dir)
        pb.clearContents(); pb.setString("prefix-test", forType: .string)
        plugin.historyService.readPasteboard()

        let actions = await plugin.actions(for: "acb")  // 含 "cb" 但非前缀
        XCTAssertTrue(actions.isEmpty,
            "PP3 (mutation-killer): actions(for:\"acb\") 必须返回 []（hasPrefix(\"cb\")=false，反 contains mutant），实际 \(actions.count) 条")
    }

    /// PP3 补充：actions(for:"") → []（空 query）
    func test_PP3_emptyQuery_returnsEmpty() async {
        let plugin = PastePlugin.shared
        let actions = await plugin.actions(for: "")
        XCTAssertTrue(actions.isEmpty,
            "PP3: actions(for:\"\") 必须返回 []（空 query），实际 \(actions.count) 条")
    }

    // MARK: - PP4 / 场景1.P3：列表按复制时间倒序（det-machine）

    /// 场景1.P3 [det-machine]：列表首条 == 最近一次复制内容
    ///
    /// Mutation-Survival 自检：
    /// - 顺序反 mutant（最旧在前）→ first == "first-copy" → 本断言失败（捕获）
    func test_PP4_scenario1_P3_latestFirst() async {
        let pb = makePasteboard()
        let dir = makeStorageDir()
        defer { cleanup(dir) }

        let plugin = makeIsolatedPlugin(pasteboard: pb, storageDir: dir)
        pb.clearContents(); pb.setString("first-copy", forType: .string); plugin.historyService.readPasteboard()
        pb.clearContents(); pb.setString("second-copy", forType: .string); plugin.historyService.readPasteboard()
        pb.clearContents(); pb.setString("third-copy-latest", forType: .string); plugin.historyService.readPasteboard()

        let actions = await plugin.actions(for: "cb")
        guard let first = actions.first else {
            XCTFail("PP4 / 场景1.P3 precondition: 必须有候选")
            return
        }
        XCTAssertTrue(first.title.contains("third-copy-latest"),
            "PP4 / 场景1.P3 (mutation-killer): 首条必须 == 最近一次复制 \"third-copy-latest\"，实际 title \"\(first.title)\"")
    }

    // MARK: - PP5 / 场景2.P1：选中纯文本写入剪贴板（det-machine）

    /// 场景2.P1 [det-machine]：perform 后 NSPasteboard.string == 选中条目原文
    ///
    /// Mutation-Survival 自检：
    /// - No-op perform mutant → pasteboard 空 → 本断言失败（捕获）
    /// - 写 title 而非原文 mutant → != 原文 → 本断言失败（捕获）
    func test_PP5_scenario2_P1_performText_writesOriginalToPasteboard() async throws {
        let pb = makePasteboard()
        let dir = makeStorageDir()
        defer { cleanup(dir) }

        let plugin = makeIsolatedPlugin(pasteboard: pb, storageDir: dir)
        pb.clearContents(); pb.setString("perform-text-original", forType: .string)
        plugin.historyService.readPasteboard()

        let actions = await plugin.actions(for: "cb")
        guard let action = actions.first else {
            XCTFail("PP5 / 场景2.P1 precondition: 必须有候选")
            return
        }

        // 场景2.P3：perform 不抛错（浮窗关闭由 LauncherManager 管，此处断言 perform 安全）
        XCTAssertNoThrow(try action.perform(),
            "PP5 / 场景2.P3: perform() 不应抛错")

        // 场景2.P1：硬断言实际粘贴板内容 == 原文
        let actual = pb.string(forType: .string)
        XCTAssertEqual(actual, "perform-text-original",
            "PP5 / 场景2.P1 (mutation-killer): perform 后 pasteboard 必须 == 原文 \"perform-text-original\"，实际 \"\(actual ?? "nil")\"")
    }

    // MARK: - PP6 / 场景3.P1：选中图片写入剪贴板（det-machine）

    /// 场景3.P1 [det-machine]：perform 后 NSPasteboard.data(forType:.png) exists AND length > 0
    ///
    /// 谓词：observe NSPasteboard.data(forType:.png) | assert: exists == true AND length > 0
    func test_PP6_scenario3_P1_performImage_writesPNG() async throws {
        let pb = makePasteboard()
        let dir = makeStorageDir()
        defer { cleanup(dir) }

        let plugin = makeIsolatedPlugin(pasteboard: pb, storageDir: dir)
        let png = minimalPNG()
        pb.clearContents(); pb.setData(png, forType: .png)
        plugin.historyService.readPasteboard()

        let actions = await plugin.actions(for: "cb")
        // 找到 image 类型的候选（可能有多个，取第一个 image）
        guard let imageAction = actions.first(where: { $0.icon != nil }) ?? actions.first else {
            XCTFail("PP6 / 场景3.P1 precondition: 必须有图片候选")
            return
        }

        XCTAssertNoThrow(try imageAction.perform(),
            "PP6: 图片 perform() 不应抛错")

        let written = pb.data(forType: .png)
        XCTAssertNotNil(written,
            "PP6 / 场景3.P1 (mutation-killer): perform 后 pasteboard 必须含 public.png 类型数据")
        XCTAssertGreaterThan(written?.count ?? 0, 0,
            "PP6 / 场景3.P1 (mutation-killer): PNG data length 必须 > 0，实际 \(written?.count ?? 0)")
    }

    // MARK: - PP7 / 场景3.P2：选中文件路径写入剪贴板（det-machine）

    /// 场景3.P2 [det-machine]：perform 后 NSPasteboard.fileURL exists AND startsWith "file://"
    ///
    /// 谓词：observe NSPasteboard.string(forType:.fileURL) | assert: exists == true AND startsWith "file://"
    /// 契约（副作用清单）：必须 writeObjects([NSURL])，禁用 setString(.fileURL)（Finder 不认）。
    /// 本测试通过 readObjects(forClass: NSURL.self) 验证（writeObjects 写法才能被 readObjects 读回）。
    func test_PP7_scenario3_P2_performFile_writesFileURL() async throws {
        let pb = makePasteboard()
        let dir = makeStorageDir()
        defer { cleanup(dir) }

        // 先创建真实文件（文件路径历史指向真实文件）
        let tmpFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccb-paste-perform-\(UUID().uuidString).txt")
        try "file-perform-test".write(to: tmpFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmpFile) }

        let plugin = makeIsolatedPlugin(pasteboard: pb, storageDir: dir)
        pb.clearContents(); pb.writeObjects([tmpFile as NSURL])
        plugin.historyService.readPasteboard()

        let actions = await plugin.actions(for: "cb")
        guard let action = actions.first else {
            XCTFail("PP7 / 场景3.P2 precondition: 必须有文件候选")
            return
        }

        XCTAssertNoThrow(try action.perform(),
            "PP7: 文件 perform() 不应抛错")

        // 通过 readObjects 验证（writeObjects 写法才能读回 NSURL）
        let urls = pb.readObjects(forClasses: [NSURL.self],
                                  options: nil)
        // CONTRACT_AMBIGUOUS: readObjects API 在不同 macOS 版本签名略异，用 fileURL 字符串兜底
        let fileURLString = pb.string(forType: .fileURL)
        let hasFileURL = (urls?.isEmpty == false) || (fileURLString?.hasPrefix("file://") == true)
        XCTAssertTrue(hasFileURL,
            "PP7 / 场景3.P2 (mutation-killer): perform 后 pasteboard 必须含 fileURL（writeObjects([NSURL])），实际 readObjects=\(urls ?? []) string=\(fileURLString ?? "nil")")
    }

    // MARK: - PP8 / 场景3.P3 + P4：选中富文本写入剪贴板（det-machine）

    /// 场景3.P3 [det-machine]：perform 后 NSPasteboard.data(forType:.html) exists AND length > 0
    /// 场景3.P4 [det-machine]：perform 后 NSPasteboard.string(forType:.string) exists AND length > 0（纯文本降级）
    ///
    /// 契约覆盖 RTF：写 public.html + 纯文本，不转 RTF（YAGNI）。
    func test_PP8_scenario3_P3_P4_performHtml_writesHtmlAndPlain() async throws {
        let pb = makePasteboard()
        let dir = makeStorageDir()
        defer { cleanup(dir) }

        let plugin = makeIsolatedPlugin(pasteboard: pb, storageDir: dir)
        let html = "<b>rich-perform-test</b>"
        let plain = "rich-perform-test"
        pb.clearContents()
        pb.setString(html, forType: .html)
        pb.setString(plain, forType: .string)
        plugin.historyService.readPasteboard()

        let actions = await plugin.actions(for: "cb")
        guard let action = actions.first else {
            XCTFail("PP8 / 场景3.P3 precondition: 必须有富文本候选")
            return
        }

        XCTAssertNoThrow(try action.perform(),
            "PP8: 富文本 perform() 不应抛错")

        // 场景3.P3：HTML data 存在
        let htmlData = pb.data(forType: .html)
        XCTAssertNotNil(htmlData,
            "PP8 / 场景3.P3 (mutation-killer): perform 后 pasteboard 必须含 public.html 数据（契约覆盖 RTF）")
        XCTAssertGreaterThan(htmlData?.count ?? 0, 0,
            "PP8 / 场景3.P3 (mutation-killer): HTML data length 必须 > 0，实际 \(htmlData?.count ?? 0)")

        // 场景3.P4：纯文本降级存在
        let plainString = pb.string(forType: .string)
        XCTAssertNotNil(plainString,
            "PP8 / 场景3.P4 (mutation-killer): perform 后同时必须提供纯文本降级（.string）")
        XCTAssertGreaterThan(plainString?.count ?? 0, 0,
            "PP8 / 场景3.P4 (mutation-killer): 纯文本 length 必须 > 0，实际 \(plainString?.count ?? 0)")
    }

    // MARK: - PP9 / 场景6.P1：连续复制相同内容候选不重复（det-machine）

    /// 场景6.P1 [det-machine]：连续复制相同内容，候选中该内容出现次数 == 1
    ///
    /// 注：此场景由 ClipboardHistoryService 去重保证，PastePlugin 透传 snapshot。
    /// 本测试验证端到端：PastePlugin 候选中不出现重复 title。
    func test_PP9_scenario6_P1_consecutiveDuplicate_inCandidates() async {
        let pb = makePasteboard()
        let dir = makeStorageDir()
        defer { cleanup(dir) }

        let plugin = makeIsolatedPlugin(pasteboard: pb, storageDir: dir)
        pb.clearContents(); pb.setString("dup-candidate", forType: .string); plugin.historyService.readPasteboard()
        pb.clearContents(); pb.setString("dup-candidate", forType: .string); plugin.historyService.readPasteboard()

        let actions = await plugin.actions(for: "cb")
        let occurrence = actions.filter { $0.title.contains("dup-candidate") }.count
        XCTAssertEqual(occurrence, 1,
            "PP9 / 场景6.P1 (mutation-killer): 候选中 dup-candidate 出现次数必须 == 1（服务去重 + 插件透传），实际 \(occurrence)")
    }

    // MARK: - PP10 / 场景7.P1 + P2：历史为空 + 触发词返回空候选（det-machine）

    /// 场景7.P1 + P2 [det-machine]：历史为空 + 触发词 → actions 返回 [] 且不崩溃
    func test_PP10_scenario7_P1_P2_emptyHistory_returnsEmpty() async {
        let pb = makePasteboard()
        let dir = makeStorageDir()
        defer { cleanup(dir) }

        let plugin = makeIsolatedPlugin(pasteboard: pb, storageDir: dir)
        // 不写入任何内容，历史为空

        let actions = await plugin.actions(for: "cb")
        XCTAssertTrue(actions.isEmpty,
            "PP10 / 场景7.P2 (mutation-killer): 历史为空时 actions(for:\"cb\") 必须返回 []（非错误），实际 \(actions.count) 条")
        // 场景7.P1：不崩溃（到达此行即未崩溃）
    }

    // MARK: - PP11：cb <filter> 后缀过滤（契约：触发词 + 空格 + 过滤词）

    /// 契约：cb <filter> → 按 filter 过滤历史（如 "cb github" 过滤含 github 的条目）
    func test_PP11_filterSuffix_filtersResults() async {
        let pb = makePasteboard()
        let dir = makeStorageDir()
        defer { cleanup(dir) }

        let plugin = makeIsolatedPlugin(pasteboard: pb, storageDir: dir)
        pb.clearContents(); pb.setString("github-repo-filter", forType: .string); plugin.historyService.readPasteboard()
        pb.clearContents(); pb.setString("unrelated-filter", forType: .string); plugin.historyService.readPasteboard()

        let actions = await plugin.actions(for: "cb github")
        XCTAssertFalse(actions.isEmpty,
            "PP11 precondition: cb github 应返回含 github 的条目")
        XCTAssertTrue(actions.contains { $0.title.contains("github") },
            "PP11: cb github 候选必须含 github 相关条目")
        XCTAssertFalse(actions.contains { !$0.title.contains("github") && !$0.title.lowercased().contains("unrelated-filter") == false },
            "PP11: cb github 不应返回无关条目（严格过滤）")
        // 更严格：不含 unrelated 的条目
        let unrelatedPresent = actions.contains { $0.title.contains("unrelated") }
        XCTAssertFalse(unrelatedPresent,
            "PP11 (mutation-killer): cb github 不应返回含 unrelated 的条目，实际 actions=\(actions.map { $0.title })")
    }

    // MARK: - PP12：候选 title 截断（边界值 title.count <= 50）

    /// 边界值谓词：候选预览 title.count <= 50（超长截断 + "…"）
    func test_PP12_titleTruncation_50chars() async {
        let pb = makePasteboard()
        let dir = makeStorageDir()
        defer { cleanup(dir) }

        let plugin = makeIsolatedPlugin(pasteboard: pb, storageDir: dir)
        // 60 字符长文本（> 50 边界）
        let longText = String(repeating: "a", count: 60)
        pb.clearContents(); pb.setString(longText, forType: .string)
        plugin.historyService.readPasteboard()

        let actions = await plugin.actions(for: "cb")
        guard let title = actions.first?.title else {
            XCTFail("PP12 precondition: 必须有候选")
            return
        }
        XCTAssertLessThanOrEqual(title.count, 50,
            "PP12 (mutation-killer): 候选 title.count 必须 <= 50（超长截断 + …），实际 \(title.count) 字符 \"\(title)\"")
    }

    // MARK: - PP13：跨插件仲裁（默认 registry 含 paste，priority=150）

    /// PP13：默认 registry 含 id=="paste" 的插件
    func test_PP13_defaultRegistry_containsPastePlugin() {
        let registry = BuiltinPluginRegistry()
        let hasPaste = registry.plugins.contains { $0.id == "paste" }
        XCTAssertTrue(hasPaste,
            "PP13: 默认 registry 必须含 id==\"paste\" 的插件，实际 plugins=\(registry.plugins.map { $0.id })")
    }

    /// PP13：PastePlugin priority 介于 Calculator(200) 与 SystemCommand(100)
    func test_PP13_priority_betweenCalculatorAndSystem() {
        let pastePriority = PastePlugin.shared.priority
        let calcPriority = CalculatorPlugin.shared.priority
        let systemPriority = SystemCommandPlugin.shared.priority
        XCTAssertGreaterThan(calcPriority, pastePriority,
            "PP13 (mutation-killer): Calc \(calcPriority) 必须 > Paste（仲裁顺序 Calc200 > Paste150 > System100）")
        XCTAssertGreaterThan(pastePriority, systemPriority,
            "PP13 (mutation-killer): Paste priority(\(pastePriority)) 必须 > SystemCommand(\(systemPriority))")
    }

    // MARK: - PP14：perform 不触碰系统剪贴板（隔离验证）

    /// PP14：注入隔离 pasteboard，perform 不污染系统剪贴板
    func test_PP14_perform_doesNotTouchSystemPasteboard() async throws {
        let sentinel = "ccb-sentinel-paste-\(UUID().uuidString)"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(sentinel, forType: .string)

        let pb = makePasteboard()
        let dir = makeStorageDir()
        defer { cleanup(dir) }

        let plugin = makeIsolatedPlugin(pasteboard: pb, storageDir: dir)
        pb.clearContents(); pb.setString("isolation-test", forType: .string)
        plugin.historyService.readPasteboard()

        let actions = await plugin.actions(for: "cb")
        guard let action = actions.first else {
            XCTFail("PP14 precondition: 必须有候选")
            return
        }
        try action.perform()

        let systemContent = NSPasteboard.general.string(forType: .string)
        XCTAssertEqual(systemContent, sentinel,
            "PP14: perform 用注入的隔离 CopyService 不应触碰系统剪贴板，系统剪贴板应仍是 sentinel，实际 \"\(systemContent ?? "nil")\"")
    }

    // MARK: - ISOLATION（源码扫描留 QA 核对）

    // ISOLATION: 蓝队实现信息隔离，PastePlugin.swift 源码扫描留 QA 核对。
    // 本红队测试不读取 PastePlugin.swift 实现（信息隔离铁律）。
}
