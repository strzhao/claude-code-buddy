import Foundation
import Darwin

// MARK: - SessionManager

/// Bridges incoming socket messages to BuddyScene actions.
/// Also enforces session timeouts and manages per-session color/label identity.
class SessionManager {

    // MARK: - Properties

    private let scene: any SceneControlling
    private let server = SocketServer()
    private(set) var eventStore = EventStore()
    private var queryHandler: QueryHandler?

    /// Full session state keyed by sessionId.
    var sessions: [String: SessionInfo] = [:]

    /// Tracks which colors are currently in use.
    var usedColors: Set<SessionColor> = []

    /// Called whenever the active session count changes.
    var onSessionCountChanged: ((Int) -> Void)?

    /// Called whenever session list changes (create/remove/label update).
    var onSessionsChanged: (([SessionInfo]) -> Void)?

    /// Called when a new session is created or PID becomes available, to sync tab title.
    var onSessionNeedsTabTitle: ((SessionInfo) -> Void)?

    private var timeoutTimer: Timer?
    private var lastTranscriptScan: Date = .distantPast

    // MARK: - Headless Detection（C-HEADLESS-DETECT）

    /// seam：sessionId 注册表反查 pid。生产 = SessionRegistryPidResolver；
    /// XCTest 宿主默认 FailFastHeadlessResolver（零等待 fail-open）；单测显式注入 Mock。
    private let headlessResolver: any HeadlessResolving
    /// seam：ps argv 判型。单测注入 Mock 驱动 headless/dead 分支。
    private let headlessChecker: any HeadlessChecking
    /// C-HEADLESS-NO-TERMINAL：检测未落定期间 hook 发来的 terminal_id 暂存区。
    /// 判定 interactive 后应用并触发 tab title；判定 headless 后丢弃（不存储不触发）。
    private var pendingTerminalIds: [String: String] = [:]
    /// 在飞检测链计数（测试 settle 用；主线程读写）
    private(set) var headlessDetectionsInFlight = 0

    // MARK: - Timeout Config

    /// After this interval with no messages, the cat reverts to idle.
    private let idleTimeout: TimeInterval   = 5 * 60    // 5 minutes
    /// After this interval, the session is auto-removed.
    private let removeTimeout: TimeInterval = 30 * 60   // 30 minutes

    // MARK: - Color File

    static let colorFilePath = "/tmp/claude-buddy-colors.json"

    // MARK: - Init

    /// - Note: 默认始终用生产 resolver（注册表反查 + 0.5s×4 重试）。单测要快速 fail-open
    ///   或驱动特定判型分支时，显式注入 `FailFastHeadlessResolver()` / Mock——
    ///   红队验收测试依赖默认构造的生产行为时序（failOpenTimeout ≥ 重试窗口），不可按
    ///   测试宿主自动切换默认值。
    init(
        scene: any SceneControlling,
        headlessResolver: (any HeadlessResolving)? = nil,
        headlessChecker: (any HeadlessChecking)? = nil
    ) {
        self.scene = scene
        self.headlessResolver = headlessResolver ?? SessionRegistryPidResolver()
        self.headlessChecker = headlessChecker ?? ProcessArgsHeadlessChecker()
    }

    // MARK: - Start / Stop

