import AppKit
import Combine
import SwiftUI

// MARK: - TrustPrompt（方案 B：自定义 NSWindow + 毛玻璃 + 大尺寸 + SwiftUI 全内容）
//
// 用户真机反馈「布局遮挡 + 整体变大 + 背景毛玻璃」，NSAlert 壳满足不了（默认尺寸小+不透明）。
// 改方案 B：
// - TrustPromptWindow（自定义 NSWindow + NSVisualEffectView .menu 毛玻璃 + .titled 圆角阴影）
// - NSHostingController 包 TrustPromptView 全内容（信任区+依赖区+进度区+按钮区）
// - NSApp.runModal(for:) 替代 NSAlert.runModal（common modes pump 保留 @Published 刷新）
// - 大尺寸：宽 480+（TrustPromptWindow.minWidth），高自适应 fittingSize
// - LSUIElement key window 兜底：TrustPromptWindow.sendEvent + NSApp.activate + makeKeyAndOrderFront
// - 按钮：SwiftUI Button 调 NSApp.stopModal(withCode:.OK/.cancel) → window.orderOut

enum TrustPrompt {
    /// 弹自定义窗口询问用户是否信任此 plugin，**必须在 @MainActor**（NSWindow 需主线程）。
    /// mode-aware：stdin/command 显示命令/路径，prompt 显示 systemPrompt 摘要 + 模型。
    ///
    /// 保留旧入口（无依赖场景，向后兼容）。新逻辑（信任+依赖合并）走 `askUserWithDeps`。
    @MainActor
    static func askUser(plugin: PluginManifest, executablePath: URL) async -> Bool {
        return await askUserWithDeps(plugin: plugin, executablePath: executablePath, hasDeps: false, isAlreadyTrusted: false, missing: [])
    }

