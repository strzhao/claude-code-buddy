import AppKit
import XCTest
@testable import BuddyCore

// MARK: - PastePluginTests
//
// 蓝队单元测试：PastePlugin 触发词门控 + 候选构造 + perform 回写。
//
// 覆盖：
//   - 属性契约（id / priority / sectionTitle）
//   - 触发词门控（cb/clipboard/剪贴板/paste + 非触发词）
//   - 候选构造（title 截断 / icon / pluginId / score）
//   - snapshot 过滤（cb <filter>）
//   - perform 回写（文本 copy / 图片 copyImage / 文件 copyFileURL / 富文本 copyRichText）
//
// 隔离：注入命名 pasteboard + 临时目录 + 构造的 historyService（不污染系统剪贴板 / ~/.buddy/）

@MainActor
final class PastePluginTests: XCTestCase {

    /// 测试 fixture：隔离 pasteboard + 临时目录 + historyService + copyService + plugin。
    private struct Fixture {
        let pasteboard: NSPasteboard
        let storageDir: URL
        let historyService: ClipboardHistoryService
        let copyService: CopyService
        let plugin: PastePlugin
    }

    private func makeFixture() -> Fixture {
        let pb = NSPasteboard(name: NSPasteboard.Name("ccb-test-paste-\(UUID().uuidString)"))
        pb.clearContents()
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccb-paste-test-\(UUID().uuidString)", isDirectory: true)
        let history = ClipboardHistoryService(pasteboard: pb, storageDir: tmp)
        let copy = CopyService(pasteboard: pb)
        // 注入 copy + history（不用 .shared，避免污染系统剪贴板）
        let plugin = PastePlugin(historyService: history, copyService: copy)
        return Fixture(pasteboard: pb, storageDir: tmp, historyService: history, copyService: copy, plugin: plugin)
    }

