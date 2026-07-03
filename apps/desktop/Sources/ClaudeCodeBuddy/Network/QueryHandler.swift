import Foundation
import AppKit
import KeyboardShortcuts

/// Handles query messages from the CLI and generates JSON responses.
/// Queries are distinguished from hook messages by the presence of an "action" field.
///
/// 注：handle() 标注 @MainActor —— hotkey_set/show/clear 命令调用 KeyboardShortcuts
/// 库 API（标注 @MainActor），编译期保证主线程。调用方 SessionManager.onQuery 通过
/// Task { @MainActor } 调用；测试类（QueryHandlerTests/LauncherHotkeyConfigAcceptanceTests）标注 @MainActor。
///
/// handle() 为 async：launcher_debug_candidates / launcher_debug_perform 调
/// BuiltinPluginRegistry.actions(for:)（async）；async 函数即使同 actor 也必须 await。
final class QueryHandler {
    private let sessionManager: SessionManager
    private let scene: any SceneControlling
    private let eventStore: EventStore
    /// Launcher debug 子命令：内置插件注册表（直驱，不经 LauncherManager）。
    /// 可选：生产 nil → 在 @MainActor handler 内 resolve 为 .shared（避免 nonisolated 默认参数
    /// / nonisolated start() 引用 @MainActor 的 .shared，Swift 6 错误）；测试注入 mock。
    private let registry: BuiltinPluginRegistry?
    /// Launcher debug perform：读 perform 后剪贴板内容（默认 .general，测试注入具名 pasteboard）。
    private let pasteboard: NSPasteboard
    /// C4 launcher run：外部插件管理器（find manifest + pluginDir）。测试注入 mock。
    private let pluginManager: PluginManager
    /// C4 launcher run：trust 存储（TOFU 检查）。测试注入 mock。
    private let trustStore: TrustStore
    /// C4 launcher run：插件执行器（stdin/command 直驱）。测试注入 mock。
    private let pluginDispatcher: PluginDispatcher

    init(
        sessionManager: SessionManager,
        scene: any SceneControlling,
        eventStore: EventStore,
        registry: BuiltinPluginRegistry? = nil,
        pasteboard: NSPasteboard = .general,
        pluginManager: PluginManager = .shared,
        trustStore: TrustStore = .shared,
        pluginDispatcher: PluginDispatcher = .shared
    ) {
        self.sessionManager = sessionManager
        self.scene = scene
        self.eventStore = eventStore
        self.registry = registry
        self.pasteboard = pasteboard
        self.pluginManager = pluginManager
        self.trustStore = trustStore
        self.pluginDispatcher = pluginDispatcher
    }

    // MARK: - Public

    /// Process a query and return the JSON response data.
    ///
    /// async：launcher_debug_candidates / launcher_debug_perform 调 registry.actions(for:)（async）。
    ///
    /// @MainActor：hotkey 命令调用 KeyboardShortcuts 库 API（@MainActor），编译期保证主线程
    /// （qa-reviewer B-1 加固：原 MainActor.assumeIsolated 是运行时隐式契约，改为编译期保证）。
    @MainActor
    func handle(query: [String: Any]) async -> Data {
        guard let action = query["action"] as? String else {
            return errorResponse(message: "missing 'action' field")
        }

        switch action {
        case "inspect":
            return handleInspect(query: query)
        case "click":
            return handleClick(query: query)
        case "food":
            return handleFood(query: query)
        case "events":
            return handleEvents(query: query)
        case "health":
            return handleHealth()
        case "hotkey_show":
            return handleHotkeyShow()
        case "hotkey_set":
            return handleHotkeySet(query: query)
        case "hotkey_clear":
            return handleHotkeyClear()
        case "launcher_debug_candidates":
            return await handleLauncherDebugCandidates(query: query)
        case "launcher_debug_perform":
            return await handleLauncherDebugPerform(query: query)
        case "launcher_debug_registry":
            return handleLauncherDebugRegistry()
        case "launcher_debug_run_plugin":
            return await handleLauncherDebugRunPlugin(query: query)
        case "launcher_debug_route":
            return await handleLauncherDebugRoute(query: query)
        case "open_settings":
            NotificationCenter.default.post(name: .buddyStoreShouldOpen, object: nil)
            return okResponse(data: ["opened": "settings"])
        default:
            return errorResponse(message: "unknown action: \(action)")
        }
    }

    // MARK: - Inspect

    private func handleInspect(query: [String: Any]) -> Data {
        if let sessionId = query["session_id"] as? String {
            return handleInspectSession(sessionId: sessionId)
        } else {
            return handleInspectAll()
        }
    }

