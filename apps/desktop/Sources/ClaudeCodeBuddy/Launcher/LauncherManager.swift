import AppKit
import Combine

/// 候选导航活动区（方案 B 分区渲染，C2/C5）。
/// 决定 ↑↓ 跨区语义与 Enter 派发目标（submit 按 activeCandidateZone 分流）。
enum CandidateZone: Equatable {
    case pluginCandidates   // post-exec 候选输出通道区（隔离其他三区）
    case commandRoute       // command 路由候选区（typing 阶段填充，用户安装的 command 插件）
    case instant            // 内置即时候选区（AppLauncher/Calculator/SystemCommand 等）
    case aiRoute            // AI 路由候选兜底（lastRouteCandidates）
}

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

    /// 当前激活的插件名（chip 水印显示用）：仅在 calling/streaming 阶段非 nil
    /// 派生自 stage + lastRoutePluginName（chip 测试通过此属性观察）
    @Published private(set) var activePluginName: String?

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

    /// 测试用：可注入 LauncherConfig（默认走 LauncherConfig.load() 读 ~/.buddy/launcher.json）。
    /// 必要性：submit/agent 路径依赖全局配置文件，而开发机常有真实配置，会让「无 provider」类
    /// 测试读到真实 provider 而非走 providerNotConfigured 路径（环境相关 flaky）。测试可注入
    /// .empty 强制无配置、或注入指定配置，使行为与机器上的 ~/.buddy 解耦。
    var configOverride: LauncherConfig?

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

    // MARK: - command 路由候选状态（方案 B 分区渲染，C1/C2/C5）

    /// command 路由候选列表（typing 阶段填充的 command-mode 子集，C1）。
    /// 与 submit 期填充的 lastRouteCandidates 解耦，避免污染路由决策。
    @Published private(set) var commandRouteCandidates: [PluginManifest] = []
    /// command 路由候选选中索引（哨兵 -1；非空时默认 0，C2 command 优先）。
    @Published private(set) var commandRouteSelectedIndex: Int = -1
    /// 当前导航活动区（C2/C5）：决定 ↑↓ 跨区语义与 Enter 派发目标。
    @Published private(set) var activeCandidateZone: CandidateZone = .instant

    /// debounce Task（连续输入时 cancel 旧 Task）
    private var debounceTask: Task<Void, Never>?

    /// 测试注入点（SUGGESTION-1）：覆盖 Registry
    var registryOverride: BuiltinPluginRegistry?
    /// 测试注入点（SUGGESTION-1）：覆盖 debounce 毫秒数（测试置 0 跳过等待）
    var instantDebounceMsOverride: Int?
    /// 测试注入点（I1）：覆盖 updateQuery 读取的 plugins 源（优先于 PluginManager.shared.list()）。
    /// 单测可注入 qzh manifest 构造「command + app 双命中」，不依赖真装插件/真 /Applications。
    var pluginsOverride: [PluginManifest]?
    /// 测试注入点（I6）：覆盖 submitCommandDirect 使用的 StdinExecutor（默认 .shared）。
    /// 红队 spy dispatch 调用次数，禁真起进程（C11 spy seam）。
    var stdinExecutorOverride: StdinExecutor?
    /// 测试注入点：覆盖 submitCommandDirect / submitWithCandidate 使用的 PluginManager（默认 .shared）。
    /// 单测可注入指向 tmpDir 的 PluginManager，不依赖 ~/.buddy/launcher-plugins 目录存在。
    var pluginManagerOverride: PluginManager?

    /// Combine 订阅持有（activePluginName 自动同步）
    private var syncCancellables = Set<AnyCancellable>()

    private init() {
        // 自动同步 activePluginName：stage 或 lastRoutePluginName 变化时重算
        Publishers.CombineLatest($stage, $lastRoutePluginName)
            .map { stage, name -> String? in
                guard stage == .calling || stage == .streaming else { return nil }
                return name
            }
            .assign(to: \.activePluginName, on: self)
            .store(in: &syncCancellables)
    }

    #if DEBUG
    /// Test seam: 直接驱动 chip / 候选行隐藏路径所需的派生状态。
    /// 仅限 @testable XCTest 使用；生产代码绝不可调用。
    func _testSetActivePluginState(stage: LauncherStage, name: String?) {
        self.stage = stage
        self.lastRoutePluginName = name
    }
    #endif

    /// 测试用：重置共享单例的提交相关状态（isSubmitting + stage）。
    /// LauncherManager.shared 是跨测试共享的单例：submit() 入口有 `isSubmitting` 再入守卫
    /// （为 true 时返回空流），且 `stage` 会被前序 submit 留成 .error/.calling 等。这些状态
    /// 跨测试泄漏会让后续测试拿到空流或读到错误的初始 stage（顺序相关 flaky，CI 上尤其暴露）。
    /// submit/stage 相关测试可在 setUp 或开头调用本方法清状态。
    func resetSubmittingStateForTesting() {
        isSubmitting = false
        stage = .idle
    }

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

        // T6 迁移：一次性幂等清理旧版（⌘⇧Space 默认时期）可能残留的不兼容 UserDefaults 值
        // 必须在 register 之前执行，确保库用新 default Ctrl+Space 重注册
        LauncherHotkey.migrateLegacyIfNeeded()

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

        // task 006: 注入 MarketHUD.shared（生产唯一注入点；同实例多次调用 no-op）
        MarketplaceManager.shared.configureHUD(MarketHUD.shared)

        // task 003 (market) 切换：MarketplaceManager 替换 installBundledPlugins
        // 顺序：先 migrateLegacy 老用户路径 → seedFromBundle 离线 fallback → syncFromRemote 后台拉
        Task.detached {
            do {
                try MarketplaceManager.shared.migrateLegacy()
                try await MarketplaceManager.shared.seedFromBundle()
                await MarketplaceManager.shared.syncFromRemote()
            } catch {
                NSLog("[Launcher] marketplace setup failed: \(error)")
            }
        }

        // task 011：触发 AppIndex 首次后台扫描（fire-and-forget，不阻塞 UI）
        AppIndex.shared.refreshIfStale(ttl: 0)

        // 剪贴板历史：常驻 Timer 监听（幂等，不阻塞 UI）
        ClipboardHistoryService.shared.startMonitoring()
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
        // 清空 command 路由候选状态（C1 复位点）
        commandRouteCandidates = []
        commandRouteSelectedIndex = -1
        activeCandidateZone = .instant
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
        // 清空 command 路由候选状态（C1 复位点）
        commandRouteCandidates = []
        commandRouteSelectedIndex = -1
        activeCandidateZone = .instant
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
    /// 方案 B（C1/C2）：同时填 command 路由候选（command-mode 子集），command 优先选中。
    func updateQuery(_ query: String) {
        debounceTask?.cancel()
        guard !query.isEmpty else {
            instantActions = []
            instantSelectedIndex = -1
            // 清空输入 → chip 立即消失
            lastRoutePluginName = nil
            // 清空 command 路由候选状态（C1 复位点）
            commandRouteCandidates = []
            commandRouteSelectedIndex = -1
            activeCandidateZone = .instant
            return
        }
        // 同步 narrow：让 chip 在用户输入命中 keyword 瞬间就显示（不等 submit）
        // I1 seam：pluginsOverride 优先于 PluginManager.shared.list()
        let plugins = pluginsOverride ?? ((try? PluginManager.shared.list()) ?? [])
        let narrowed = LauncherRouter.narrowCandidates(query: query, plugins: plugins)
        lastRoutePluginName = narrowed.first?.name

        // C1/C9：command 路由候选 = narrowed 的 command-mode 子集
        commandRouteCandidates = narrowed.filter { manifest in
            if case .command = manifest.modeConfig { return true }
            return false
        }
        commandRouteSelectedIndex = commandRouteCandidates.isEmpty ? -1 : 0

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
            // C2/I5：不再用 -1 钉死 instantSelectedIndex。
            // command 区非空时 command 优先选中（activeCandidateZone=.commandRoute），
            // instant 区可见但不预选（instantSelectedIndex 仍按候选存在性置 0，
            // 由 activeCandidateZone 决定 Enter 实际派发目标，避免跨区 off-by-one）。
            self.instantSelectedIndex = acts.isEmpty ? -1 : 0
            // C2：默认活动区 = command 优先（非空）否则 instant
            self.activeCandidateZone = self.commandRouteCandidates.isEmpty ? .instant : .commandRoute
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

    // MARK: - command 路由候选导航（C5 四态矩阵）

    /// command 路由候选区内环形导航（C5：单区内环形，跨区由 LauncherInputView 边界处理）。
    func moveCommandRouteSelection(up: Bool) {
        guard !commandRouteCandidates.isEmpty else { return }
        let count = commandRouteCandidates.count
        if up {
            commandRouteSelectedIndex = commandRouteSelectedIndex <= 0 ? count - 1 : commandRouteSelectedIndex - 1
        } else {
            commandRouteSelectedIndex = commandRouteSelectedIndex >= count - 1 ? 0 : commandRouteSelectedIndex + 1
        }
    }

    /// 键盘覆盖 command 路由候选索引（C5）：clamp 到 [0, count-1]，空 list no-op。
    func setCommandRouteSelectedIndex(_ index: Int) {
        guard !commandRouteCandidates.isEmpty else { return }
        let clamped = max(0, min(commandRouteCandidates.count - 1, index))
        commandRouteSelectedIndex = clamped
    }

    /// 切换当前导航活动区（C2/C5）：LauncherInputView 跨区边界处理时调用。
    func setActiveCandidateZone(_ zone: CandidateZone) {
        activeCandidateZone = zone
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
    /// 方案 B（C1 复位点）：同时清 command 路由候选状态。
    func clearInstantActions() {
        debounceTask?.cancel()
        debounceTask = nil
        instantActions = []
        instantSelectedIndex = -1
        commandRouteCandidates = []
        commandRouteSelectedIndex = -1
        activeCandidateZone = .instant
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
            config = try configOverride ?? LauncherConfig.load()
        } catch {
            isSubmitting = false
            stage = .error
            return Self.errorStream(.networkFailure(error))
        }
        // provider 可选：command mode（零 LLM）不需 provider；directChat/stdin/prompt 需要。
        // command 短路在 detached 内独立处理（用户无 LLM provider 也能用 qr 等命令插件）。
        let providerConfig = config.activeProvider.isEmpty
            ? nil
            : config.providers[config.activeProvider]
        let store = secretStore
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
                // command mode 短路（零 LLM，不需 provider）：QR 等确定性命令插件在用户无 LLM provider 时也应可用。
                // 静态 narrowCandidates 判断唯一/strong 命中 + command mode → 直接执行，bypass provider/router/agent loop。
                let scored = LauncherRouter.narrowCandidatesScored(
                    query: query,
                    plugins: (try? PluginManager.shared.list()) ?? []
                )
                let topManifest = scored.first?.manifest
                let topIsCommand: Bool = {
                    guard case .command = topManifest?.modeConfig else { return false }
                    return true
                }()
                let isShortCircuit = !scored.isEmpty && (
                    scored.count == 1 || (scored.first?.score ?? 0) >= LauncherConstants.routerSkipScore
                )
                if isShortCircuit && topIsCommand, let manifest = topManifest,
                   let dir = try? PluginManager.shared.pluginDir(for: manifest) {
                    await MainActor.run {
                        LauncherManager.shared.lastRouteCandidates = scored.map(\.manifest)
                        LauncherManager.shared.lastRouteSelectedIndex = 0
                        LauncherManager.shared.lastRoutePluginName = manifest.name
                        LauncherManager.shared.stage = .calling
                    }
                    let executablePath = dir.appending(path: manifest.cmd)
                    let trusted = await TrustStore.shared.checkAndPrompt(manifest, executablePath: executablePath)
                    guard trusted else {
                        continuation.yield(.error(.pluginNotTrusted(manifest.name)))
                        continuation.finish()
                        await MainActor.run {
                            LauncherManager.shared.stage = .idle
                            LauncherManager.shared.isSubmitting = false
                        }
                        return
                    }
                    let strippedQuery = Self.stripKeywordPrefix(query, manifest: manifest)
                    let pluginInput = PluginInput(query: strippedQuery, sessionId: UUID().uuidString, cwd: NSHomeDirectory())
                    await MainActor.run { LauncherManager.shared.stage = .streaming }
                    do {
                        let result = try await PluginDispatcher(stdinExecutor: .shared).execute(manifest, pluginDir: dir, input: pluginInput)
                        if !result.stdout.isEmpty { continuation.yield(.text(result.stdout)) }
                        if let imageData = result.image { continuation.yield(.image(imageData)) }
                        if let candidates = result.candidates { continuation.yield(.candidates(candidates)) }
                        if result.exitCode != 0 && result.stdout.isEmpty && result.image == nil && result.candidates == nil {
                            continuation.yield(.text(result.stderr.isEmpty ? "未生成图片" : result.stderr))
                        }
                        continuation.yield(.done(reason: "end_turn"))
                    } catch let err as LauncherError {
                        continuation.yield(.error(err))
                    } catch {
                        continuation.yield(.error(.networkFailure(error)))
                    }
                    await MainActor.run {
                        LauncherManager.shared.stage = .idle
                        LauncherManager.shared.isSubmitting = false
                    }
                    continuation.finish()
                    return
                }

                // 非 command 短路：需 provider（directChat/aiSelect/stdin/prompt）
                guard let providerConfig = providerConfig, let store = store else {
                    await MainActor.run {
                        LauncherManager.shared.stage = .error
                        LauncherManager.shared.isSubmitting = false
                    }
                    continuation.yield(.error(.providerNotConfigured))
                    continuation.finish()
                    return
                }
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
                var tools: [AgentTool] = []
                var toolExecutor: (String, [String: AnyCodable]) async throws -> String = { _, _ in throw LauncherError.providerNotConfigured }

                switch decision {
                case .directChat:
                    // 默认流：单轮流式 + Buddy system prompt + 框架 meta tools（render-only 按钮）。
                    // 不走 LauncherAgent 的 execute-loop —— attach_action 是「声明按钮」非「执行动作」，
                    // 用 PromptExecutor 单轮路径收集 .action 后随文本一并展示。
                    let promptExecutor = PromptExecutor(provider: provider, activeProviderModel: providerConfig.model)
                    let cfg = PromptConfig(
                        systemPrompt: DefaultAgentPrompt.system,
                        maxIterations: 1,
                        model: nil,
                        autoCopyToClipboard: false
                    )
                    await MainActor.run { LauncherManager.shared.stage = .streaming }
                    do {
                        let result = try await promptExecutor.execute(query: query, config: cfg)
                        if result.exitCode == 0 {
                            continuation.yield(.text(result.stdout))
                            for action in result.actions {
                                continuation.yield(.action(action))
                            }
                        } else {
                            continuation.yield(.text(result.stderr))
                        }
                        continuation.yield(.done(reason: "end_turn"))
                    } catch let err as LauncherError {
                        continuation.yield(.error(err))
                    } catch {
                        continuation.yield(.error(.networkFailure(error)))
                    }
                    await MainActor.run {
                        LauncherManager.shared.stage = .idle
                        LauncherManager.shared.isSubmitting = false
                    }
                    continuation.finish()
                    return // directChat 单轮路径，跳过 LauncherAgent.run

                case .withPlugin(let manifest):
                    // trust check 提前到 mode 分支之前（stdin/prompt 都做）
                    let dir = try PluginManager.shared.pluginDir(for: manifest)
                    let executablePath = dir.appending(path: manifest.cmd)
                    let trusted = await TrustStore.shared.checkAndPrompt(
                        manifest, executablePath: executablePath
                    )
                    guard trusted else {
                        continuation.yield(.error(.pluginNotTrusted(manifest.name)))
                        continuation.finish()
                        return
                    }

                    switch manifest.modeConfig {
                    case .stdin:
                        // 现有路径：toolExecutor 闭包 + LauncherAgent loop
                        tools = [manifest.toAgentTool()]
                        toolExecutor = { name, input in
                            guard name == manifest.name else {
                                throw LauncherError.pluginNotFound(name)
                            }
                            let pluginInput = PluginInput(
                                query: input["query"]?.value as? String ?? query,
                                sessionId: UUID().uuidString,
                                cwd: NSHomeDirectory()
                            )
                            let result = try await PluginDispatcher.shared.execute(
                                manifest,
                                pluginDir: dir,
                                input: pluginInput
                            )
                            return result.stdout
                        }
                        // 继续走下面 LauncherAgent.run

                    case .command:
                        // command mode bypass agent loop（零 LLM）：直接调 StdinExecutor，结果映射为
                        // AgentEvent.text（stdout 非空时）+ .image（图片通道）+ .done。
                        // 仿 prompt mode 结构（:496-532），但走 stdinExecutor 路径。
                        let dispatcher = PluginDispatcher(stdinExecutor: .shared)
                        // strip 命中 keyword 前缀（如 "qr https://..." → "https://..."）
                        let strippedQuery = Self.stripKeywordPrefix(query, manifest: manifest)
                        let pluginInput = PluginInput(
                            query: strippedQuery,
                            sessionId: UUID().uuidString,
                            cwd: NSHomeDirectory()
                        )
                        await MainActor.run { LauncherManager.shared.stage = .streaming }
                        do {
                            let result = try await dispatcher.execute(manifest, pluginDir: dir, input: pluginInput)
                            if !result.stdout.isEmpty {
                                continuation.yield(.text(result.stdout))
                            }
                            if let imageData = result.image {
                                continuation.yield(.image(imageData))
                            }
                            if let candidates = result.candidates {
                                continuation.yield(.candidates(candidates))
                            }
                            continuation.yield(.done(reason: "end_turn"))
                        } catch let err as LauncherError {
                            continuation.yield(.error(err))
                        } catch {
                            continuation.yield(.error(.networkFailure(error)))
                        }
                        await MainActor.run {
                            LauncherManager.shared.stage = .idle
                            LauncherManager.shared.isSubmitting = false
                        }
                        continuation.finish()
                        return // command mode 提前 return，跳过 LauncherAgent.run

                    case .prompt:
                        // prompt mode bypass agent loop：直接调 PromptExecutor，结果映射为 AgentEvent.text
                        let promptExecutor = PromptExecutor(provider: provider, activeProviderModel: providerConfig.model)
                        let dispatcher = PluginDispatcher(stdinExecutor: .shared, promptExecutor: promptExecutor)
                        // strip 命中 keyword 前缀（如 "tr buddy" → "buddy"），避免 LLM 把 keyword 当 query
                        let strippedQuery = Self.stripKeywordPrefix(query, manifest: manifest)
                        let pluginInput = PluginInput(
                            query: strippedQuery,
                            sessionId: UUID().uuidString,
                            cwd: NSHomeDirectory()
                        )
                        do {
                            let result = try await dispatcher.execute(manifest, pluginDir: dir, input: pluginInput)
                            if result.exitCode == 0 {
                                continuation.yield(.text(result.stdout))
                                for action in result.actions {
                                    continuation.yield(.action(action))
                                }
                            } else {
                                // 错误时 stderr 作为用户可见文本展示（含"执行超时" / "执行失败:"）
                                continuation.yield(.text(result.stderr))
                            }
                            continuation.yield(.done(reason: "end_turn"))
                        } catch let err as LauncherError {
                            continuation.yield(.error(err))
                        } catch {
                            continuation.yield(.error(.networkFailure(error)))
                        }
                        // D2 bug fix: prompt mode 完成后 stage 必须归 .idle，否则 TextField 永远 disabled
                        // 注：lastRoutePluginName 保留到下次 submit/hide，让 chip 在结果展示期间持续显示
                        await MainActor.run {
                            LauncherManager.shared.stage = .idle
                            LauncherManager.shared.isSubmitting = false
                        }
                        continuation.finish()
                        return // prompt mode 提前 return，跳过 LauncherAgent.run
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
                            // lastRoutePluginName 保留到下次 submit/hide
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
                        // lastRoutePluginName 保留到下次 submit/hide
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
            config = try configOverride ?? LauncherConfig.load()
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
                    let result = try await PluginDispatcher.shared.execute(
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
                            // lastRoutePluginName 保留到下次 submit/hide
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
                        // lastRoutePluginName 保留到下次 submit/hide
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// 选中回调重入（C5）：用户从候选列表选中某项后，以 `LauncherCandidate.selection` 为 PluginInput.selection
    /// 再次调用同一 **command mode** 插件，bypass LLM（零 provider/router/agent loop）。
    ///
    /// 契约（state.md ## 契约规约 C5）：
    ///   - 签名：`submitWithCandidate(_ manifest: PluginManifest, selection: String, query: String)`
    ///   - 执行权留插件：launcher 仅把 selection 透传给插件，**绝不**执行候选携带命令（C2 安全红线）
    ///   - 结果映射：同静态 command 短路（.text/.image/.candidates/.done），不含 stop/start 专属逻辑
    ///
    /// TOFU 不变（C6）：command trustKey = "command:" + SHA256(cmd+args+exeBytes)，不含 stdin/selection，
    /// 同二进制同 args ⇒ 回调 trustKey 不变，不重复弹框（TrustStore.checkAndPrompt 命中已信任记录直接 true）。
    ///
    /// 注：仅支持 command mode 回调（stdin/prompt 回调留待后续，见设计文档「不做」清单）。
    func submitWithCandidate(
        _ manifest: PluginManifest,
        selection: String,
        query: String
    ) -> AsyncStream<AgentEvent> {
        // command mode 才支持候选回调（stdin/prompt 走 LLM loop，语义不同）
        guard case .command = manifest.modeConfig else {
            return Self.errorStream(.pluginCrash(-1, "submitWithCandidate 仅支持 command mode 插件"))
        }

        // 直接进入 calling 阶段（跳过 narrowing/routing），记录 plugin 名
        lastRoutePluginName = manifest.name
        stage = .calling

        return AsyncStream { continuation in
            let task = Task.detached {
                // 解析插件目录（detached 内独立查，不依赖 submit 的窄结果）
                let dir: URL
                // 测试缝：pluginManagerOverride 优先，不依赖 ~/.buddy/launcher-plugins
                let pm = await MainActor.run { LauncherManager.shared.pluginManagerOverride ?? PluginManager.shared }
                do {
                    dir = try pm.pluginDir(for: manifest)
                } catch {
                    await MainActor.run {
                        LauncherManager.shared.stage = .error
                        LauncherManager.shared.isSubmitting = false
                    }
                    continuation.yield(.error((error as? LauncherError) ?? .networkFailure(error)))
                    continuation.finish()
                    return
                }
                let executablePath = dir.appending(path: manifest.cmd)
                // C6：trustKey 不含 selection，同二进制同 args ⇒ 已信任则不弹框
                let trusted = await TrustStore.shared.checkAndPrompt(manifest, executablePath: executablePath)
                guard trusted else {
                    continuation.yield(.error(.pluginNotTrusted(manifest.name)))
                    continuation.finish()
                    await MainActor.run {
                        LauncherManager.shared.stage = .idle
                        LauncherManager.shared.isSubmitting = false
                    }
                    return
                }
                // C4：selection 填入 PluginInput.selection，插件据此路由
                let pluginInput = PluginInput(
                    query: query,
                    sessionId: UUID().uuidString,
                    cwd: NSHomeDirectory(),
                    selection: selection
                )
                await MainActor.run { LauncherManager.shared.stage = .streaming }
                let dispatcher = PluginDispatcher(stdinExecutor: .shared)
                do {
                    let result = try await dispatcher.execute(manifest, pluginDir: dir, input: pluginInput)
                    if !result.stdout.isEmpty {
                        continuation.yield(.text(result.stdout))
                    }
                    if let imageData = result.image {
                        continuation.yield(.image(imageData))
                    }
                    if let candidates = result.candidates {
                        continuation.yield(.candidates(candidates))
                    }
                    // exitCode != 0 且无任何产物 → stderr 作为用户可见文本（对称静态短路）
                    if result.exitCode != 0 && result.stdout.isEmpty
                        && result.image == nil && result.candidates == nil {
                        continuation.yield(.text(result.stderr.isEmpty ? "执行失败" : result.stderr))
                    }
                    continuation.yield(.done(reason: "end_turn"))
                } catch let err as LauncherError {
                    continuation.yield(.error(err))
                } catch {
                    continuation.yield(.error(.networkFailure(error)))
                }
                await MainActor.run {
                    LauncherManager.shared.stage = .idle
                    LauncherManager.shared.isSubmitting = false
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// command 短路直接执行入口（方案 B §1.5，C11）。
    ///
    /// 镜像 `submit()` 内 `.command` case（L559-594）+ 顶层 command 短路（L347-388）的执行段：
    /// `guard case .command`（非 command → errorStream(.pluginCrash)）→ prologue（清 commandRouteCandidates/
    /// commandRouteSelectedIndex=-1 + stage=.calling + lastRoutePluginName）→ detached: trust checkAndPrompt
    /// → `PluginDispatcher(stdinExecutor: stdinExecutorOverride ?? .shared).execute` →
    /// yield `.text`/`.image`/`.candidates`/`.done` → stage streaming→idle。
    ///
    /// **零 provider / 零 LLM**（与 submitWithPlugin 区别：后者强制 provider + LLM agent loop，见 B1）。
    /// 对称 submitWithCandidate（command 回调入口）。
    ///
    /// 用途：用户在 command 路由候选区按 Enter / 点行（C4）→ 经此入口触发 command 短路执行，
    /// 子进程经 BUDDY_OUTPUT_CANDIDATES 回吐子候选 → pluginCandidates 通道。
    func submitCommandDirect(_ manifest: PluginManifest, query: String) -> AsyncStream<AgentEvent> {
        // C11：guard case .command（非 command → errorStream）
        guard case .command = manifest.modeConfig else {
            return Self.errorStream(.pluginCrash(-1, "submitCommandDirect 仅支持 command mode 插件"))
        }

        // prologue（MainActor 同步段，B2：清 commandRouteCandidates 避免子候选回吐后双重渲染/计高）
        commandRouteCandidates = []
        commandRouteSelectedIndex = -1
        lastRoutePluginName = manifest.name
        // C5 回调查找：填 lastRouteCandidates，让"选中子候选（如关闭监控）"时 submit() 能按 name 找到 manifest。
        // 镜像 submit() command 短路 L350 的赋值；不填则回调路径 manifest=nil → 落 AI 流 → 执行失败。
        lastRouteCandidates = [manifest]
        stage = .calling
        // 在 MainActor 上捕获 spy seam，避免 detached 跨 actor 访问
        let executorOverride = stdinExecutorOverride

        return AsyncStream { continuation in
            let task = Task.detached {
                // 解析插件目录（测试缝：pluginManagerOverride 优先）
                let pm = await MainActor.run { LauncherManager.shared.pluginManagerOverride ?? PluginManager.shared }
                let dir: URL
                do {
                    dir = try pm.pluginDir(for: manifest)
                } catch {
                    await MainActor.run {
                        LauncherManager.shared.stage = .error
                        LauncherManager.shared.isSubmitting = false
                    }
                    continuation.yield(.error((error as? LauncherError) ?? .networkFailure(error)))
                    continuation.finish()
                    return
                }
                let executablePath = dir.appending(path: manifest.cmd)
                // TOFU 不变（C8）：command trustKey = "command:" + SHA256(cmd+args+exeBytes)
                let trusted = await TrustStore.shared.checkAndPrompt(manifest, executablePath: executablePath)
                guard trusted else {
                    continuation.yield(.error(.pluginNotTrusted(manifest.name)))
                    continuation.finish()
                    await MainActor.run {
                        LauncherManager.shared.stage = .idle
                        LauncherManager.shared.isSubmitting = false
                    }
                    return
                }
                // strip 命中 keyword 前缀（如 "qr https://..." → "https://..."）
                let strippedQuery = Self.stripKeywordPrefix(query, manifest: manifest)
                let pluginInput = PluginInput(
                    query: strippedQuery,
                    sessionId: UUID().uuidString,
                    cwd: NSHomeDirectory()
                )
                await MainActor.run { LauncherManager.shared.stage = .streaming }
                // C11/I6 spy seam：stdinExecutorOverride 优先于 .shared
                let dispatcher = PluginDispatcher(stdinExecutor: executorOverride ?? .shared)
                do {
                    let result = try await dispatcher.execute(manifest, pluginDir: dir, input: pluginInput)
                    if !result.stdout.isEmpty {
                        continuation.yield(.text(result.stdout))
                    }
                    if let imageData = result.image {
                        continuation.yield(.image(imageData))
                    }
                    if let candidates = result.candidates {
                        continuation.yield(.candidates(candidates))
                    }
                    // exitCode != 0 且无任何产物 → stderr 作为用户可见文本（对称静态短路）
                    if result.exitCode != 0 && result.stdout.isEmpty
                        && result.image == nil && result.candidates == nil {
                        continuation.yield(.text(result.stderr.isEmpty ? "执行失败" : result.stderr))
                    }
                    continuation.yield(.done(reason: "end_turn"))
                } catch let err as LauncherError {
                    continuation.yield(.error(err))
                } catch {
                    continuation.yield(.error(.networkFailure(error)))
                }
                await MainActor.run {
                    LauncherManager.shared.stage = .idle
                    LauncherManager.shared.isSubmitting = false
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

    /// Strip 命中 plugin 的 keyword 前缀（含 manifest.name），让 LLM 只看到真实查询内容。
    /// 示例：query="tr buddy", manifest.keywords=["tr","translate","翻译"] → 返回 "buddy"
    /// 长前缀优先匹配（避免 "translator" 被 "tr" 错切）。无前缀命中时返回原 query。
    nonisolated static func stripKeywordPrefix(_ query: String, manifest: PluginManifest) -> String {
        let candidates = ([manifest.name] + manifest.keywords)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .sorted { $0.count > $1.count }
        let queryLower = query.lowercased()
        for prefix in candidates {
            let prefixLower = prefix.lowercased()
            guard queryLower.hasPrefix(prefixLower) else { continue }
            // 严格分隔：前缀后必须紧跟空白 / 标点 / 行尾，避免 "trace" 被 "tr" 错切
            let after = query.index(query.startIndex, offsetBy: prefix.count)
            if after == query.endIndex {
                return ""  // query 就是 keyword 本身
            }
            let nextChar = query[after]
            if nextChar.isWhitespace || nextChar.isPunctuation {
                return String(query[after...]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return query
    }
}