    private func cleanup(_ dir: URL) {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - 属性契约

    /// plugin.id == "paste"
    func test_id_paste() {
        XCTAssertEqual(PastePlugin.shared.id, "paste")
    }

    /// plugin.priority == 150（介于 Calculator 200 与 SystemCommand 100 之间）
    func test_priority_150() {
        XCTAssertEqual(PastePlugin.shared.priority, 150)
    }

    /// plugin.sectionTitle == "剪贴板"
    func test_sectionTitle_剪贴板() {
        XCTAssertEqual(PastePlugin.shared.sectionTitle, "剪贴板")
    }

    /// 遵守 BuiltinPlugin 协议（编译期隐式验证，运行期通过协议访问）
    func test_conformsTo_BuiltinPlugin() {
        let plugin: any BuiltinPlugin = PastePlugin.shared
        XCTAssertEqual(plugin.id, "paste")
        XCTAssertEqual(plugin.priority, 150)
    }

    // MARK: - 触发词门控

    /// 触发词 "cb" → 命中（无历史时返回空候选，非错误）。
    func test_trigger_cb_returns_empty_when_no_history() async {
        let f = makeFixture()
        defer { cleanup(f.storageDir) }

        let actions = await f.plugin.actions(for: "cb")
        XCTAssertEqual(actions.count, 0, "无历史时应返回空候选（边界）")
    }

    /// 触发词 "cb" → 命中且有历史时返回候选。
    func test_trigger_cb_returns_candidates_when_history_present() async {
        let f = makeFixture()
        defer { cleanup(f.storageDir) }

        // 注入历史条目
        f.historyService.append(ClipboardHistoryItem(
            id: "x", type: .text, content: "hello",
            html: nil, imagePath: nil, sourceApp: "com.test",
            ts: ClipboardHistoryService.now(), hash: "helloxxx"
        ))

        let actions = await f.plugin.actions(for: "cb")
        XCTAssertEqual(actions.count, 1)
        XCTAssertEqual(actions.first?.title, "hello")
    }

    /// 触发词 "clipboard" 命中。
    func test_trigger_clipboard_matches() async {
        let f = makeFixture()
        defer { cleanup(f.storageDir) }

        f.historyService.append(ClipboardHistoryItem(
            id: "y", type: .text, content: "test",
            html: nil, imagePath: nil, sourceApp: nil,
            ts: 1, hash: "testxxxx"
        ))

        let actions = await f.plugin.actions(for: "clipboard")
        XCTAssertEqual(actions.count, 1)
    }

    /// 触发词 "剪贴板"（中文）命中。
    func test_trigger_chinese_matches() async {
        let f = makeFixture()
        defer { cleanup(f.storageDir) }

        f.historyService.append(ClipboardHistoryItem(
            id: "z", type: .text, content: "中文",
            html: nil, imagePath: nil, sourceApp: nil,
            ts: 1, hash: "chinesex"
        ))

        let actions = await f.plugin.actions(for: "剪贴板")
        XCTAssertEqual(actions.count, 1)
    }

    /// 触发词 "paste" 命中。
    func test_trigger_paste_matches() async {
        let f = makeFixture()
        defer { cleanup(f.storageDir) }

        f.historyService.append(ClipboardHistoryItem(
            id: "p", type: .text, content: "paste-test",
            html: nil, imagePath: nil, sourceApp: nil,
            ts: 1, hash: "pastexxx"
        ))

        let actions = await f.plugin.actions(for: "paste")
        XCTAssertEqual(actions.count, 1)
    }

    /// 非触发词 "abc" → 不命中，返回 []。
    func test_non_trigger_returns_empty() async {
        let f = makeFixture()
        defer { cleanup(f.storageDir) }

        f.historyService.append(ClipboardHistoryItem(
            id: "a", type: .text, content: "abc",
            html: nil, imagePath: nil, sourceApp: nil,
            ts: 1, hash: "abcxxxxx"
        ))

        let actions = await f.plugin.actions(for: "abc")
        XCTAssertEqual(actions.count, 0, "非触发词应返回 []")
    }

    /// 空 query → 返回 []（边界）。
    func test_empty_query_returns_empty() async {
        let f = makeFixture()
        defer { cleanup(f.storageDir) }

        let actions = await f.plugin.actions(for: "")
        XCTAssertEqual(actions.count, 0)
    }

    /// 大写触发词 "CB" 命中（大小写不敏感）。
    func test_trigger_uppercase_matches() async {
        let f = makeFixture()
        defer { cleanup(f.storageDir) }

        f.historyService.append(ClipboardHistoryItem(
            id: "u", type: .text, content: "upper",
            html: nil, imagePath: nil, sourceApp: nil,
            ts: 1, hash: "upperxxx"
        ))

        let actions = await f.plugin.actions(for: "CB")
        XCTAssertEqual(actions.count, 1)
    }

    // MARK: - cb <filter> 过滤

    /// "cb github" → 过滤含 github 的条目。
    func test_cb_with_filter_filters_results() async {
        let f = makeFixture()
        defer { cleanup(f.storageDir) }

        f.historyService.append(ClipboardHistoryItem(
            id: "g", type: .text, content: "github repo",
            html: nil, imagePath: nil, sourceApp: nil,
            ts: 1, hash: "githubhx"
        ))
        f.historyService.append(ClipboardHistoryItem(
            id: "s", type: .text, content: "slack msg",
            html: nil, imagePath: nil, sourceApp: nil,
            ts: 2, hash: "slackhxx"
        ))

        let actions = await f.plugin.actions(for: "cb github")
        XCTAssertEqual(actions.count, 1)
        XCTAssertEqual(actions.first?.title, "github repo")
    }

    /// "cb nonexistent" → 过滤后无匹配。
    func test_cb_with_filter_no_match_returns_empty() async {
        let f = makeFixture()
        defer { cleanup(f.storageDir) }

        f.historyService.append(ClipboardHistoryItem(
            id: "a", type: .text, content: "alpha",
            html: nil, imagePath: nil, sourceApp: nil,
            ts: 1, hash: "alphahxx"
        ))

        let actions = await f.plugin.actions(for: "cb zzz")
        XCTAssertEqual(actions.count, 0)
    }

    // MARK: - 候选构造

    /// 长文本 title 截断到 50 字符 + "…"。
    func test_long_text_title_truncated() async {
        let f = makeFixture()
        defer { cleanup(f.storageDir) }

        let long = String(repeating: "a", count: 200)
        f.historyService.append(ClipboardHistoryItem(
            id: "long", type: .text, content: long,
            html: nil, imagePath: nil, sourceApp: nil,
            ts: 1, hash: "longhash"
        ))

        let actions = await f.plugin.actions(for: "cb")
        XCTAssertEqual(actions.count, 1)
        let title = actions.first?.title ?? ""
        XCTAssertLessThanOrEqual(title.count, PastePlugin.previewLimit + 1, "title 应截断到 ≤ limit + 省略号")
        XCTAssertTrue(title.hasSuffix("…"), "title 应以 … 结尾")
    }

    /// 候选 pluginId == "paste"。
    func test_candidate_pluginId_paste() async {
        let f = makeFixture()
        defer { cleanup(f.storageDir) }

        f.historyService.append(ClipboardHistoryItem(
            id: "x", type: .text, content: "hello",
            html: nil, imagePath: nil, sourceApp: nil,
            ts: 1, hash: "helloxxx"
        ))

        let actions = await f.plugin.actions(for: "cb")
        XCTAssertEqual(actions.first?.pluginId, "paste")
    }

    /// 候选 score 按 index 降序（越前越新 score 越高）。
    func test_candidate_score_descending_by_index() async {
        let f = makeFixture()
        defer { cleanup(f.storageDir) }

        // append 顺序：newer 先（队首）
        f.historyService.append(ClipboardHistoryItem(
            id: "new", type: .text, content: "newer",
            html: nil, imagePath: nil, sourceApp: nil,
            ts: 100, hash: "newerxxx"
        ))
        f.historyService.append(ClipboardHistoryItem(
            id: "old", type: .text, content: "older",
            html: nil, imagePath: nil, sourceApp: nil,
            ts: 1, hash: "olderxxx"
        ))

        let actions = await f.plugin.actions(for: "cb")
        XCTAssertEqual(actions.count, 2)
        XCTAssertGreaterThanOrEqual(actions[0].score, actions[1].score, "队首 score 应 ≥ 队尾")
    }

    /// 不同类型候选 subtitle 含类型标识。
    func test_subtitle_contains_type_label() async {
        let f = makeFixture()
        defer { cleanup(f.storageDir) }

        f.historyService.append(ClipboardHistoryItem(
            id: "t", type: .text, content: "text",
            html: nil, imagePath: nil, sourceApp: nil,
            ts: 1, hash: "textxxxx"
        ))
        f.historyService.append(ClipboardHistoryItem(
            id: "h", type: .html, content: "plain",
            html: "<b>plain</b>", imagePath: nil, sourceApp: nil,
            ts: 2, hash: "plainxxx"
        ))

        let actions = await f.plugin.actions(for: "cb")
        XCTAssertEqual(actions.count, 2)
        let subtitles = actions.compactMap { $0.subtitle }
        XCTAssertTrue(subtitles.contains { $0.contains("文本") }, "应含文本类型标识")
        XCTAssertTrue(subtitles.contains { $0.contains("富文本") }, "应含富文本类型标识")
    }

    // MARK: - perform 回写

    /// perform 文本条目 → 写入 pasteboard.string。
    func test_perform_text_writes_pasteboard() async throws {
        let f = makeFixture()
        defer { cleanup(f.storageDir) }

        f.historyService.append(ClipboardHistoryItem(
            id: "t", type: .text, content: "copy me",
            html: nil, imagePath: nil, sourceApp: nil,
            ts: 1, hash: "copymexx"
        ))

        let actions = await f.plugin.actions(for: "cb")
        guard let action = actions.first else {
            XCTFail("precondition: 必须有候选")
            return
        }

        // perform 前清空 pasteboard 确保验证
        f.pasteboard.clearContents()
        try action.perform()

        XCTAssertEqual(f.pasteboard.string(forType: .string), "copy me")
    }

    /// perform 文件路径条目 → writeObjects([NSURL])。
    func test_perform_file_writes_file_url() async throws {
        let f = makeFixture()
        defer { cleanup(f.storageDir) }

        // 确保存储目录存在（service.init 不创建，write 前需手动）
        try FileManager.default.createDirectory(at: f.storageDir, withIntermediateDirectories: true)

        // 创建真实临时文件
        let tmpFile = f.storageDir.appendingPathComponent("perf-file.txt")
        try "content".data(using: .utf8)?.write(to: tmpFile)

        f.historyService.append(ClipboardHistoryItem(
            id: "f", type: .file, content: tmpFile.path,
            html: nil, imagePath: nil, sourceApp: nil,
            ts: 1, hash: "filexxxx"
        ))

        let actions = await f.plugin.actions(for: "cb")
        guard let action = actions.first else {
            XCTFail("precondition")
            return
        }

        f.pasteboard.clearContents()
        try action.perform()

        // 验证 writeObjects 写入：读回 NSURL
        let urls = f.pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL]
        XCTAssertEqual(urls?.first?.path, tmpFile.path)
    }