    private func handleInspectSession(sessionId: String) -> Data {
        guard let info = sessionManager.sessionInfo(for: sessionId) else {
            return errorResponse(message: "session not found: \(sessionId)")
        }

        var data: [String: Any] = [
            "session": sessionInfoDict(info),
        ]

        // Add cat snapshot if available
        if let catSnap = scene.catSnapshot(for: sessionId) {
            data["cat"] = catSnap.toDict()
        }

        return okResponse(data: data)
    }

    private func handleInspectAll() -> Data {
        let sessions = Array(sessionManager.sessions.values).sorted { $0.sessionId < $1.sessionId }
        let sessionDicts = sessions.map { info -> [String: Any] in
            [
                "id": info.sessionId,
                "state": info.state.rawValue,
                "label": info.label,
                "color": "\(info.color)",
            ]
        }

        return okResponse(data: [
            "sessions": sessionDicts,
            "total": sessionDicts.count,
        ])
    }

    // MARK: - Click

    private func handleClick(query: [String: Any]) -> Data {
        guard let sessionId = query["session_id"] as? String else {
            return errorResponse(message: "click requires 'session_id'")
        }
        let success = scene.simulateClick(sessionId: sessionId)
        if success {
            return okResponse(data: ["clicked": sessionId])
        } else {
            return errorResponse(message: "session not found: \(sessionId)")
        }
    }

    // MARK: - Food

    private func handleFood(query: [String: Any]) -> Data {
        let x: CGFloat?
        if let explicitX = query["x"] as? Double {
            x = CGFloat(explicitX)
        } else if let sessionId = query["session_id"] as? String {
            x = scene.catPosition(for: sessionId)
        } else {
            x = nil
        }
        scene.spawnFood(near: x)
        return okResponse(data: ["spawned": true])
    }

    // MARK: - Events

    private func handleEvents(query: [String: Any]) -> Data {
        let sessionId = query["session_id"] as? String
        var last = query["last"] as? Int ?? 0

        // Validate last parameter
        if last < 0 { last = 0 }
        if last > EventStore.capacity { last = EventStore.capacity }

        let (events, totalStored) = eventStore.query(sessionId: sessionId, last: last)
        let eventDicts = events.map { $0.toDict() }

        return okResponse(data: [
            "events": eventDicts,
            "count": eventDicts.count,
            "total_stored": totalStored,
        ])
    }

    // MARK: - Health

    private func handleHealth() -> Data {
        let sceneSnap = scene.sceneSnapshot()

        let data: [String: Any] = [
            "socket": [
                "listening": sessionManager.isSocketListening,
                "path": SocketServer.socketPath,
            ],
            "sessions": [
                "active": sessionManager.sessions.count,
                "max": 8,
            ],
            "event_store": [
                "events_stored": eventStore.totalRecordedCount,
                "capacity": EventStore.capacity,
            ],
            "scene": sceneSnap.toDict(),
            "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
        ]

        return okResponse(data: data)
    }

    // MARK: - Hotkey

    /// hotkey_show → getShortcut(for: .toggle) → {status:"ok", data:{combo, isDefault}}
    @MainActor
    private func handleHotkeyShow() -> Data {
        let shortcut = KeyboardShortcuts.getShortcut(for: LauncherHotkey.toggle)
        let combo = hotkeyComboString(for: shortcut)
        let isDefault = isShortcutDefault(shortcut)
        return okResponse(data: [
            "combo": combo,
            "isDefault": isDefault,
        ])
    }

    /// hotkey_set → 参数校验 → setShortcut → 即时重注册 → {status:"ok", data:{combo, isDefault:false}}
    /// 注：库 setShortcut 不做系统级冲突检测（仅 Recorder UI 路径有 alert），CLI 不预检系统冲突（契约 2 降级）
    @MainActor
    private func handleHotkeySet(query: [String: Any]) -> Data {
        guard let keyStr = query["key"] as? String, !keyStr.isEmpty else {
            return errorResponse(message: "invalid key/modifiers")
        }
        guard let key = HotkeyKeyMapper.key(from: keyStr) else {
            return errorResponse(message: "invalid key/modifiers")
        }

        // modifiers 必须是 [String]（存在但非数组 → 类型错误，拒绝）
        let modStrs: [String]
        if let mods = query["modifiers"] as? [String] {
            modStrs = mods
        } else if query["modifiers"] == nil {
            // modifiers 必填（qa-reviewer B-3：与 CLI 对齐 —— 全局热键必须带修饰键，否则与普通打字冲突）
            return errorResponse(message: "invalid key/modifiers")
        } else {
            // 存在但非 [String]（如单个 String / Int）→ 契约违规
            return errorResponse(message: "invalid key/modifiers")
        }
        // 空数组 = 无修饰键，拒绝（同 CLI 护栏，B-3）
        guard !modStrs.isEmpty else {
            return errorResponse(message: "invalid key/modifiers")
        }
        guard let modifiers = HotkeyKeyMapper.modifiers(from: modStrs) else {
            return errorResponse(message: "invalid key/modifiers")
        }

        let shortcut = KeyboardShortcuts.Shortcut(key, modifiers: modifiers)
        KeyboardShortcuts.setShortcut(shortcut, for: LauncherHotkey.toggle)
        let combo = hotkeyComboString(for: shortcut)
        return okResponse(data: [
            "combo": combo,
            "isDefault": false,
        ])
    }

