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

    /// 缓存 secretStore，避免每次 submit 都 probe Keychain（lazy 在 setup() 中初始化一次）
    private lazy var secretStore: SecretStore? = try? SecretStoreFactory.create()

    /// 测试用：可注入 provider 工厂（默认走 ProviderFactory.create）
    /// 重要-2：production 路径不变，仅测试初始化时可替换
    var providerFactoryOverride: ((ProviderConfig, SecretStore) throws -> LauncherProvider)?

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

        // 触发 secretStore lazy 初始化（probe Keychain 一次，选择存储后端）
        _ = secretStore

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

        // task 004 追加：异步安装 bundled plugins（不阻塞 UI）
        Task.detached {
            do {
                try PluginManager.shared.installBundledPlugins()
            } catch {
                NSLog("[Launcher] installBundledPlugins failed: \(error)")
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

    /// 流式返回 AgentEvent，包含 provider/agent/工具执行的全部事件
    func submit(_ query: String) -> AsyncStream<AgentEvent> {
        // 先在 MainActor 上同步读出依赖（不在 detach 后访问 self）
        let config: LauncherConfig
        do {
            config = try LauncherConfig.load()
        } catch {
            return Self.errorStream(.networkFailure(error))
        }
        guard !config.activeProvider.isEmpty,
              let providerConfig = config.providers[config.activeProvider] else {
            return Self.errorStream(.providerNotConfigured)
        }
        guard let store = secretStore else {
            return Self.errorStream(.secretStoreUnavailable)
        }
        let factoryOverride = providerFactoryOverride

        return AsyncStream { continuation in
            // Task.detached 离开 MainActor，避免阻塞 UI 线程（BLOCKER-2 修复）
            let task = Task.detached {
                let provider: LauncherProvider
                do {
                    provider = try (factoryOverride ?? ProviderFactory.create)(providerConfig, store)
                } catch let err as LauncherError {
                    continuation.yield(.error(err))
                    continuation.finish()
                    return
                } catch {
                    continuation.yield(.error(.networkFailure(error)))
                    continuation.finish()
                    return
                }

                // 内置 echo tool stub（task 005 路由层会替换 tools 列表）
                let echoTool = AgentTool(
                    name: "echo",
                    description: "Echo the input text back verbatim",
                    inputSchema: [
                        "type": AnyCodable("object"),
                        "properties": AnyCodable(["text": ["type": "string"]]),
                        "required": AnyCodable(["text"])
                    ]
                )
                let agent = LauncherAgent(
                    provider: provider,
                    tools: [echoTool],
                    model: providerConfig.model,
                    toolExecutor: { name, input in
                        guard name == "echo" else { throw LauncherError.providerNotConfigured }
                        guard let text = input["text"]?.value as? String else { return "" }
                        return text
                    }
                )
                for await event in agent.run(prompt: query, config: .default) {
                    continuation.yield(event)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// 同步生成单事件错误流（用于配置错误前置）
    nonisolated private static func errorStream(_ err: LauncherError) -> AsyncStream<AgentEvent> {
        AsyncStream { continuation in
            continuation.yield(.error(err))
            continuation.finish()
        }
    }
}