    func start() {
        // Clear stale color file on startup
        try? Data("{}".utf8).write(to: URL(fileURLWithPath: Self.colorFilePath))

        // Initialize query handler
        // registry（默认 nil，在 @MainActor handle 内 resolve 为 .shared）/ pasteboard（默认 .general）
        // 用默认值；测试侧通过自定义 init 注入。不在 nonisolated start() 里引用 @MainActor 的 .shared。
        queryHandler = QueryHandler(
            sessionManager: self,
            scene: scene,
            eventStore: eventStore
        )

        server.onMessage = { [weak self] message in
            self?.handle(message: message)
        }

        server.onQuery = { [weak self] query, clientFD in
            guard let self = self, let handler = self.queryHandler else { return }
            // handle() 标注 @MainActor（hotkey 命令调用 KeyboardShortcuts 库 API），通过 Task 派主线程（qa-reviewer B-1）
            Task { @MainActor in
                // handle 为 async：launcher_debug_candidates/perform 调 registry.actions(for:)（async）
                let responseData = await handler.handle(query: query)
                // 写回 socket queue 而非主线程（qa-reviewer B-2：避免主线程同步写循环卡 UI）
                self.server.sendResponseAsync(data: responseData, to: clientFD)
            }
        }

        server.start()

        // Timer to enforce idle / remove timeouts
        timeoutTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.checkTimeouts()
        }
    }

    func stop() {
        server.stop()
        timeoutTimer?.invalidate()
        timeoutTimer = nil
    }

    deinit { stop() }

    // MARK: - Public Lookup

    func sessionInfo(for sessionId: String) -> SessionInfo? {
        return sessions[sessionId]
    }

    /// Whether the socket server is currently listening.
    var isSocketListening: Bool {
        return FileManager.default.fileExists(atPath: SocketServer.socketPath)
    }

    // MARK: - EventBus Recording
    // Events are recorded directly in handle(message:) — no Combine subscription needed.
    // All state transitions flow through handle(), making it the natural recording point.

    // MARK: - Color Pool（C-COLOR-REUSE）

    /// 首选未占用色；池满（8 色全占）时选「当前在用会话数最少」的颜色循环复用
    /// （同数取 allCases 序靠前——min(by:) 平局语义）。
    private func assignColor() -> SessionColor {
        if let free = SessionColor.allCases.first(where: { !usedColors.contains($0) }) {
            usedColors.insert(free)
            return free
        }
        let counts = Dictionary(grouping: sessions.values, by: { $0.color }).mapValues(\.count)
        let chosen = SessionColor.allCases.min { counts[$0] ?? 0 < counts[$1] ?? 0 }
            ?? SessionColor.allCases[0]
        usedColors.insert(chosen)
        return chosen
    }

    /// 精确回收：复用后一个颜色可能被多个 session 持有，
    /// 仅当没有其他 session 仍持有该色时才从 usedColors 移除（保持「in use」语义不失真）。
    private func releaseColor(_ color: SessionColor) {
        let stillHeld = sessions.values.contains { $0.color == color }
        if !stillHeld {
            usedColors.remove(color)
        }
    }

    // MARK: - Label Generation

    private func generateLabel(from cwd: String?) -> String {
        guard let cwd = cwd else { return "claude" }
        let base = (cwd as NSString).lastPathComponent
        let existing = sessions.values.filter { $0.label == base }.count
        return existing > 0 ? "\(base)②" : base
    }

    // MARK: - CWD Enrichment

    private func enrichCwd(for sessionId: String, from message: HookMessage) {
        guard sessions[sessionId]?.cwd == nil else { return }

        // Primary: from hook message
        if let cwd = message.cwd {
            let label = generateLabel(from: cwd)
            sessions[sessionId]?.cwd = cwd
            sessions[sessionId]?.label = label
            return
        }

        // Fallback: scan ~/.claude/sessions/
        // (each session scanned at most once - cwd is cached in SessionInfo)
    }

    // MARK: - Color File Writing (atomic)

    private func writeColorFile() {
        var dict: [String: [String: String]] = [:]
        for (id, info) in sessions {
            dict[id] = [
                "color": "\(info.color)",
                "hex": info.color.hex,
                "label": info.label,
                // C-INSPECT-FIELD：`buddy status` 行 headless 标记的数据源
                "headless": info.isHeadless ? "yes" : "no"
            ]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]) else { return }
        let tempPath = Self.colorFilePath + ".tmp"
        FileManager.default.createFile(atPath: tempPath, contents: data)
        // removeItem may fail if file doesn't exist yet — that's fine
        try? FileManager.default.removeItem(atPath: Self.colorFilePath)
        do {
            try FileManager.default.moveItem(atPath: tempPath, toPath: Self.colorFilePath)
        } catch {
            let buddyError = BuddyError.colorFileWriteFailed(path: Self.colorFilePath, reason: error.localizedDescription)
            BuddyLogger.shared.error("colorFileWriteFailed", subsystem: "session", meta: [
                "path": Self.colorFilePath, "error": buddyError.description
            ])
        }
    }

    // MARK: - Message Handling

    func handle(message: HookMessage) {
        let sessionId = message.sessionId

        switch message.event {
        case .sessionEnd:
            if let session = sessions[sessionId] {
                BuddyLogger.shared.info("session ended", subsystem: "session", meta: [
                    "session_id": sessionId,
                    "label": session.label,
                ])
                eventStore.record(StoredEvent(
                    timestamp: Date(), type: "session_ended", sessionId: sessionId,
                    details: ["label": session.label, "color": "\(session.color)"]
                ))
                // 先移除会话再回收颜色——releaseColor 精确回收（C-COLOR-REUSE）以
                // 「无其他持有者」为条件，垂死会话自身不得计入持有者
                sessions.removeValue(forKey: sessionId)
                releaseColor(session.color)
                pendingTerminalIds.removeValue(forKey: sessionId)
                scene.removeCat(sessionId: sessionId)
                writeColorFile()
            }

        case .setLabel:
            if let label = message.label {
                eventStore.record(StoredEvent(
                    timestamp: Date(), type: "label_changed", sessionId: sessionId,
                    details: ["new_label": label]
                ))
                sessions[sessionId]?.label = label
                scene.updateCatLabel(sessionId: sessionId, label: label)
                writeColorFile()
            }

        case .setTokens:
            if let tokens = message.totalTokens {
                sessions[sessionId]?.totalTokens = tokens
            }

        default:
            // Create session on first message
            if sessions[sessionId] == nil {
                let color = assignColor()
                let label = generateLabel(from: message.cwd)
                let info = SessionInfo(
                    sessionId: sessionId,
                    label: label,
                    color: color,
                    cwd: message.cwd,
                    pid: message.pid,
                    // C-HEADLESS-NO-TERMINAL（创建分支）：不直接存储 hook terminal_id
                    // （判型 headless 时该值是兜底污染源），暂存 pendingTerminalIds 待判型处置
                    terminalId: nil,
                    state: message.entityState ?? .idle,
                    lastActivity: Date(),
                    toolDescription: message.description,
                    model: nil,
                    startedAt: nil,
                    totalTokens: 0,
                    toolCallCount: 0
                )
                sessions[sessionId] = info
                BuddyLogger.shared.info("session started", subsystem: "session", meta: [
                    "session_id": sessionId,
                    "label": label,
                    "cwd": message.cwd ?? "",
                ])

                eventStore.record(StoredEvent(
                    timestamp: Date(), type: "session_started", sessionId: sessionId,
                    details: ["label": label, "color": "\(color)", "cwd": message.cwd ?? ""]
                ))

                // C-HEADLESS-NO-TERMINAL（创建分支）：terminal_id 不直接存储，暂存待判型；
                // 判定 interactive 后应用并触发 tab title，判定 headless 后丢弃。
                if let tid = message.terminalId {
                    pendingTerminalIds[sessionId] = tid
                }

                // 旧 `activeCatCount < 8` 上屏门禁删除（C-NO-CAP）。
                // 上屏改由判型结果驱动：pending 期间不上猫（防闪猫，C-HEADLESS-NOCAT），
                // 检测链落定后按类型处置（见 applyHeadlessDetection）。
                scheduleHeadlessDetection(for: sessionId)
                writeColorFile()
                if let pid = info.pid {
                    sessions[sessionId]?.startedAt = TranscriptReader.readStartedAt(pid: pid)
                }
            } else {
                sessions[sessionId]?.lastActivity = Date()
                enrichCwd(for: sessionId, from: message)
                if sessions[sessionId]?.pid == nil, let pid = message.pid {
                    sessions[sessionId]?.pid = pid
                }
                // C-HEADLESS-NO-TERMINAL（更新分支，dual-path 双堵）：
                // 仅 interactive 会话存储并触发 tab title；pending 暂存；headless 一律不存储。
                if sessions[sessionId]?.terminalId == nil, let tid = message.terminalId {
                    switch sessions[sessionId]?.headlessState ?? .pending {
                    case .interactive:
                        sessions[sessionId]?.terminalId = tid
                        if let updated = sessions[sessionId] {
                            onSessionNeedsTabTitle?(updated)
                        }
                    case .pending:
                        pendingTerminalIds[sessionId] = tid
                    case .headless:
                        break   // 不存储、不触发 tab title 同步
                    }
                }
            }

            // Update state
            if let entityState = message.entityState {
                sessions[sessionId]?.state = entityState
                // Pass description for permission request display
                let desc = message.description ?? message.tool
                sessions[sessionId]?.toolDescription = desc

                eventStore.record(StoredEvent(
                    timestamp: Date(), type: "state_changed", sessionId: sessionId,
                    details: ["new_state": entityState.rawValue, "tool_description": desc ?? ""]
                ))

                scene.updateCatState(sessionId: sessionId, state: catState(from: entityState), toolDescription: desc)
                // Publish to EventBus for future subscribers
                // isHeadless 供 NotificationManager 过滤（C-NO-NOTIFY：后台任务不产生系统通知）
                EventBus.shared.stateChanged.send(StateChangeEvent(
                    sessionId: sessionId, newState: entityState, toolDescription: desc,
                    label: sessions[sessionId]?.label,
                    isHeadless: sessions[sessionId]?.isHeadless ?? false
                ))
            }

            // Increment tool call count
            if message.event == .toolStart {
                sessions[sessionId]?.toolCallCount += 1
            }

            // Food spawn trigger on toolEnd
            if message.event == .toolEnd {
                let roll = Float.random(in: 0..<1)
                if roll < FoodManager.toolEndSpawnProbability {
                    let catX = scene.catPosition(for: sessionId)
                    BuddyLogger.shared.debug("toolEndSpawn food", subsystem: "session", meta: [
                        "session": sessionId, "x": catX ?? 0
                    ])
                    scene.spawnFood(near: catX)
                }
            }
        }

        onSessionCountChanged?(scene.activeCatCount)
        onSessionsChanged?(Array(sessions.values))

        // Throttled transcript scan (at most once every 10 seconds)
        let now = Date()
        if now.timeIntervalSince(lastTranscriptScan) >= 10 {
            lastTranscriptScan = now
            let sessionsSnapshot = sessions
            DispatchQueue.global(qos: .utility).async { [weak self] in
                var updated = false
                for (id, info) in sessionsSnapshot {
                    guard let cwd = info.cwd else { continue }
                    let path = TranscriptReader.transcriptPath(cwd: cwd, sessionId: info.sessionId)
                    let stats = TranscriptReader.scan(path: path)
                    if stats.model != nil || stats.totalTokens > 0 {
                        DispatchQueue.main.async {
                            self?.sessions[id]?.model = stats.model
                            self?.sessions[id]?.totalTokens = stats.totalTokens
                        }
                        updated = true
                    }
                }
                if updated {
                    DispatchQueue.main.async {
                        guard let self = self else { return }
                        self.onSessionsChanged?(Array(self.sessions.values))
                    }
                }
            }
        }
    }

    // MARK: - Headless Detection Chain（C-HEADLESS-DETECT）

    /// 检测链落定结果（SessionInfo.headlessState 之外还需携带 pid/procStart 富化数据）
    private enum HeadlessDetectionOutcome {
        case interactive(pid: Int?, procStart: String?)
        case headless(pid: Int?, procStart: String?)
        case dead(pid: Int?, procStart: String?)
    }

    /// 新会话判型链（后台执行）：注册表反查 pid（内部带 0.5s×4 重试）→ ps argv 判型 →
    /// 主线程落定。resolve 失败（文件缺失/无 pid）→ fail-open interactive。
    /// 每 session 至多检测一次，结果缓存于 SessionInfo.headlessState。
    private func scheduleHeadlessDetection(for sessionId: String) {
        let resolver = headlessResolver
        let checker = headlessChecker
        headlessDetectionsInFlight += 1
        Task.detached { [weak self] in
            guard let entry = await resolver.resolveEntry(pidFor: sessionId) else {
                // 注册表文件缺失/无 pid → fail-open 非 headless（CLI/调试会话同路径）
                self?.finishHeadlessDetection(
                    sessionId: sessionId, outcome: .interactive(pid: nil, procStart: nil))
                return
            }
            switch checker.check(pid: entry.pid) {
            case .headless:
                self?.finishHeadlessDetection(
                    sessionId: sessionId, outcome: .headless(pid: entry.pid, procStart: entry.procStart))
            case .processDead:
                // ESRCH → 判 dead：不上猫，按 C-HEADLESS-CLEANUP 直接清理
                self?.finishHeadlessDetection(
                    sessionId: sessionId, outcome: .dead(pid: entry.pid, procStart: entry.procStart))
            case .interactive, .unknown:
                // unknown（ps 失败等）→ fail-open 非 headless
                self?.finishHeadlessDetection(
                    sessionId: sessionId, outcome: .interactive(pid: entry.pid, procStart: entry.procStart))
            }
        }
    }

    private func finishHeadlessDetection(sessionId: String, outcome: HeadlessDetectionOutcome) {
        DispatchQueue.main.async { [weak self] in
            self?.applyHeadlessDetection(sessionId: sessionId, outcome: outcome)
        }
    }

    /// 检测落定（主线程）：headlessState 已非 pending 则忽略（每 session 至多一次）。
    private func applyHeadlessDetection(sessionId: String, outcome: HeadlessDetectionOutcome) {
        headlessDetectionsInFlight -= 1

        // 会话在检测期间已结束 → 无处落定
        guard var info = sessions[sessionId] else { return }
        guard info.headlessState == .pending else { return }

        switch outcome {
        case .headless(let pid, let procStart):
            info.headlessState = .headless
            if info.pid == nil { info.pid = pid }
            if info.procStart == nil { info.procStart = procStart }
            sessions[sessionId] = info
            // C-HEADLESS-NOCAT：不上猫、不触发对其他猫的驱逐
            // C-HEADLESS-NO-TERMINAL：暂存的 terminal_id 一律丢弃
            pendingTerminalIds.removeValue(forKey: sessionId)
            BuddyLogger.shared.info("session classified headless", subsystem: "session", meta: [
                "session_id": sessionId,
                "pid": pid ?? -1,
            ])

        case .interactive(let pid, let procStart):
            info.headlessState = .interactive
            if info.pid == nil { info.pid = pid }
            if info.procStart == nil { info.procStart = procStart }
            sessions[sessionId] = info
            // 交互会话（含 fail-open）上屏；补放 pending 期间错过的状态迁移
            // （handle() 时猫不存在，updateCatState 是 no-op）
            scene.addCat(info: info)
            scene.updateCatState(
                sessionId: sessionId,
                state: catState(from: info.state),
                toolDescription: info.toolDescription)
            // 暂存的 terminal_id 应用并触发 tab title（C-HEADLESS-NO-TERMINAL 唯一放行点）
            if let tid = pendingTerminalIds.removeValue(forKey: sessionId), info.terminalId == nil {
                sessions[sessionId]?.terminalId = tid
                if let updated = sessions[sessionId] {
                    onSessionNeedsTabTitle?(updated)
                }
            }
            BuddyLogger.shared.info("session classified interactive", subsystem: "session", meta: [
                "session_id": sessionId,
                "pid": pid ?? -1,
                "fail_open": pid == nil ? "true" : "false",
            ])

        case .dead(let pid, _):
            // 检测时进程已死（ESRCH）：不上猫，按 C-HEADLESS-CLEANUP 直接清理
            // （先移除会话再回收颜色，同 C-COLOR-REUSE 精确回收前提）
            pendingTerminalIds.removeValue(forKey: sessionId)
            sessions.removeValue(forKey: sessionId)
            releaseColor(info.color)
            scene.removeCat(sessionId: sessionId)   // 防御性 no-op
            BuddyLogger.shared.info("session classified dead (ESRCH), removed", subsystem: "session", meta: [
                "session_id": sessionId,
                "pid": pid ?? -1,
            ])
        }

        onSessionCountChanged?(scene.activeCatCount)
        onSessionsChanged?(Array(sessions.values))
        writeColorFile()
    }

    // MARK: - Timeouts

    private func isProcessAlive(pid: Int) -> Bool {
        return kill(Int32(pid), 0) == 0 || errno == EPERM
    }

    /// headless 存活探测（C-HEADLESS-CLEANUP）：kill(pid,0) + procStart 比对防 pid 复用误报。
    /// 无 pid / ESRCH / procStart 与当前 pid 实际启动时间不一致（pid 已被复用）→ 视为死亡。
    private func isHeadlessProcessDead(_ session: SessionInfo) -> Bool {
        guard let pid = session.pid else { return true }
        guard isProcessAlive(pid: pid) else { return true }
        if let recorded = session.procStart, !recorded.isEmpty {
            if let current = headlessChecker.processStartTime(pid: pid), current != recorded {
                return true
            }
        }
        return false
    }

    func checkTimeouts() {
        let now = Date()
        var toRemove: [String] = []
        for (sessionId, session) in sessions {
            // C-HEADLESS-CLEANUP：headless 会话短路清理——idle（5 分钟无 hook 活动）即
            // kill(pid,0) 探测，进程死亡即移除（不受 30 分钟 removeTimeout 制约）；
            // 交互会话清理行为不变。
            if session.headlessState == .headless {
                guard now.timeIntervalSince(session.lastActivity) >= idleTimeout else { continue }
                sessions[sessionId]?.state = .idle   // popover 状态诚实显示（无猫，scene 调用省略）
                if isHeadlessProcessDead(session) {
                    toRemove.append(sessionId)
                }
                continue
            }
            let elapsed = now.timeIntervalSince(session.lastActivity)
            if elapsed >= removeTimeout {
                if let pid = session.pid, isProcessAlive(pid: pid) {
                    // Process still alive — keep the session, just ensure idle state
                    if session.state != .idle {
                        sessions[sessionId]?.state = .idle
                        scene.updateCatState(sessionId: sessionId, state: catState(from: .idle), toolDescription: nil)
                    }
                } else {
                    toRemove.append(sessionId)
                }
            } else if elapsed >= idleTimeout {
                sessions[sessionId]?.state = .idle
                scene.updateCatState(sessionId: sessionId, state: catState(from: .idle), toolDescription: nil)
            }
        }
        for sessionId in toRemove {
            if let session = sessions[sessionId] {
                // 先移除会话再回收颜色（C-COLOR-REUSE 精确回收前提）
                sessions.removeValue(forKey: sessionId)
                releaseColor(session.color)
            }
            scene.removeCat(sessionId: sessionId)
        }
        if !toRemove.isEmpty {
            writeColorFile()
            onSessionCountChanged?(scene.activeCatCount)
            onSessionsChanged?(Array(sessions.values))
        }
    }

    // MARK: - EntityState → CatState Bridge

    /// Converts EntityState to CatState for passing to BuddyScene/CatSprite.
    private func catState(from entityState: EntityState) -> CatState {
        switch entityState {
        case .idle:              return .idle
        case .thinking:          return .thinking
        case .toolUse:           return .toolUse
        case .permissionRequest: return .permissionRequest
        case .eating:            return .eating
        case .taskComplete:      return .taskComplete
        }
    }
}