    /// perform 富文本条目 → 同时写 html + plain。
    func test_perform_html_writes_html_and_plain() async throws {
        let f = makeFixture()
        defer { cleanup(f.storageDir) }

        f.historyService.append(ClipboardHistoryItem(
            id: "h", type: .html, content: "plain",
            html: "<b>plain</b>", imagePath: nil, sourceApp: nil,
            ts: 1, hash: "plainxxx"
        ))

        let actions = await f.plugin.actions(for: "cb")
        guard let action = actions.first else {
            XCTFail("precondition")
            return
        }

        f.pasteboard.clearContents()
        try action.perform()

        XCTAssertEqual(f.pasteboard.string(forType: .html), "<b>plain</b>")
        XCTAssertEqual(f.pasteboard.string(forType: .string), "plain")
    }

    /// perform 图片条目 → 写 PNG data。
    func test_perform_image_writes_png() async throws {
        let f = makeFixture()
        defer { cleanup(f.storageDir) }

        // 确保存储目录存在
        try FileManager.default.createDirectory(at: f.storageDir, withIntermediateDirectories: true)

        // 构造 PNG 并写入临时图片路径
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 1, pixelsHigh: 1,
            bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        )
        guard let rep = rep else {
            XCTFail("precondition: NSBitmapImageRep 创建失败")
            return
        }
        rep.setColor(NSColor(red: 0, green: 1, blue: 0, alpha: 1), atX: 0, y: 0)
        guard let pngData = rep.representation(using: .png, properties: [:]) else {
            XCTFail("precondition: PNG 编码失败")
            return
        }