    /// M4（弹框内修订 + 方案 B 毛玻璃窗口）：信任 + 依赖合并弹框。
    ///
    /// 弹框内完成（revise 修订，用户反馈「不开新页面」+「整体变大 + 毛玻璃」）：
    /// - TrustPromptWindow（NSVisualEffectView .menu 毛玻璃 + 大尺寸 480 宽 + 圆角阴影）
    /// - NSHostingController 包 TrustPromptView（信任区+依赖区+进度区+按钮区 SwiftUI 全内容）
    /// - 一键安装按钮 action → installer.installAllSync(missing)（同步，绕 Task @MainActor 不 pump modal runloop）
    /// - 「允许并运行」按钮：依赖全装才 enable（Combine sink 监听 installer.statuses 全装 + SwiftUI .disabled 兜底）
    /// - 用户点「允许并运行」→ NSApp.stopModal(.OK) → 返 true（approved）
    /// - 用户点「拒绝」/关闭 → NSApp.stopModal(.cancel) → 返 false
    ///
    /// pump 论证（蓝队 modal runloop 修复，铁证日志实测）：
    /// - NSApp.runModal(for:) 的 modal runloop（NSModalPanelRunLoopMode）**不 pump GCD main queue**
    /// - 所以 Task @MainActor { installAll } 在弹框关闭后才执行（实测 51s 延迟）
    /// - 修复：onInstallAll 同步调 installAllSync，内部 Process.run + while RunLoop.current.run(until:)
    ///   pump modal/common runloop，process 期间 Timer 触发 objectWillChange.send 刷新 SwiftUI
    ///
    /// 参数：
    /// - `hasDeps`：是否有缺失依赖（true 时展示依赖区）
    /// - `isAlreadyTrusted`：已信任重弹时标记（信任区显示「已授权」，按钮文案调整）
    /// - `missing`：缺失依赖列表（供依赖区展示 + 一键安装触发）
    @MainActor
    static func askUserWithDeps(
        plugin: PluginManifest,
        executablePath: URL,
        hasDeps: Bool,
        isAlreadyTrusted: Bool,
        missing: [DependencyStatus]
    ) async -> Bool {
        let brewAvail = hasDeps ? DependencyResolver.shared.brewAvailability() : .available(path: "")
        let autoInstall = DependencySettingsStore.shared.isEnabled
        let installer = DependencyInstaller.shared
        // 初始化 installer.statuses（供 DependencyRow 实时读 isInstalled 状态迁移）
        if hasDeps {
            installer.statuses = missing
        }

        let informative = informativeText(for: plugin, executablePath: executablePath, isAlreadyTrusted: isAlreadyTrusted)

        // 模态结果捕获（按钮回调写入）
        var approved = false

        let view = TrustPromptView(
            pluginName: plugin.name,
            informativeText: informative,
            statuses: missing,
            brewAvailability: brewAvail,
            isAlreadyTrusted: isAlreadyTrusted,
            hasDeps: hasDeps,
            autoInstallEnabled: autoInstall,
            installer: installer,
            onInstallAll: {
                // 立即 loading（不等子进程启动，点击即反馈）
                installer.installingLabel = missing.first?.label ?? missing.first?.check
                installer.progressPhase = "准备安装…"
                BuddyLogger.shared.info("onInstallAll triggered (button click)", subsystem: "plugin", meta: ["plugin": plugin.name])
                // 同步执行（不 Task @MainActor —— modal runloop 不 pump GCD main queue，
                // 实测 Task 在弹框关闭后才执行 51s 延迟；installAllSync 内 while RunLoop.run pump modal/common）
                BuddyLogger.shared.info("onInstallAll installAllSync start", subsystem: "plugin")
                _ = installer.installAllSync(missing)
                BuddyLogger.shared.info("onInstallAll installAllSync done", subsystem: "plugin")
            },
            onCancel: {
                installer.cancel()
            },
            onApprove: {
                BuddyLogger.shared.info("onApprove triggered", subsystem: "plugin", meta: ["plugin": plugin.name])
                // 合并交互：点击允许 → 自动装缺失依赖（installAllSync 同步，弹框内 while pump + 进度刷新）
                // → 装完 approve + 执行；失败/取消则停留弹框（用户看进度区状态可重试或拒绝）
                if !missing.isEmpty {
                    installer.installingLabel = missing.first?.label ?? missing.first?.check
                    installer.progressPhase = "准备安装…"
                    BuddyLogger.shared.info("onApprove installAllSync start", subsystem: "plugin")
                    let result = installer.installAllSync(missing)
                    BuddyLogger.shared.info("onApprove installAllSync done", subsystem: "plugin", meta: ["result": "\(result)"])
                    if result != .success {
                        // 装失败/取消/manualRequired → 不 approve（停留弹框）
                        return
                    }
                }
                approved = true
                NSApp.stopModal(withCode: .OK)
            },
            onDeny: {
                approved = false
                NSApp.stopModal(withCode: .cancel)
            }
        )

        let hosting = NSHostingController(rootView: view)
        // sizingOptions = .preferredContentSize（知识库 nshostingcontroller-sizingoptions-preferredcontentsize）
        hosting.sizingOptions = [.preferredContentSize]

        let window = TrustPromptWindow()
        window.contentViewController = hosting
        // AX id 设在 contentView（NSWindow.accessibilityIdentifier 是方法非属性，走 contentView 标识）
        window.contentView?.setAccessibilityIdentifier("trust-prompt-window")

        // 大尺寸：宽 480+（TrustPromptWindow.minWidth），高自适应 fittingSize
        // fittingSize 由 NSHostingController sizingOptions=.preferredContentSize 计算后自动同步
        let fitting = hosting.view.fittingSize
        let width = max(TrustPromptWindow.minWidth, fitting.width)
        let height = max(fitting.height, 280)
        window.setContentSize(NSSize(width: width, height: height))
        window.minSize = NSSize(width: TrustPromptWindow.minWidth, height: 240)
        window.center()

        // Combine sink 监听 installer.statuses 变化（Q1：装后更新 isInstalled → approveEnabled 重算）
        // SwiftUI .disabled(approveEnabled) 已绑定 installer.statuses（@ObservedObject），
        // 此 sink 仅作日志观测（Q1 调试用），SwiftUI 刷新由 @ObservedObject 自动驱动
        var installCancellable: AnyCancellable?
        if hasDeps {
            // 监听 installer.objectWillChange（任意 @Published 变化：statuses/installingLabel/progressPhase）
            // → 强制 NSHostingView 重绘（modal runloop 不自动 pump SwiftUI @ObservedObject body re-evaluate，
            // 靠 sink + setNeedsDisplay + layoutSubtreeIfNeeded 手动触发 NSHostingController 重绘读最新 @Published）
            installCancellable = installer.objectWillChange
                .receive(on: RunLoop.main)
                .sink { [weak hosting] _ in
                    hosting?.view.needsDisplay = true
                    hosting?.view.layoutSubtreeIfNeeded()
                }
        }

        // 在 LSUIElement app 中让窗口获得焦点（知识库 lsuielement-standard-nswindow-key-window-sendevent-fallback）
        // 顺序：activate 先、makeKeyAndOrderFront 后（macOS 14+ 用无参 activate 新 API）
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)

