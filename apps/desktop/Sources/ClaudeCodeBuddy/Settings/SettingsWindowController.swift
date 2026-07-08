import AppKit

// MARK: - SettingsWindowController
//
// macOS 原生系统设置风格：标准 NSWindow + NSSplitViewController
// 左 sidebar（插件/热键/AI 配置/皮肤/通用/关于）+ 右 detail 容器。
//
// 窗口契约（契约 1）：
//   - 标准 NSWindow（非 NSPanel），canBecomeKey==true（NSWindow 默认即 true）
//   - styleMask `[.titled, .closable, .minimizable, .resizable]`（无 .fullSizeContentView）
//   - level != .floating
//   - 初始 ~屏幕可见区 75%（兜底 1200×800），minSize 800×560，title "设置"
//
// R1 安全网（暂不删除）：SettingsPanel + sendEvent + SettingsTabClickReceiver
// 保留作降级；本次窗口改用标准 NSWindow，待 QA SC-08 验证 LSUIElement 下点击
// 首次即生效后，后续清理 sendEvent 机制。蓝队本次不删这些文件。
final class SettingsWindowController: NSWindowController {

    /// 持久化 key（契约 4）：值 = `SettingsSection.rawValue`，默认 .skins。
    /// 旧 key `BuddyStoreSelectedTab` 废弃（不迁移，读不到→默认 skins）。
    static let selectedCategoryDefaultsKey = "SettingsSelectedCategory"

    /// 窗口最小尺寸（2026-07-02 上调，避免小窗内容/tab 被遮挡）。
    private static let minWindowSize = NSSize(width: 800, height: 560)

    /// 兜底初始尺寸（无 NSScreen.main 或 visibleFrame 异常时使用）。
    private static let fallbackInitialSize = NSSize(width: 1200, height: 800)

    /// 计算初始窗口尺寸：~ NSScreen.main?.visibleFrame 的 75%（兜底 1200×800）。
    /// 同时夹紧到 >= minWindowSize（避免极端小屏算出小于 minSize 的值）。
    private static func computeInitialSize() -> NSSize {
        let fallback = fallbackInitialSize
        guard let visibleFrame = NSScreen.main?.visibleFrame else { return fallback }
        let width = max(minWindowSize.width, visibleFrame.width * 0.75)
        let height = max(minWindowSize.height, visibleFrame.height * 0.75)
        // 兜底：若算出值异常（<=0），回落 fallback
        guard width > 0, height > 0 else { return fallback }
        return NSSize(width: width, height: height)
    }

    private(set) var splitViewController: SettingsSplitViewController!

    override init(window: NSWindow?) {
        super.init(window: window)
    }

    convenience init() {
        let initialSize = Self.computeInitialSize()
        let window = SettingsWindow(
            contentRect: NSRect(x: 0, y: 0, width: initialSize.width, height: initialSize.height),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: true
        )
        window.title = "设置"
        window.isReleasedWhenClosed = false
        window.minSize = Self.minWindowSize
        // 标准 NSWindow，level 保持默认（.normal），不用 .floating（契约 1）
        // canBecomeKey 标准 NSWindow 默认即 true，无需子类（契约 1）

        let splitVC = SettingsSplitViewController()
        window.contentViewController = splitVC

        // NSSplitViewController 作 contentViewController 后会按 fittingSize 调整 window frame，
        // 需显式 setFrame 锁回契约要求的初始尺寸（动态 ~75% 屏幕，契约 1）。
        window.setFrame(NSRect(x: 0, y: 0, width: initialSize.width, height: initialSize.height), display: false)

        self.init(window: window)
        self.splitViewController = splitVC

        // settings window key 状态（排查用）+ 关闭时切回 .accessory（配合 showSettings 切 .regular）。
        NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main
        ) { _ in
            BuddyLogger.shared.info("settings window didBecomeKey", subsystem: "settings")
        }
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { _ in
            AppDelegate.shared?.restoreActivationPolicy()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

// MARK: - SettingsWindow（R1：LSUIElement key window 兜底）
//
// LSUIElement accessory app 下标准 NSWindow 可能不成为 key window，
// 致 NSTableView 鼠标选中失效（与 patterns/2026-04-19 同根因）。
// sendEvent 拦截 leftMouseDown，hitTest 上溯到 sidebar NSTableView 后
// 手动 selectRowIndexes 兜底选中（→ tableViewSelectionDidChange → detail 切换）。
final class SettingsWindow: NSWindow {

    override func sendEvent(_ event: NSEvent) {
        super.sendEvent(event)
        guard event.type == .leftMouseDown else { return }
        forwardSidebarClick(event)
        forwardDetailClick(event)
    }

    /// LSUIElement 下窗口可能非 key：NSTableView（sidebar）selection 兜底（patterns/2026-04-19 适配）。
    private func forwardSidebarClick(_ event: NSEvent) {
        let location = event.locationInWindow
        guard let hitView = contentView?.hitTest(location) else { return }
        var current: NSView? = hitView
        while let v = current, !(v is NSTableView) {
            current = v.superview
        }
        guard let tableView = current as? NSTableView else { return }
        // imp-82 守卫：仅 sidebar 类 table（设置 sidebar / 插件页左栏）触发 selectRowIndexes 兜底；
        // 排除右栏 SwiftUI List 嵌套的无 identifier NSTableView（避免点 snip 列表误触发左栏选中切换）。
        guard tableView.identifier?.rawValue == "settings.sidebar"
            || tableView.identifier?.rawValue == "settings.plugins.sidebar" else { return }
        let point = tableView.convert(location, from: nil)
        let row = tableView.row(at: point)
        guard row >= 0, row < tableView.numberOfRows else { return }
        guard tableView.selectedRow != row else { return }
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    }

    /// NSCollectionView isSelectable=false（SkinGallery），系统不选中；上溯 responder chain
    /// 找 SettingsTabClickReceiver（SkinGallery.handleClickAt）手动命中（复用旧 SettingsPanel 机制）。
    private func forwardDetailClick(_ event: NSEvent) {
        let location = event.locationInWindow
        guard let hitView = contentView?.hitTest(location) else { return }
        var responder: NSResponder? = hitView
        while let r = responder {
            if let receiver = r as? SettingsTabClickReceiver {
                receiver.handleClickAt(windowPoint: location)
                return
            }
            responder = r.nextResponder
        }
    }
}

// MARK: - SettingsPanel（R1 安全网，保留不删）
//
// 历史：LSUIElement app 拿不到稳定 key window，致 NSCollectionView.didSelectItemsAt 失效。
// 旧解法：SettingsPanel.sendEvent 拦截 leftMouseUp → activeTab.handleClickAt。
//
// 本次窗口改用标准 NSWindow（非 NSPanel），canBecomeKey 默认 true，
// 理论让 isKeyWindow=true，选择机制自动恢复。
// 待 QA SC-08 真机验证「首次点击即生效」通过后，后续 PR 清理 sendEvent；
// 若 SC-08 失败则 sendEvent 持续承担转发。
//
// 本文件保留 class 作降级安全网，新窗口不再引用它。
final class SettingsPanel: NSPanel {
    weak var activeTab: SettingsTabClickReceiver?

    override var canBecomeKey: Bool { true }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseUp, let activeTab {
            activeTab.handleClickAt(windowPoint: event.locationInWindow)
        }
        super.sendEvent(event)
    }
}
