import AppKit
import SwiftUI

// MARK: - SnipPanelVC
//
// snip 专属设置面板 NSHostingController 包装（T2）。
//
// - 绑定 SnippetsService.shared（@MainActor 直驱）
// - 删除二次确认用 NSAlert（modal 弹窗，非候选回选——修旧 task 候选混删除项痛点）
//
// 契约引用：C1 / AC-SNIPGUI-10（删除二次确认）
//
// 注意 NSAlert runModal 阻塞 RunLoop 陷阱（patterns/2026-06-27）：
// 这里在 @MainActor 上下文（用户点击触发）调用 runModal，NSApp.runModal 是
// 用户主动操作的预期阻塞，不影响 GCD Task 调度（非在 Task 内部 runModal）。

@MainActor
final class SnipPanelVC: NSHostingController<SnipPanelView>, PluginSettingsPanelProvider {

    init() {
        // editingItem/isCreating 改为 SnipPanelView 内部 @State（修点新增无反应 bug：
        // 旧 @Binding 桥接 SnipPanelState，view 未订阅 → source 变不触发渲染 → 点新增无反应）。
        let view = SnipPanelView(
            onDeleteRequest: { item in
                Task { @MainActor in
                    SnipPanelVC.confirmDelete(item: item)
                }
            }
        )
        super.init(rootView: view)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // PluginSettingsPanelProvider
    func makePanelVC() -> NSViewController { self }

    // MARK: - 删除二次确认（AC-SNIPGUI-10）

    /// 构造删除确认 NSAlert（test seam：构造不 runModal，in-process 测试可断言按钮文案 + messageText）。
    /// internal static：confirmDelete + in-process 测试共用，确保 alert 构造单一真相源。
    static func presentDeleteAlert(for item: SnippetItem) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "删除片段「\(item.keyword)」？"
        alert.informativeText = "此操作不可恢复，删除后该片段将不再可用。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "确认删除")
        alert.addButton(withTitle: "取消")
        return alert
    }

    /// 处理删除确认 response（确认则 delete；取消 no-op）。
    /// internal static：test seam，in-process 测试可注入 response 验副作用（不 runModal）。
    static func handleDeleteResponse(_ response: NSApplication.ModalResponse, for item: SnippetItem) {
        guard response == .alertFirstButtonReturn else { return }
        SnippetsService.shared.delete(keyword: item.keyword)
        BuddyLogger.shared.info(
            "snippet deleted via GUI",
            subsystem: "snippets",
            meta: ["keyword": item.keyword]
        )
    }

    /// 弹 NSAlert 让用户确认删除。取消不删；确认调 service.delete。
    private static func confirmDelete(item: SnippetItem) {
        let alert = presentDeleteAlert(for: item)
        // NSApp.runModal 在用户主动操作上下文阻塞等待，符合 macOS 习惯
        let response = alert.runModal()
        handleDeleteResponse(response, for: item)
    }
}