    /// hotkey_clear → KeyboardShortcuts.reset(.toggle)（回 default，非 setShortcut(nil)）→ {status:"ok", data:{combo:default, isDefault:true}}
    @MainActor
    private func handleHotkeyClear() -> Data {
        KeyboardShortcuts.reset(LauncherHotkey.toggle)
        let shortcut = KeyboardShortcuts.getShortcut(for: LauncherHotkey.toggle)
        let combo = hotkeyComboString(for: shortcut)
        return okResponse(data: [
            "combo": combo,
            "isDefault": true,
        ])
    }

    /// 当前 combo 的展示字符串（与 UI Recorder 显示一致，如「⌃Space」）。
    /// MainActor：Shortcut.description 标注 @MainActor（内部 TISGetInputSourceProperty 限主线程）。
    @MainActor
    private func hotkeyComboString(for shortcut: KeyboardShortcuts.Shortcut?) -> String {
        guard let shortcut else {
            // 未设置（getShortcut 返回 nil，理论上 reset 后回 default 不会发生，但兜底）
            return LauncherHotkey.toggle.defaultShortcut.map { $0.description } ?? ""
        }
        return shortcut.description
    }

    /// 判断当前生效 shortcut 是否等于 default shortcut。
    private func isShortcutDefault(_ shortcut: KeyboardShortcuts.Shortcut?) -> Bool {
        guard let shortcut, let defaultShortcut = LauncherHotkey.toggle.defaultShortcut else {
            return false
        }
        return shortcut == defaultShortcut
    }

    // MARK: - Launcher Debug（CLI 驱动候选生成，不经键盘自动化）

    /// Resolve registry：测试注入优先（非 nil），否则用 .shared。
    /// @MainActor：合法引用 @MainActor 隔离的 BuiltinPluginRegistry.shared（避免 nonisolated
    /// 默认参数 / SessionManager.start() nonisolated 引用 .shared 的 Swift 6 错误）。
    @MainActor
    private func resolvedRegistry() -> BuiltinPluginRegistry {
        registry ?? BuiltinPluginRegistry.shared
    }

    /// launcher_debug_candidates → registry.actions(for: q) → {query, count, candidates[]}
    /// 契约：请求字段 query:String（非空）；响应候选字段 pluginId/title/subtitle/score。
    @MainActor
    private func handleLauncherDebugCandidates(query: [String: Any]) async -> Data {
        guard let q = query["query"] as? String, !q.isEmpty else {
            return errorResponse(message: "missing 'query'")
        }
        let acts = await resolvedRegistry().actions(for: q)
        let candidates: [[String: Any]] = acts.map {
            [
                "pluginId": $0.pluginId,
                "title": $0.title,
                "subtitle": $0.subtitle ?? "",
                "score": $0.score,
            ]
        }
        return okResponse(data: [
            "query": q,
            "count": acts.count,
            "candidates": candidates,
        ])
    }

    /// launcher_debug_perform → registry.actions(for: q)[index].perform() → 读 pasteboard →
    /// {pluginId, performed:true, copied?}（copied 仅当 perform 后 pasteboard 非空）。
    /// 契约：请求字段 query:String（非空）+ index:Int（默认 0）。
    @MainActor
    private func handleLauncherDebugPerform(query: [String: Any]) async -> Data {
        guard let q = query["query"] as? String, !q.isEmpty else {
            return errorResponse(message: "missing 'query'")
        }
        let index = query["index"] as? Int ?? 0
        let acts = await resolvedRegistry().actions(for: q)
        guard acts.indices.contains(index) else {
            return errorResponse(message: "no candidate at index \(index)")
        }
        let action = acts[index]
        do {
            try action.perform()
        } catch {
            return errorResponse(message: "perform failed: \(error)")
        }
        let copied = pasteboard.string(forType: .string)
        var data: [String: Any] = [
            "pluginId": action.pluginId,
            "performed": true,
        ]
        if let copied {
            data["copied"] = copied
        }
        return okResponse(data: data)
    }

