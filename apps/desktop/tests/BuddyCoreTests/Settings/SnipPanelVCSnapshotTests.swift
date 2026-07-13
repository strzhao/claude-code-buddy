import XCTest
import AppKit
import SwiftUI
@testable import BuddyCore

// MARK: - SnipPanelVCSnapshotTests
//
// 蓝队单测：SnipPanelVC + SnipPanelView 行为验证（T2）。
//
// 注：原本计划像素快照测试（swift-snapshot-testing），但 SwiftUI List+Form 在不同
// macOS 版本/字体渲染下像素级漂移严重（参考 SkinGallerySnapshotTests 的相同问题）。
// 改为结构化行为测试：验证 VC 创建/绑定/占位符展开逻辑，避免跨机器 flaky。
//
// 契约引用：C1（CRUD via SnippetsService）/ C6（占位符展开对齐 snippets.sh）
// 验收场景：AC-SNIPGUI-13（占位符语法提示）/ AC-SNIPGUI-23（预览展开）

@MainActor
final class SnipPanelVCSnapshotTests: XCTestCase {

    private var tmpDir: URL!
    private var snippetsFile: URL!
    private var service: SnippetsService!

    override func setUp() async throws {
        try await super.setUp()
        tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("SnipPanelVC-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        snippetsFile = tmpDir.appendingPathComponent("snippets.json")
        service = SnippetsService(snippetsFile: snippetsFile)
        service.load()
    }

    override func tearDown() async throws {
        service = nil
        try? FileManager.default.removeItem(at: tmpDir)
        try await super.tearDown()
    }

    // MARK: - SnipPanelVC 创建

    func test_snipPanelVC_canInstantiate() {
        let vc = SnipPanelVC()
        XCTAssertNotNil(vc.view, "SnipPanelVC 应能创建 SwiftUI 视图")
    }

    func test_snipPanelVC_isPluginSettingsPanelProvider() {
        let vc = SnipPanelVC()
        let made = vc.makePanelVC()
        // C-PANEL-NEW-INSTANCE（autopilot 2026-07-13）：makePanelVC 每次返回新实例，禁 return self。
        XCTAssertFalse(made === vc, "makePanelVC 禁返回 self（C-PANEL-NEW-INSTANCE）")
        XCTAssertTrue(made is SnipPanelVC, "makePanelVC 应返回 SnipPanelVC 实例")
    }

    func test_snipPanelVC_viewIsNotNil() {
        let vc = SnipPanelVC()
        // 触发 view 加载
        _ = vc.view
        XCTAssertNotNil(vc.view, "SnipPanelVC.view 加载后不应为 nil")
    }

    // MARK: - 占位符展开（AC-SNIPGUI-23 + C6 对齐 snippets.sh）

    func test_expandPlaceholders_dateReplaced() {
        let result = SnippetsService.expandPlaceholders("今天是 {date}")
        // 应含 YYYY-MM-DD（不再含字面 {date}）
        XCTAssertFalse(result.contains("{date}"), "{date} 应被展开")
        let regex = try! NSRegularExpression(pattern: "\\d{4}-\\d{2}-\\d{2}")
        XCTAssertTrue(regex.firstMatch(in: result, range: NSRange(result.startIndex..., in: result)) != nil,
                      "展开后应含 YYYY-MM-DD: \(result)")
    }

    func test_expandPlaceholders_timeReplaced() {
        let result = SnippetsService.expandPlaceholders("时间 {time}")
        XCTAssertFalse(result.contains("{time}"), "{time} 应被展开")
        let regex = try! NSRegularExpression(pattern: "\\d{2}:\\d{2}")
        XCTAssertTrue(regex.firstMatch(in: result, range: NSRange(result.startIndex..., in: result)) != nil,
                      "展开后应含 HH:MM: \(result)")
    }

    func test_expandPlaceholders_clipboardReplaced() {
        // 写剪贴板
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("CLIP_TEST_VALUE", forType: .string)
        let result = SnippetsService.expandPlaceholders("前缀 {clipboard} 后缀")
        XCTAssertEqual(result, "前缀 CLIP_TEST_VALUE 后缀")
    }

    func test_expandPlaceholders_undefinedPreserved() {
        let result = SnippetsService.expandPlaceholders("a {nope} b")
        XCTAssertEqual(result, "a {nope} b", "未定义占位符应原样保留（对齐 snippets.sh）")
    }

    func test_expandPlaceholders_multipleInOneLine() {
        let result = SnippetsService.expandPlaceholders("{date} {time}")
        XCTAssertFalse(result.contains("{"))
        XCTAssertTrue(result.contains(" "))
    }

    // MARK: - 端到端（service → view state）

    // 这里只测 service 行为（view state 由 SwiftUI 管理，难直接驱动）
    // 关键场景：CRUD 后 list 反映
    func test_serviceCRUD_reflectedInList() throws {
        try service.add(keyword: "addr", content: "北京")
        try service.add(keyword: "sig", content: "张三")
        XCTAssertEqual(service.list().map(\.keyword), ["addr", "sig"])

        try service.edit(keyword: "sig", content: "李四")
        XCTAssertEqual(service.list().first(where: { $0.keyword == "sig" })?.content, "李四")

        service.delete(keyword: "addr")
        XCTAssertEqual(service.list().map(\.keyword), ["sig"])
    }

    // MARK: - AppKit GUI CRUD 端到端（stage-4，经 testHook 真实 action 链路）
    //
    // patterns/2026-07-09 testHook 原则：testHook_fillAndSaveCreate 经 createSaveButton.performClick
    // 触发 @objc saveCreate（禁直接调私有方法）。SnipPanelVC 用 .shared，测试用唯一 keyword 隔离 + 清理。

    func test_saveCreate_writesToSharedService() throws {
        let vc = SnipPanelVC()
        _ = vc.view
        let kw = "appkit_save_\(UUID().uuidString.prefix(6))"
        try vc.testHook_fillAndSaveCreate(keyword: kw, content: "hello {date}")

        // 成功保存后 detail 应切回空态
        XCTAssertEqual(vc.testHook_currentDetailMode, .empty,
                       "saveCreate 成功后应切回空态，实际 \(vc.testHook_currentDetailMode)")
        // service.shared 应含该片段
        XCTAssertTrue(SnippetsService.shared.search(kw).contains(where: { $0.keyword == kw }),
                      "saveCreate 后 SnippetsService.shared 应含 keyword「\(kw)」")
        // 清理
        SnippetsService.shared.delete(keyword: kw)
    }

    func test_invalidKeyword_showsFieldError_staysInCreateMode() {
        let vc = SnipPanelVC()
        _ = vc.view
        // 含空格非法 keyword → service.add 抛 .invalidKeyword → saveCreate catch 显示字段错误
        try? vc.testHook_fillAndSaveCreate(keyword: "bad space", content: "x")
        XCTAssertEqual(vc.testHook_currentDetailMode, .create,
                       "非法 keyword 应留在 create 态显示字段错误，实际 \(vc.testHook_currentDetailMode)")
    }
}
