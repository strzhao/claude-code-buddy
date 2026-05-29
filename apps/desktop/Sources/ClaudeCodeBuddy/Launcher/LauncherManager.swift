import AppKit
import Combine

@MainActor
final class LauncherManager: ObservableObject {
    static let shared = LauncherManager()
    @Published private(set) var isVisible = false

    /// 执行阶段（task 008 追加）
    @Published private(set) var stage: LauncherStage = .idle

    /// 最近一次路由的候选列表（task 005 追加，供 LauncherCandidateView 显示）
    @Published private(set) var lastRouteCandidates: [PluginManifest] = []
    /// 最近一次路由选中的候选索引（task 008 改为哨兵 -1）
    @Published private(set) var lastRouteSelectedIndex: Int = -1

    private lazy var launcherWindow: LauncherWindow = makeWindow()
    private var hostingController: LauncherHostingController?
    private var resignKeyObserver: NSObjectProtocol?
    private var isSetup = false

    /// SC-12 防重入标志（独立于 stage，避免测试间 stage 残留影响）
    private var isSubmitting = false

    /// 缓存 secretStore，避免每次 submit 都 probe Keychain（lazy 在 setup() 中初始化一次）
    private lazy var secretStore: SecretStore? = try? SecretStoreFactory.create()

    /// 测试用：可注入 provider 工厂（默认走 ProviderFactory.create）
    /// 重要-2：production 路径不变，仅测试初始化时可替换
    var providerFactoryOverride: ((ProviderConfig, SecretStore) throws -> LauncherProvider)?

    /// 测试用：可注入 router 工厂（默认走 LauncherRouter init）
    /// 红队/蓝队共同约定注入点，用于 SC-13/SC-14 mock candidates
    var routerFactoryOverride: ((PluginManager, LauncherProvider, String) -> LauncherRouter)?

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

    /// 键盘覆盖候选索引（C4 契约）：@MainActor + 空 list no-op + clamp
    /// clamp 到 [0, count-1]；负数 clamp 到 0，超出上界 clamp 到 count-1
    func setSelectedIndex(_ index: Int) {
        guard !lastRouteCandidates.isEmpty else { return }
        let clamped = max(0, min(lastRouteCandidates.count - 1, index))
        lastRouteSelectedIndex = clamped
    }

