import Foundation
import Combine

// MARK: - SessionManager

/// Bridges incoming socket messages to BuddyScene actions.
/// Also enforces session timeouts and manages per-session color/label identity.
class SessionManager {

    // MARK: - Properties

    private let scene: any SceneControlling
    private let server = SocketServer()
    private(set) var eventStore = EventStore()
    private var queryHandler: QueryHandler?

    // MARK: - Morph State (Step 4)

    private var currentMode: EntityMode = .cat
    private var modeStoreCancellable: AnyCancellable?
    /// Per-session last dispatched event — replayed into the new entity on hot-switch.
    private var lastEvents: [String: EntityInputEvent] = [:]
    /// True while a hot-switch is in flight — incoming messages are queued.
    private var isTransitioning = false
    private var queuedMessages: [HookMessage] = []

    /// Full session state keyed by sessionId.
    var sessions: [String: SessionInfo] = [:]

    /// Token per showcase-driven session. Bumped whenever a session is
    /// restarted or ended — pending cycle callbacks bail out if the token
    /// no longer matches.
    private var showcaseTokens: [String: UUID] = [:]

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

    // MARK: - Timeout Config

    /// After this interval with no messages, the cat reverts to idle.
    private let idleTimeout: TimeInterval   = 5 * 60    // 5 minutes
    /// After this interval, the session is auto-removed.
    private let removeTimeout: TimeInterval = 15 * 60   // 15 minutes

    // MARK: - Color File

    static let colorFilePath = "/tmp/claude-buddy-colors.json"

    // MARK: - Init

    init(scene: any SceneControlling) {
        self.scene = scene
    }

    // MARK: - Morph Binding (Step 4)