    /// launcher_debug_registry → registry.plugins（priority 降序）→ {plugins[{id,priority,sectionTitle,summary,enabled}]}
    /// C2/C3：含 summary（人话）+ enabled（C3 开关状态）。
    @MainActor
    private func handleLauncherDebugRegistry() -> Data {
        let registry = resolvedRegistry()
        let plugins: [[String: Any]] = registry.plugins
            .sorted { $0.priority > $1.priority }
            .map {
                [
                    "id": $0.id,
                    "priority": $0.priority,
                    "sectionTitle": $0.sectionTitle,
                    "summary": $0.summary,
                    "enabled": registry.isEnabled(id: $0.id),
                ]
            }
        return okResponse(data: ["plugins": plugins])
    }

    /// C4 launcher_debug_run_plugin → 按 name 找外部插件 manifest → TrustStore.checkAndPrompt（B1）
    /// → 信任通过则 PluginDispatcher.execute() 直驱 → 返回 {name,stdout,stderr,exit_code,duration_ms}。
    /// trust 失败返回 {status:"error", message:"not trusted"}。不经候选路由（name→直接 execute）。
    @MainActor
    private func handleLauncherDebugRunPlugin(query: [String: Any]) async -> Data {
        guard let name = query["name"] as? String, !name.isEmpty else {
            return errorResponse(message: "missing 'name'")
        }
        // 1. 找外部插件 manifest + pluginDir
        let manifest: PluginManifest
        let pluginDir: URL
        do {
            guard let found = try pluginManager.find(name: name) else {
                return errorResponse(message: "plugin not found: \(name)")
            }
            manifest = found
            pluginDir = try pluginManager.pluginDir(for: found)
        } catch {
            return errorResponse(message: "plugin not found: \(name)")
        }

        // 2. B1：TOFU trust 检查（必须在 PluginDispatcher.execute 前显式调，与 LauncherManager.submit 一致）
        // executablePath = pluginDir/cmd（stdin/command）；prompt mode checkAndPrompt 内部按 systemPrompt 处理。
        let executablePath = pluginDir.appending(path: manifest.cmd)
        let trusted = await trustStore.checkAndPrompt(manifest, executablePath: executablePath)
        guard trusted else {
            BuddyLogger.shared.warn("launcher run rejected: not trusted", subsystem: "plugin", meta: ["name": name])
            return errorResponse(message: "not trusted")
        }

        // 3. 直驱执行（不经候选路由）
        let input = PluginInput(
            query: (query["input"] as? String) ?? "",
            sessionId: "launcher-run-\(UUID().uuidString)",
            cwd: FileManager.default.currentDirectoryPath
        )
        let result: PluginResult
        do {
            result = try await pluginDispatcher.execute(manifest, pluginDir: pluginDir, input: input)
        } catch {
            BuddyLogger.shared.error("launcher run execute failed", subsystem: "plugin", meta: ["name": name, "error": "\(error)"])
            return errorResponse(message: "execute failed: \(error.localizedDescription)")
        }

        // 4. 返回结果 JSON
        let data: [String: Any] = [
            "name": name,
            "stdout": result.stdout,
            "stderr": result.stderr,
            "exit_code": Int(result.exitCode),
            "duration_ms": result.durationMs,
        ]
        BuddyLogger.shared.info("launcher run ok", subsystem: "plugin", meta: [
            "name": name,
            "exit_code": Int(result.exitCode),
            "duration_ms": result.durationMs,
        ])
        return okResponse(data: data)
    }