        let imgPath = f.storageDir.appendingPathComponent("test.png")
        try pngData.write(to: imgPath)

        f.historyService.append(ClipboardHistoryItem(
            id: "i", type: .image, content: "",
            html: nil, imagePath: imgPath.path, sourceApp: nil,
            ts: 1, hash: "imagexxx"
        ))

        let actions = await f.plugin.actions(for: "cb")
        guard let action = actions.first else {
            XCTFail("precondition")
            return
        }

        f.pasteboard.clearContents()
        try action.perform()

        let written = f.pasteboard.data(forType: .png)
        XCTAssertNotNil(written, "应写入 PNG 数据")
        XCTAssertEqual(written, pngData)
    }

    // MARK: - Registry 集成（验证注册）

    /// 默认 registry 含 PastePlugin。
    func test_default_registry_contains_paste_plugin() {
        let registry = BuiltinPluginRegistry()
        let has = registry.plugins.contains { $0.id == "paste" }
        XCTAssertTrue(has, "默认 registry 必须含 PastePlugin")
    }

    /// reset() 后默认列表仍含 PastePlugin（防 flaky）。
    func test_reset_still_contains_paste_plugin() {
        BuiltinPluginRegistry.shared.reset()
        let has = BuiltinPluginRegistry.shared.plugins.contains { $0.id == "paste" }
        XCTAssertTrue(has, "reset 后默认列表必须仍含 PastePlugin")
    }

    /// 默认 registry 仲裁顺序：Calculator(200) > Paste(150) > SystemCommand(100)。
    func test_priority_ordering_calc_above_paste_above_system() {
        let calc = CalculatorPlugin.shared.priority
        let paste = PastePlugin.shared.priority
        let system = SystemCommandPlugin.shared.priority
        XCTAssertGreaterThan(calc, paste, "Calculator priority 应 > Paste")
        XCTAssertGreaterThan(paste, system, "Paste priority 应 > SystemCommand")
    }
}
