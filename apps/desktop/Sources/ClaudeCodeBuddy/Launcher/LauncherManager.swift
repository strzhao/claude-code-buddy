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
    /// 当前 calling/streaming 阶段使用的插件名（供 LauncherStatusFooter 显示）
    @Published private(set) var lastRoutePluginName: String?

    private lazy var launcherWindow: LauncherWindow = makeWindow()
    private var hostingController: LauncherHostingController?
    private var resignKeyObserver: NSObjectProtocol?
    private var isSetup = false

    /// 召唤 launcher 前的前台 app，hide() 时切回去（让光标继续回到原命令行/编辑器）
    private var previousFrontApp: NSRunningApplication?

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

    // MARK: - 即时候选管线（task 011 内置插件）

    /// 即时候选列表（live 阶段：边输入边搜索）
    @Published private(set) var instantActions: [LauncherAction] = []
    /// 即时候选选中索引（哨兵 -1；有候选时置 0）
    @Published private(set) var instantSelectedIndex: Int = -1
    /// 启动失败错误（呈现中文文案，修复 SUGGESTION-2）
    @Published private(set) var lastInstantError: LauncherError?

    /// debounce Task（连续输入时 cancel 旧 Task）
    private var debounceTask: Task<Void, Never>?

    /// 测试注入点（SUGGESTION-1）：覆盖 Registry
    var registryOverride: BuiltinPluginRegistry?
    /// 测试注入点（SUGGESTION-1）：覆盖 debounce 毫秒数（测试置 0 跳过等待）
    var instantDebounceMsOverride: Int?

    private init() {}

    private func makeWindow() -> LauncherWindow {
        let w = LauncherWindow()
        let hc = LauncherHostingController(manager: self)
        w.contentViewController = hc
        self.hostingController = hc
        // 注入毛玻璃背景（C1 契约）：contentViewController 设置后 contentView 已就绪
        w.installVisualEffect()

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

        // task 010 retry 2：停用 builtin-hello 自动安装
        // 原因：示例插件 description 中通用词 (stdin/stdout/markdown/示例) 让 narrow 算法
        // 在大量无关 query 下都把它排到候选首位，干扰真实使用。需要 demo 时用户手动 add 即可。

        // task 011：触发 AppIndex 首次后台扫描（fire-and-forget，不阻塞 UI）
        AppIndex.shared.refreshIfStale(ttl: 0)
    }

    func show() {
        let w = launcherWindow
        // 记录召唤前的前台 app（Terminal/编辑器等），hide() 时切回去恢复光标位置
        // 排除 buddy app 自己，避免重新激活循环
        let myPID = ProcessInfo.processInfo.processIdentifier
        if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != myPID {
            previousFrontApp = front
        }
        // 召唤时清空残留路由状态：避免上次执行的候选行 / 选中项 / footer 文案在新会话开头闪现
        lastRouteCandidates = []
        lastRouteSelectedIndex = -1
        lastRoutePluginName = nil
        stage = .idle
        // 清空即时候选状态（task 011）
        instantActions = []
        instantSelectedIndex = -1
        lastInstantError = nil
        debounceTask?.cancel()
        debounceTask = nil
        // 重置 panel 尺寸到初始小高度，避免上次执行后的大尺寸导致 centerOnScreen y 算偏高
        w.setContentSize(NSSize(width: LauncherConstants.windowWidth, height: LauncherConstants.windowMinHeight))
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
        // 清空即时候选状态（task 011）
        instantActions = []
        instantSelectedIndex = -1
        lastInstantError = nil
        debounceTask?.cancel()
        debounceTask = nil
        launcherWindow.orderOut(nil)
        // 切回召唤前的前台 app（Terminal/编辑器等），光标继续回到原位置
        // 注：必须在 orderOut 后异步执行，否则 macOS 会忽略 activate 调用
        if let prev = previousFrontApp {
            previousFrontApp = nil
            DispatchQueue.main.async {
                prev.activate(options: [])
            }
        }
    }

    func toggle() {
        if isVisible { hide() } else { show() }
    }

    // MARK: - 即时候选管线方法（task 011）

    /// C7 契约：非空 query → debounce 后更新 instantActions；空 query → 立即清空。
    /// 连续输入时 cancel 旧 debounceTask，只有最后一次落地。
    func updateQuery(_ query: String) {
        debounceTask?.cancel()
        guard !query.isEmpty else {
            instantActions = []
            instantSelectedIndex = -1
            return
        }
        let delayMs = instantDebounceMsOverride ?? LauncherConstants.instantDebounceMs
        let registry = registryOverride ?? BuiltinPluginRegistry.shared
        debounceTask = Task { @MainActor [weak self] in
            guard let self else { return }
            if delayMs > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delayMs) * 1_000_000)
            }
            guard !Task.isCancelled else { return }
            let acts = await registry.actions(for: query)
            guard !Task.isCancelled else { return }
            self.instantActions = acts
            self.instantSelectedIndex = acts.isEmpty ? -1 : 0
        }
    }

    /// 键盘导航 instant 候选（C5 契约：instantActions 非空时生效）。
    func moveInstantSelection(up: Bool) {
        guard !instantActions.isEmpty else { return }
        let count = instantActions.count
        if up {
            instantSelectedIndex = instantSelectedIndex <= 0 ? count - 1 : instantSelectedIndex - 1
        } else {
            instantSelectedIndex = instantSelectedIndex >= count - 1 ? 0 : instantSelectedIndex + 1
        }
    }

    /// C5 契约：若有选中的即时 action，执行并返回 true（已消费，不走 AI）；否则返回 false。
    /// 执行失败：设 lastInstantError + stage = .error（C6/C9）。
    @discardableResult
    func performSelectedInstantAction() -> Bool {
        guard instantActions.indices.contains(instantSelectedIndex) else { return false }
        let action = instantActions[instantSelectedIndex]
        clearInstantActions()
        do {
            try action.perform()
            hide()
        } catch let err as LauncherError {
            lastInstantError = err
            stage = .error
        } catch {
            lastInstantError = .appLaunchFailed(error.localizedDescription)
            stage = .error
        }
        return true
    }

    /// 清空即时候选（submit 落回 AI 流前调用，C5 契约）
    func clearInstantActions() {
        debounceTask?.cancel()
        debounceTask = nil
        instantActions = []
        instantSelectedIndex = -1
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
        lastRoutePluginName = nil
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
                    // 记录 calling 阶段的 plugin 名（用于 status footer 显示）
                    if case .withPlugin(let m) = decision {
                        LauncherManager.shared.lastRoutePluginName = m.name
                    } else {
                        LauncherManager.shared.lastRoutePluginName = nil
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
                            LauncherManager.shared.lastRoutePluginName = nil
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
                        LauncherManager.shared.lastRoutePluginName = nil
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

        // 直接进入 calling 阶段（跳过 narrowing/routing），记录 plugin 名
        lastRoutePluginName = manifest.name
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
                        await MainActor.run {
                            LauncherManager.shared.stage = .idle
                            LauncherManager.shared.lastRoutePluginName = nil
                        }
                    }
                    if case .error = event {
                        await MainActor.run { LauncherManager.shared.stage = .error }
                    }
                }
                await MainActor.run {
                    if LauncherManager.shared.stage == .streaming ||
                       LauncherManager.shared.stage == .calling {
                        LauncherManager.shared.stage = .idle
                        LauncherManager.shared.lastRoutePluginName = nil
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
