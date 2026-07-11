import XCTest
import SnapshotTesting
@testable import BuddyCore

// MARK: - SnipPanelRenderDiagnosticTests
//
// 诊断测试（非验收）：强制渲染 SnipPanelVC 截图，看 AppKit 实际渲染是否正常。
// stage-4 后 SnipPanelVC 是纯 AppKit NSViewController（master-detail），不再依赖 SwiftUI。
// 本测试用 record: .all 强制生成图（不比对基线，避免 flaky），人工 Read 图诊断。
//
// ⚠️ record: .all 在 CI 上永远 fail（每次录制即失败），它是人工诊断工具而非回归 gate。
// 故 CI 跳过（GitHub Actions 设 CI=true），本地保留诊断能力。

@MainActor
final class SnipPanelRenderDiagnosticTests: XCTestCase {

    private var isCI: Bool { ProcessInfo.processInfo.environment["CI"] != nil }

    /// 默认态（空列表 + 「选择片段查看或预览，或点新增」空态）
    func test_renderDefault_emptyState() throws {
        try XCTSkipIf(isCI, "诊断测试（record:.all）跳过 CI，仅本地人工 Read 图诊断")
        let vc = SnipPanelVC()
        _ = vc.view
        vc.view.layoutSubtreeIfNeeded()
        assertSnapshot(of: vc.view, as: .image(size: .init(width: 780, height: 540)),
                       record: .all, testName: "snipPanel-default-empty")
    }

    /// 新建表单态（createForm：keyword TextField + content TextEditor + 占位符提示 + 保存/取消按钮）
    ///
    /// stage-4 后用 testHook_startCreate() 触发 @objc startCreate → detail 切 create 态。
    func test_renderCreateForm() throws {
        try XCTSkipIf(isCI, "诊断测试（record:.all）跳过 CI，仅本地人工 Read 图诊断")
        let vc = SnipPanelVC()
        _ = vc.view
        vc.testHook_startCreate()
        vc.view.layoutSubtreeIfNeeded()
        assertSnapshot(of: vc.view, as: .image(size: .init(width: 780, height: 540)),
                       record: .all, testName: "snipPanel-create-form")
    }

    /// 编辑表单态（editForm：keyword 只读 + content TextEditor + 删除/取消/保存）
    ///
    /// 注入一个片段 → selectRow 0 触发 preview → editCurrentPreview 触发 edit 态。
    func test_renderEditForm() throws {
        try XCTSkipIf(isCI, "诊断测试（record:.all）跳过 CI，仅本地人工 Read 图诊断")
        let vc = SnipPanelVC()
        _ = vc.view
        let kw = "render_edit_\(UUID().uuidString.prefix(6))"
        try? SnippetsService.shared.add(keyword: kw, content: "张三\nzhangsan@example.com")
        vc.testHook_reload()
        vc.testHook_selectRow(0)
        // preview 态点「编辑」→ edit 态
        if let editBtn = findButton(titled: "编辑", in: vc.view) {
            editBtn.target?.perform(editBtn.action)
        }
        vc.view.layoutSubtreeIfNeeded()
        assertSnapshot(of: vc.view, as: .image(size: .init(width: 780, height: 540)),
                       record: .all, testName: "snipPanel-edit-form")
        // 清理
        SnippetsService.shared.delete(keyword: kw)
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