        // NSApp.runModal：modal runloop（NSModalPanelRunLoopMode）不 pump GCD main queue（Task 不执行），
        // 但 installAllSync 同步执行 + while RunLoop.run pump 期间刷新 @Published/SwiftUI；
        // Combine sink hosting.setNeedsDisplay 强制 NSHostingView 重绘读最新 @Published
        _ = NSApp.runModal(for: window)

        // 关闭窗口（无论 OK/cancel 都 orderOut）
        window.orderOut(nil)

        // 释放 Combine 订阅（runModal 返回后）
        _ = installCancellable  // 显式 retain 到此处，出作用域自动释放
        installCancellable = nil

        return approved
    }

    /// M6 + 方案 B：brew 缺失引导框（场景 6）。
    /// 显示失败状态 + 「打开 brew.sh」按钮（NSWorkspace.open("https://brew.sh")）。
    /// 不执行插件，用户装完 brew 后重试时 brew 可用 → 走正常 installAll。
    ///
    /// 同 TrustPromptWindow 模式（NSVisualEffectView 毛玻璃 + 大尺寸 + SwiftUI 内容）。
    @MainActor
    static func showBrewMissingGuide(missing: [DependencyStatus]) async {
        let depNames = missing.map(\.check).joined(separator: "、")
        let informative = """
        以下依赖需要 Homebrew 才能自动安装：\(depNames)

        请先安装 Homebrew（打开 brew.sh 按提示操作），安装完成后重试。
        """

        let installer = DependencyInstaller.shared
        var openBrewSh = false

        let view = TrustPromptView(
            pluginName: "无法自动安装依赖",
            informativeText: informative,
            statuses: missing,
            brewAvailability: .missing,
            isAlreadyTrusted: false,
            hasDeps: true,
            autoInstallEnabled: true,
            installer: installer,
            onInstallAll: {},  // brew 缺失无一键安装
            onCancel: {},
            onApprove: {
                openBrewSh = true
                NSApp.stopModal(withCode: .OK)
            },
            onDeny: {
                openBrewSh = false
                NSApp.stopModal(withCode: .cancel)
            }
        )
        // 注：brew 缺失场景复用 TrustPromptView 但按钮语义改为「打开 brew.sh / 取消」
        // 视觉一致性优先（同一窗口形态），按钮文案在 view 外不可改 —— 用 approve=打开 brew.sh 语义

        let hosting = NSHostingController(rootView: view)
        hosting.sizingOptions = [.preferredContentSize]

        let window = TrustPromptWindow()
        window.contentViewController = hosting
        window.contentView?.setAccessibilityIdentifier("trust-prompt-window")

        let fitting = hosting.view.fittingSize
        let width = max(TrustPromptWindow.minWidth, fitting.width)
        let height = max(fitting.height, 280)
        window.setContentSize(NSSize(width: width, height: height))
        window.minSize = NSSize(width: TrustPromptWindow.minWidth, height: 240)
        window.center()

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)

        _ = NSApp.runModal(for: window)
        window.orderOut(nil)

        // 场景 6.P2：NSWorkspace.open("https://brew.sh")
        if openBrewSh {
            if let url = URL(string: "https://brew.sh") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    /// 构造 informativeText（mode-aware，复用旧逻辑 + 已信任标记）。
    private static func informativeText(
        for plugin: PluginManifest,
        executablePath: URL,
        isAlreadyTrusted: Bool
    ) -> String {
        let trustNote = isAlreadyTrusted ? "（已授权）\n" : ""
        switch plugin.modeConfig {
        case .stdin(let cfg):
            let argsStr = cfg.args.joined(separator: " ")
            return """
            \(trustNote)\(plugin.description)

            模式: stdin (subprocess)
            命令: \(cfg.cmd) \(argsStr)
            路径: \(executablePath.path)
            """
        case .command(let cfg):
            let argsStr = cfg.args.joined(separator: " ")
            return """
            \(trustNote)\(plugin.description)

            模式: command (direct subprocess，不经 AI)
            命令: \(cfg.cmd) \(argsStr)
            路径: \(executablePath.path)
            """
        case .prompt(let cfg):
            let summary = String(cfg.systemPrompt.prefix(200))
            let truncated = cfg.systemPrompt.count > 200 ? "...（共 \(cfg.systemPrompt.count) 字符）" : ""
            let modelStr = cfg.model ?? "（用 launcher 激活的 provider 模型）"
            return """
            \(trustNote)\(plugin.description)

            模式: prompt (LLM 直接调用)
            模型: \(modelStr)

            System Prompt 摘要:
            \(summary)\(truncated)
            """
        }
    }
}
