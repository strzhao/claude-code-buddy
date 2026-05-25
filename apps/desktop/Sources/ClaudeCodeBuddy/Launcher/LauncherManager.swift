import AppKit
import Combine

@MainActor
final class LauncherManager: ObservableObject {
    static let shared = LauncherManager()
    @Published private(set) var isVisible = false

    private lazy var launcherWindow: LauncherWindow = makeWindow()
    private var hostingController: LauncherHostingController?
    private var resignKeyObserver: NSObjectProtocol?
    private var isSetup = false

    private init() {}

    private func makeWindow() -> LauncherWindow {
        let w = LauncherWindow()
        let hc = LauncherHostingController(manager: self)
        w.contentViewController = hc
        self.hostingController = hc

        // 失焦自动隐藏
        resignKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: w, queue: .main
        ) { [weak self] _ in self?.hide() }
        return w
    }

    /// AppDelegate 调用：注册全局快捷键 + 探针（仅执行一次）
    func setup() {
        guard !isSetup else { return }
        isSetup = true

        // 触发 launcherWindow lazy 初始化
        _ = launcherWindow

        // 注册全局快捷键
        LauncherHotkey.register { [weak self] in self?.toggle() }

        // 探针
        Task { @MainActor in
            let ok = await LauncherHotkey.probeIfNeeded()
            if !ok {
                // 探针失败 → 弹 KeyboardShortcuts.Recorder（task 005 增强；MVP 仅打日志）
                NSLog("[Launcher] hotkey probe failed — user should reconfigure")
            }
        }
    }

    func show() {
        let w = launcherWindow
        w.centerOnScreen()
        isVisible = true   // 先更新状态，防止 makeKeyAndOrderFront 触发的通知在 isVisible=true 之前 hide()
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    func hide() {
        // 防重入：hidesOnDeactivate=true 已让 NSPanel 在失焦时自动 orderOut，
        // didResignKeyNotification 观察者会再次调用 hide()；用 isVisible 短路防多次状态翻转
        // 重要：先设 isVisible=false，再调 orderOut(nil)，防止 orderOut 同步触发
        // didResignKeyNotification → observer 递归调 hide() 时绕过 guard 导致重复发布
        guard isVisible else { return }
        isVisible = false  // 先更新状态，防止 orderOut 触发的通知重入
        launcherWindow.orderOut(nil)
    }

    func toggle() {
        if isVisible { hide() } else { show() }
    }

    /// 占位 submit（task 003 重写为 AsyncStream<AgentEvent>）
    func submit(_ query: String) async -> AttributedString {
        return AttributedString("echo: \(query)")
    }
}