    /// Subscribe to EntityModeStore; hot-switch all entities when mode changes.
    func bind(modeStore: EntityModeStore) {
        currentMode = modeStore.current
        modeStoreCancellable = modeStore.publisher
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] newMode in
                self?.performHotSwitch(to: newMode)
            }
    }

    /// Drops the EntityModeStore subscription. Used by the relaunch flow:
    /// the caller is about to persist a new mode and restart the process,
    /// and we don't want the in-process hot-switch to race with the
    /// relaunch's exit animation.
    func unbindModeStore() {
        modeStoreCancellable?.cancel()
        modeStoreCancellable = nil
    }

    /// Spawns one debug session per RocketKind with a random state, so every
    /// variant is visible side-by-side for comparison. Only runs in rocket mode
    /// (morphs there first if not already). Running again resets the display.
    private func performShowcase(filter: RocketKind? = nil) {
        if currentMode != .rocket {
            EntityModeStore.shared.set(.rocket)
        }
        // Tear down all previous showcase sessions first so a filtered re-run
        // clears the other kinds rather than adding alongside them.
        for existing in sessions.keys where existing.hasPrefix("showcase-") {
            if let info = sessions[existing] { releaseColor(info.color) }
            sessions.removeValue(forKey: existing)
            lastEvents.removeValue(forKey: existing)
            showcaseTokens.removeValue(forKey: existing)
            scene.removeEntity(sessionId: existing)
        }
        let kinds: [RocketKind] = filter.map { [$0] } ?? RocketKind.allCases
        for kind in kinds {
            let sid = "showcase-\(kind.rawValue)"
            // Tear down any previous showcase session with this id. Bumping
            // the token invalidates any pending cycle callback from the
            // previous run.
            if sessions[sid] != nil {
                if let info = sessions[sid] { releaseColor(info.color) }
                sessions.removeValue(forKey: sid)
                lastEvents.removeValue(forKey: sid)
                showcaseTokens.removeValue(forKey: sid)
                scene.removeEntity(sessionId: sid)
            }
            EntityFactory.presetKind(sessionId: sid, kind: kind)

            let color = assignColor()
            let info = SessionInfo(
                sessionId: sid,
                label: kind.rawValue,
                color: color,
                cwd: "/tmp/showcase-\(kind.rawValue)",
                pid: nil,
                terminalId: nil,
                state: .idle,
                lastActivity: Date(),
                toolDescription: nil,
                model: nil,
                startedAt: nil,
                totalTokens: 0,
                toolCallCount: 0
            )
            sessions[sid] = info
            if scene.activeCatCount < 8 {
                scene.addEntity(info: info, mode: .rocket)
            }

            // Drive every showcase rocket through the same deterministic
            // cycle: OnPad → liftoff → abort (!) → resume → landing → loop.
            startShowcaseCycle(for: sid)
        }
        writeColorFile()
        onSessionCountChanged?(scene.activeCatCount)
        onSessionsChanged?(Array(sessions.values))
    }

    /// Fixed showcase cycle — (event, wait-before-next).
    /// The session starts in OnPad automatically on spawn; after the initial
    /// settle delay we emit `.userPromptSubmit` to lift off, then cycle forever.
    private static let showcaseCycleSteps: [(EntityInputEvent, TimeInterval)] = [
        // Settle on the pad before the first liftoff so the initial
        // state reads clearly.
        (.userPromptSubmit,                               5.0),  // liftoff → cruising
        (.permissionRequest(description: "Confirm"),      3.5),  // "!" abort
        (.toolStart(name: "Read", description: nil),      3.5),  // resume flight
        (.taskComplete,                                   6.0),  // land → OnPad (2.8s anim + settle)
    ]

    private func startShowcaseCycle(for sid: String) {
        let token = UUID()
        showcaseTokens[sid] = token
        // Initial on-pad dwell before the first event in the cycle.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            self?.advanceShowcaseCycle(sid: sid, token: token, step: 0)
        }
    }

    private func advanceShowcaseCycle(sid: String, token: UUID, step: Int) {
        // Bail if the session was torn down or a newer cycle was started.
        guard sessions[sid] != nil, showcaseTokens[sid] == token else { return }

        let steps = Self.showcaseCycleSteps
        let (event, wait) = steps[step % steps.count]
        lastEvents[sid] = event
        scene.dispatchEntityEvent(sessionId: sid, event: event)

        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            self?.advanceShowcaseCycle(sid: sid, token: token, step: step + 1)
        }
    }

    private func performHotSwitch(to newMode: EntityMode) {
        let prev = currentMode
        currentMode = newMode
        isTransitioning = true
        let infos = Array(sessions.values)
        scene.replaceAllEntities(
            with: newMode,
            infos: infos,
            lastEvents: lastEvents,
            onOldEntitiesExited: {
                // Fires between old entities fully exiting and new ones
                // spawning — emit the mode-change event HERE so BuddyScene
                // swaps the boundary dressing before new entities appear,
                // preventing the "tree-next-to-rocket" frame flash.
                EventBus.shared.entityModeChanged.send(
                    EntityModeChangeEvent(previous: prev, next: newMode)
                )
            }
        ) { [weak self] in
            guard let self = self else { return }
            self.isTransitioning = false
            let queued = self.queuedMessages
            self.queuedMessages.removeAll()
            for m in queued { self.handle(message: m) }
        }
    }

    // MARK: - Start / Stop

    func start() {
        // Clear stale color file on startup
        try? Data("{}".utf8).write(to: URL(fileURLWithPath: Self.colorFilePath))

        // Initialize query handler
        queryHandler = QueryHandler(sessionManager: self, scene: scene, eventStore: eventStore)

        server.onMessage = { [weak self] message in
            self?.handle(message: message)
        }

        server.onQuery = { [weak self] query, clientFD in
            guard let self = self, let handler = self.queryHandler else { return }
            let responseData = handler.handle(query: query)
            self.server.sendResponse(data: responseData, to: clientFD)
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

    // MARK: - Color Pool

    private func assignColor() -> SessionColor {
        for color in SessionColor.allCases where !usedColors.contains(color) {
            usedColors.insert(color)
            return color
        }
        return SessionColor.allCases[0]
    }

    private func releaseColor(_ color: SessionColor) {
        usedColors.remove(color)
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
                "label": info.label
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
            NSLog("[SessionManager] %@", buddyError.description)
        }
    }

    // MARK: - Message Handling

    func handle(message: HookMessage) {
        if isTransitioning {
            queuedMessages.append(message)
            return
        }
        let sessionId = message.sessionId

        switch message.event {
        case .morph:
            if let raw = message.mode, let mode = EntityMode(rawValue: raw) {
                EntityModeStore.shared.set(mode)
            }
            return

        case .showcase:
            let filter = message.label.flatMap { RocketKind(rawValue: $0) }
            performShowcase(filter: filter)
            return

        case .sessionEnd:
            if let session = sessions[sessionId] {
                eventStore.record(StoredEvent(
                    timestamp: Date(), type: "session_ended", sessionId: sessionId,
                    details: ["label": session.label, "color": "\(session.color)"]
                ))
                releaseColor(session.color)
                sessions.removeValue(forKey: sessionId)
                lastEvents.removeValue(forKey: sessionId)
                showcaseTokens.removeValue(forKey: sessionId)
                scene.removeEntity(sessionId: sessionId)
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
                    terminalId: message.terminalId,
                    state: message.entityState ?? .idle,
                    lastActivity: Date(),
                    toolDescription: message.description,
                    model: nil,
                    startedAt: nil,
                    totalTokens: 0,
                    toolCallCount: 0
                )
                sessions[sessionId] = info

                eventStore.record(StoredEvent(
                    timestamp: Date(), type: "session_started", sessionId: sessionId,
                    details: ["label": label, "color": "\(color)", "cwd": message.cwd ?? ""]
                ))

                if scene.activeCatCount < 8 {
                    scene.addEntity(info: info, mode: currentMode)
                }
                writeColorFile()
                if info.terminalId != nil {
                    onSessionNeedsTabTitle?(info)
                }
                if let pid = info.pid {
                    sessions[sessionId]?.startedAt = TranscriptReader.readStartedAt(pid: pid)
                }
            } else {
                sessions[sessionId]?.lastActivity = Date()
                enrichCwd(for: sessionId, from: message)
                if sessions[sessionId]?.pid == nil, let pid = message.pid {
                    sessions[sessionId]?.pid = pid
                }
                if sessions[sessionId]?.terminalId == nil, let tid = message.terminalId {
                    sessions[sessionId]?.terminalId = tid
                    if let updated = sessions[sessionId] {
                        onSessionNeedsTabTitle?(updated)
                    }
                }
            }

            // Build the generic EntityInputEvent and cache for hot-switch replay.
            let entityInput = EntityInputEvent.from(
                hookEvent: message.event,
                tool: message.tool,
                description: message.description
            )
            lastEvents[sessionId] = entityInput

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

                if currentMode == .cat {
                    scene.updateCatState(sessionId: sessionId, state: catState(from: entityState), toolDescription: desc)
                } else {
                    scene.dispatchEntityEvent(sessionId: sessionId, event: entityInput)
                }
                // Publish to EventBus for future subscribers
                EventBus.shared.stateChanged.send(StateChangeEvent(
                    sessionId: sessionId, newState: entityState, toolDescription: desc
                ))
            }

            // Increment tool call count
            if message.event == .toolStart {
                sessions[sessionId]?.toolCallCount += 1
            }

            // Food spawn trigger on toolEnd — only in cat mode.
            if message.event == .toolEnd, currentMode == .cat {
                let roll = Float.random(in: 0..<1)
                if roll < FoodManager.toolEndSpawnProbability {
                    let catX = scene.catPosition(for: sessionId)
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

    // MARK: - Timeouts

    func checkTimeouts() {
        let now = Date()
        var toRemove: [String] = []
        for (sessionId, session) in sessions {
            let elapsed = now.timeIntervalSince(session.lastActivity)
            if elapsed >= removeTimeout {
                toRemove.append(sessionId)
            } else if elapsed >= idleTimeout {
                sessions[sessionId]?.state = .idle
                scene.updateCatState(sessionId: sessionId, state: catState(from: .idle), toolDescription: nil)
            }
        }
        for sessionId in toRemove {
            if let session = sessions[sessionId] {
                releaseColor(session.color)
            }
            sessions.removeValue(forKey: sessionId)
            lastEvents.removeValue(forKey: sessionId)
            scene.removeEntity(sessionId: sessionId)
        }
        if !toRemove.isEmpty {
            writeColorFile()
            onSessionCountChanged?(scene.activeCatCount)
            onSessionsChanged?(Array(sessions.values))
        }
    }

    // MARK: - EntityState → CatState Bridge

    /// Converts EntityState to CatState for passing to BuddyScene/CatEntity.
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
