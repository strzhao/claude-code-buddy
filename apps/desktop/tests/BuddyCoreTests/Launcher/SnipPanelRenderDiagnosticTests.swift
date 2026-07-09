import XCTest
import SwiftUI
import SnapshotTesting
@testable import BuddyCore

// MARK: - SnipPanelRenderDiagnosticTests
//
// 诊断测试（非验收）：强制渲染 SnipPanelVC 截图，看 SwiftUI 实际渲染是否正常。
// 蓝队因「SwiftUI List+Form 像素 flaky」放弃像素 snapshot 改行为测试 → 渲染类 bug 漏报。
// 本测试用 record: .all 强制生成图（不比对基线，避免 flaky），人工 Read 图诊断。
// XCUITest 等价（SPM 无 XCUITest target 的变通）。
//
// ⚠️ record: .all 在 CI 上永远 fail（每次录制即失败），它是人工诊断工具而非回归 gate。
// 故 CI 跳过（GitHub Actions 设 CI=true），本地保留诊断能力。对齐 SettingsPageSnapshotTests
// 等 snapshot 测试的 isCI 跳过惯例。

@MainActor
final class SnipPanelRenderDiagnosticTests: XCTestCase {

    private var isCI: Bool { ProcessInfo.processInfo.environment["CI"] != nil }

    /// 默认态（空列表 + 「尚无片段」空态）
    func test_renderDefault_emptyState() throws {
        try XCTSkipIf(isCI, "诊断测试（record:.all）跳过 CI，仅本地人工 Read 图诊断")
        let vc = SnipPanelVC()
        assertSnapshot(of: vc.view, as: .image(size: .init(width: 780, height: 540)), record: .all, testName: "snipPanel-default-empty")
    }

    /// 新建表单态（createForm：keyword TextField + content TextEditor + 占位符提示 + 保存/取消按钮）
    ///
    /// 验证 @State editingItem/isCreating 触发 body 重算 → detailPane 切到 createForm。
    /// 旧 @Binding 桥接 SnipPanelState（view 未订阅）→ 点新增无反应（body 不重算，detailPane 停空态）。
    /// 改 @State 后用 init 注入 initialEditingItem+initialIsCreating 直接渲染 createForm（绕开
    /// SwiftUI Button performClick 盲区：SwiftUI Button 不是 NSButton，进程内 click 不触发）。
    func test_renderCreateForm() throws {
        try XCTSkipIf(isCI, "诊断测试（record:.all）跳过 CI，仅本地人工 Read 图诊断")
        let vc = NSHostingController(rootView: SnipPanelView(
            initialEditingItem: SnippetItem(keyword: "", content: ""),
            initialIsCreating: true
        ))
        assertSnapshot(of: vc.view, as: .image(size: .init(width: 780, height: 540)), record: .all, testName: "snipPanel-create-form")
    }

    /// 编辑表单态（editForm：keyword 只读 + content TextEditor + 时间戳 + 删除/取消/保存）
    ///
    /// 诊断「点编辑没反应」：startEdit 后 detailPane 应切 editForm。本测试注入
    /// initialEditingItem + initialIsCreating=false 直接渲染 editForm，看 content TextEditor
    /// 是否可见（排查 Form 布局把 TextEditor 挤窄/隐藏）。
    func test_renderEditForm() throws {
        try XCTSkipIf(isCI, "诊断测试（record:.all）跳过 CI，仅本地人工 Read 图诊断")
        let item = SnippetItem(
            keyword: "sig",
            content: "张三\nzhangsan@example.com",
            created_at: "2026-07-01T00:00:00Z",
            updated_at: "2026-07-08T00:00:00Z"
        )
        let vc = NSHostingController(rootView: SnipPanelView(
            initialEditingItem: item,
            initialIsCreating: false,
            initialEditContent: item.content
        ))
        assertSnapshot(of: vc.view, as: .image(size: .init(width: 780, height: 540)), record: .all, testName: "snipPanel-edit-form")
    }

    // MARK: - Helpers

    private func findButton(titled title: String, in view: NSView) -> NSButton? {
        if let btn = view as? NSButton, btn.title == title { return btn }
        for sub in view.subviews {
            if let found = findButton(titled: title, in: sub) { return found }
        }
        return nil
    }
}