    /// launcher_debug_route → 提取 query → ProviderFactory 创建 provider → LauncherRouter narrow + AI select
    /// → PromptExecutor.execute 直接获取 LLM 响应 → 返回 {query, decision, candidates[], outputText, durationMs}。
    /// 绕过 LauncherManager.submit 的 isSubmitting 卫兵和 AsyncStream（在 handler 上下文中不适合 consume 异步流）。
    @MainActor
    private func handleLauncherDebugRoute(query: [String: Any]) async -> Data {
        guard let q = query["query"] as? String, !q.isEmpty else {
            return errorResponse(message: "missing 'query'")
        }

        let startTime = Date()

        // 1. 加载配置
        let config: LauncherConfig
        do {
            config = try LauncherConfig.load()
        } catch {
            return errorResponse(message: "config load failed: \(error.localizedDescription)")
        }
        guard !config.activeProvider.isEmpty,
              let providerConfig = config.providers[config.activeProvider] else {
            return errorResponse(message: "provider not configured")
        }

        // 2. 创建 provider
        let store: SecretStore
        do {
            store = try SecretStoreFactory.create()
        } catch {
            return errorResponse(message: "secretStore unavailable: \(error.localizedDescription)")
        }
        let provider: LauncherProvider
        do {
            provider = try ProviderFactory.create(providerConfig, store: store)
        } catch {
            return errorResponse(message: "provider creation failed: \(error.localizedDescription)")
        }

        // 3. LauncherRouter: narrow candidates + AI select
        let plugins = (try? PluginManager.shared.list()) ?? []
        let scored = LauncherRouter.narrowCandidatesScored(query: q, plugins: plugins)
        let candidates: [[String: Any]] = scored.map {
            [
                "name": $0.manifest.name,
                "score": $0.score,
                "mode": String(describing: $0.manifest.modeConfig),
            ]
        }

        var decision = "directChat"
        var routeMethod = "directChat"
        var extractedQuery: String?
        if !candidates.isEmpty {
            let router = LauncherRouter(
                pluginManager: PluginManager.shared,
                provider: provider,
                routerModel: providerConfig.model
            )
            let narrowList = router.narrowCandidates(q)
            if !narrowList.isEmpty {
                do {
                    // debugRoute 镜像 submit 路由分支：空→directChat / 全 prompt→pickWithAI /
                    // 含 tool 候选→selectWithTools（e2a65ca 的 tool-use 路径，原 debug route 走旧 pickWithAI）
                    let routeResult = try await router.debugRoute(query: q, candidates: narrowList)
                    routeMethod = routeResult.routeMethod
                    extractedQuery = routeResult.extractedQuery
                    if case .withPlugin(let m) = routeResult.decision {
                        decision = "withPlugin:\(m.name)"
                    }
                } catch {
                    // AI select 失败 → 降级为 directChat
                    decision = "directChat (router failed: \(error.localizedDescription))"
                    routeMethod = "error"
                }
            }
        }

        // 4. PromptExecutor 直接获取 LLM 响应
        let promptExecutor = PromptExecutor(provider: provider, activeProviderModel: providerConfig.model)
        let cfg = PromptConfig(
            systemPrompt: DefaultAgentPrompt.system,
            maxIterations: 1,
            model: nil,
            autoCopyToClipboard: false
        )
        let outputText: String
        do {
            let result = try await promptExecutor.execute(query: q, config: cfg)
            outputText = result.exitCode == 0 ? result.stdout : result.stderr
        } catch {
            outputText = "LLM execute failed: \(error.localizedDescription)"
        }

        let durationMs = Int(Date().timeIntervalSince(startTime) * 1000)

        var data: [String: Any] = [
            "query": q,
            "decision": decision,
            "candidates": candidates,
            "outputText": outputText,
            "durationMs": durationMs,
            // routeMethod 让 cli 透传路由路径（selectWithTools|pickWithAI|directChat|error），
            // 使「自然语言→选插件」的 tool-use 路径可观测；extractedQuery 是 LLM 从 tool_call 提取的参数。
            "routeMethod": routeMethod,
        ]
        if let eq = extractedQuery {
            data["extractedQuery"] = eq
        }
        return okResponse(data: data)
    }

    // MARK: - Response Helpers

    private func okResponse(data: [String: Any]) -> Data {
        let response: [String: Any] = ["status": "ok", "data": data]
        return (try? JSONSerialization.data(withJSONObject: response, options: [.sortedKeys])) ?? Data()
    }

    private func errorResponse(message: String) -> Data {
        let response: [String: Any] = ["status": "error", "message": message]
        return (try? JSONSerialization.data(withJSONObject: response, options: [.sortedKeys])) ?? Data()
    }

    // MARK: - Session Info Serialization

    private func sessionInfoDict(_ info: SessionInfo) -> [String: Any] {
        var dict: [String: Any] = [
            "id": info.sessionId,
            "label": info.label,
            "color": "\(info.color)",
            "state": info.state.rawValue,
            "last_activity": ISO8601DateFormatter().string(from: info.lastActivity),
            "total_tokens": info.totalTokens,
            "tool_call_count": info.toolCallCount,
        ]
        if let cwd = info.cwd { dict["cwd"] = cwd }
        if let pid = info.pid { dict["pid"] = pid }
        if let tid = info.terminalId { dict["terminal_id"] = tid }
        if let desc = info.toolDescription { dict["tool_description"] = desc }
        if let model = info.model { dict["model"] = model }
        if let startedAt = info.startedAt { dict["started_at"] = ISO8601DateFormatter().string(from: startedAt) }
        return dict
    }
}