    /// 流式返回 AgentEvent，包含 provider/agent/工具执行的全部事件
    /// task 008：两阶段 publish 候选（narrowing → candidates+sentinel → routing → AI 完成 → calling → streaming）
    func submit(_ query: String) -> AsyncStream<AgentEvent> {
        // SC-12：防止重复提交（isSubmitting 为 true 时返回空流）
        guard !isSubmitting else {
            return AsyncStream { continuation in continuation.finish() }
        }

        // 先在 MainActor 上同步读出依赖（不在 detach 后访问 self）
        let config: LauncherConfig
        do {
            config = try LauncherConfig.load()
        } catch {
            isSubmitting = false
            stage = .error
            return Self.errorStream(.networkFailure(error))
        }
        guard !config.activeProvider.isEmpty,
              let providerConfig = config.providers[config.activeProvider] else {
            isSubmitting = false
            stage = .error
            return Self.errorStream(.providerNotConfigured)
        }
        guard let store = secretStore else {
            isSubmitting = false
            stage = .error
            return Self.errorStream(.secretStoreUnavailable)
        }
        let factoryOverride = providerFactoryOverride
        let routerOverride = routerFactoryOverride

        // 提交前重置路由状态（在 MainActor 上同步）+ 开始 narrowing
        isSubmitting = true
        lastRouteCandidates = []
        lastRouteSelectedIndex = -1
        stage = .narrowing

        return AsyncStream { continuation in
            // Task.detached 离开 MainActor，避免阻塞 UI 线程（保留 task 003 结构）
            let task = Task.detached {
                let provider: LauncherProvider
                do {
                    provider = try (factoryOverride ?? ProviderFactory.create)(providerConfig, store)
                } catch let err as LauncherError {
                    await MainActor.run {
                        LauncherManager.shared.stage = .error
                        LauncherManager.shared.isSubmitting = false
                    }
                    continuation.yield(.error(err))
                    continuation.finish()
                    return
                } catch {
                    await MainActor.run {
                        LauncherManager.shared.stage = .error
                        LauncherManager.shared.isSubmitting = false
                    }
                    continuation.yield(.error(.networkFailure(error)))
                    continuation.finish()
                    return
                }

                // task 008：两阶段路由
                let router = routerOverride?(PluginManager.shared, provider, providerConfig.model)
                    ?? LauncherRouter(
                        pluginManager: PluginManager.shared,
                        provider: provider,
                        routerModel: providerConfig.model
                    )

                // 第 1 阶段：同步 keyword 缩候选
                let candidates = router.narrowCandidates(query)

                // 第 1 次 @Published 变化：candidates + 哨兵 + 进入 routing
                await MainActor.run {
                    LauncherManager.shared.lastRouteCandidates = candidates
                    LauncherManager.shared.lastRouteSelectedIndex = -1
                    LauncherManager.shared.stage = candidates.isEmpty ? .calling : .routing
                }

                // 第 2 阶段：AI 选 1（降级：candidates 为空直接 directChat）
                let decision: RouteDecision
                if candidates.isEmpty {
                    decision = .directChat
                } else {
                    do {
                        decision = try await router.pickWithAI(query: query, from: candidates)
                    } catch let err as LauncherError {
                        await MainActor.run {
                            LauncherManager.shared.stage = .error
                            LauncherManager.shared.isSubmitting = false
                        }
                        continuation.yield(.error(err))
                        continuation.finish()
                        return
                    } catch {
                        await MainActor.run {
                            LauncherManager.shared.stage = .error
                            LauncherManager.shared.isSubmitting = false
                        }
                        continuation.yield(.error(.networkFailure(error)))
                        continuation.finish()
                        return
                    }
                }

                // 第 2 次 @Published 变化：AI 决策完成，更新 selectedIndex + 进入 calling
                await MainActor.run {
                    if let idx = candidates.firstIndex(where: {
                        if case .withPlugin(let m) = decision { return $0 == m }
                        return false
                    }) {
                        LauncherManager.shared.lastRouteSelectedIndex = idx
                    }
                    // directChat 或 hallucinate fallback 时 selectedIndex 保持 -1（哨兵）
                    LauncherManager.shared.stage = .calling
                }

                // 构造 tools 和 toolExecutor
                let tools: [AgentTool]
                let toolExecutor: (String, [String: AnyCodable]) async throws -> String

                switch decision {
                case .directChat:
                    tools = []
                    toolExecutor = { _, _ in throw LauncherError.providerNotConfigured }

                case .withPlugin(let manifest):
                    tools = [manifest.toAgentTool()]
                    toolExecutor = { name, input in
                        guard name == manifest.name else {
                            throw LauncherError.pluginNotFound(name)
                        }
                        // task 006: trust check（TOFU）
                        let dir = try PluginManager.shared.pluginDir(for: manifest)
                        let executablePath = dir.appending(path: manifest.cmd)
                        let trusted = await TrustStore.shared.checkAndPrompt(
                            manifest, executablePath: executablePath
                        )
                        guard trusted else {
                            throw LauncherError.pluginNotTrusted(manifest.name)
                        }
                        let pluginInput = PluginInput(
                            query: input["query"]?.value as? String ?? query,
                            sessionId: UUID().uuidString,
                            cwd: NSHomeDirectory()
                        )
                        let result = try await PluginExecutor.shared.execute(
                            manifest,
                            pluginDir: dir,
                            input: pluginInput
                        )
                        return result.stdout
                    }
                }

                let agent = LauncherAgent(
                    provider: provider,
                    tools: tools,
                    model: providerConfig.model,
                    toolExecutor: toolExecutor
                )

                var receivedFirstChunk = false
                for await event in agent.run(prompt: query, config: .default) {
                    // 首次 chunk 到达时切换到 streaming 态
                    if !receivedFirstChunk {
                        receivedFirstChunk = true
                        await MainActor.run { LauncherManager.shared.stage = .streaming }
                    }
                    continuation.yield(event)
                    // 流结束事件
                    if case .done = event {
                        await MainActor.run {
                            LauncherManager.shared.stage = .idle
                            LauncherManager.shared.isSubmitting = false
                        }
                    }
                    if case .error = event {
                        await MainActor.run {
                            LauncherManager.shared.stage = .error
                            LauncherManager.shared.isSubmitting = false
                        }
                    }
                }
                // agent.run 完成但未收到 .done（正常流结束）
                await MainActor.run {
                    if LauncherManager.shared.stage == .streaming ||
                       LauncherManager.shared.stage == .calling {
                        LauncherManager.shared.stage = .idle
                    }
                    LauncherManager.shared.isSubmitting = false
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                task.cancel()
                Task { @MainActor in LauncherManager.shared.isSubmitting = false }
            }
        }
    }

    /// 用指定 plugin 直接执行（键盘选中候选后 Enter 触发，跳过 AI 路由阶段）
    /// task 008 / C5 契约：Enter 优先取 selectedIndex 候选
    func submitWithPlugin(_ manifest: PluginManifest, query: String) -> AsyncStream<AgentEvent> {
        let config: LauncherConfig
        do {
            config = try LauncherConfig.load()
        } catch {
            stage = .error
            return Self.errorStream(.networkFailure(error))
        }
        guard !config.activeProvider.isEmpty,
              let providerConfig = config.providers[config.activeProvider] else {
            stage = .error
            return Self.errorStream(.providerNotConfigured)
        }
        guard let store = secretStore else {
            stage = .error
            return Self.errorStream(.secretStoreUnavailable)
        }
        let factoryOverride = providerFactoryOverride

        // 直接进入 calling 阶段（跳过 narrowing/routing）
        stage = .calling

        return AsyncStream { continuation in
            let task = Task.detached {
                let provider: LauncherProvider
                do {
                    provider = try (factoryOverride ?? ProviderFactory.create)(providerConfig, store)
                } catch let err as LauncherError {
                    await MainActor.run { LauncherManager.shared.stage = .error }
                    continuation.yield(.error(err))
                    continuation.finish()
                    return
                } catch {
                    await MainActor.run { LauncherManager.shared.stage = .error }
                    continuation.yield(.error(.networkFailure(error)))
                    continuation.finish()
                    return
                }

                let tools = [manifest.toAgentTool()]
                let toolExecutor: (String, [String: AnyCodable]) async throws -> String = { name, input in
                    guard name == manifest.name else {
                        throw LauncherError.pluginNotFound(name)
                    }
                    let dir = try PluginManager.shared.pluginDir(for: manifest)
                    let executablePath = dir.appending(path: manifest.cmd)
                    let trusted = await TrustStore.shared.checkAndPrompt(
                        manifest, executablePath: executablePath
                    )
                    guard trusted else {
                        throw LauncherError.pluginNotTrusted(manifest.name)
                    }
                    let pluginInput = PluginInput(
                        query: input["query"]?.value as? String ?? query,
                        sessionId: UUID().uuidString,
                        cwd: NSHomeDirectory()
                    )
                    let result = try await PluginExecutor.shared.execute(
                        manifest,
                        pluginDir: dir,
                        input: pluginInput
                    )
                    return result.stdout
                }

                let agent = LauncherAgent(
                    provider: provider,
                    tools: tools,
                    model: providerConfig.model,
                    toolExecutor: toolExecutor
                )

                var receivedFirstChunk = false
                for await event in agent.run(prompt: query, config: .default) {
                    if !receivedFirstChunk {
                        receivedFirstChunk = true
                        await MainActor.run { LauncherManager.shared.stage = .streaming }
                    }
                    continuation.yield(event)
                    if case .done = event {
                        await MainActor.run { LauncherManager.shared.stage = .idle }
                    }
                    if case .error = event {
                        await MainActor.run { LauncherManager.shared.stage = .error }
                    }
                }
                await MainActor.run {
                    if LauncherManager.shared.stage == .streaming ||
                       LauncherManager.shared.stage == .calling {
                        LauncherManager.shared.stage = .idle
                    }
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
