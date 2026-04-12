import Foundation

// MARK: - SessionManager

/// Bridges incoming socket messages to BuddyScene actions.
/// Also enforces session timeouts and manages per-session color/label identity.
class SessionManager {

    // MARK: - Properties

    private let scene: BuddyScene
    private let server = SocketServer()

    /// Full session state keyed by sessionId.
    private var sessions: [String: SessionInfo] = [:]

    /// Tracks which colors are currently in use.
    private var usedColors: Set<SessionColor> = []

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

    init(scene: BuddyScene) {
        self.scene = scene
    }

    // MARK: - Start / Stop

    func start() {
        // Clear stale color file on startup
        try? "{}".data(using: .utf8)?.write(to: URL(fileURLWithPath: Self.colorFilePath))

        server.onMessage = { [weak self] message in
            self?.handle(message: message)
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

    // MARK: - Color Pool

    private func assignColor() -> SessionColor {
        for color in SessionColor.allCases {
            if !usedColors.contains(color) {
                usedColors.insert(color)
                return color
            }
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
        try? FileManager.default.removeItem(atPath: Self.colorFilePath)
        try? FileManager.default.moveItem(atPath: tempPath, toPath: Self.colorFilePath)
    }

    // MARK: - Message Handling

    private func handle(message: HookMessage) {
        let sessionId = message.sessionId

        switch message.event {
        case .sessionEnd:
            if let session = sessions[sessionId] {
                releaseColor(session.color)
                sessions.removeValue(forKey: sessionId)
                scene.removeCat(sessionId: sessionId)
                writeColorFile()
            }

        case .setLabel:
            if let label = message.label {
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

                if scene.activeCatCount < 8 {
                    scene.addCat(info: info)
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

            // Update state
            if let entityState = message.entityState {
                sessions[sessionId]?.state = entityState
                // Pass description for permission request display
                let desc = message.description ?? message.tool
                sessions[sessionId]?.toolDescription = desc
                scene.updateCatState(sessionId: sessionId, state: catState(from: entityState), toolDescription: desc)
                // Publish to EventBus for future subscribers
                EventBus.shared.stateChanged.send(StateChangeEvent(
                    sessionId: sessionId, newState: entityState, toolDescription: desc
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

    private func checkTimeouts() {
        let now = Date()
        var toRemove: [String] = []
        for (sessionId, session) in sessions {
            let elapsed = now.timeIntervalSince(session.lastActivity)
            if elapsed >= removeTimeout {
                toRemove.append(sessionId)
            } else if elapsed >= idleTimeout {
                sessions[sessionId]?.state = .idle
                scene.updateCatState(sessionId: sessionId, state: catState(from: .idle))
            }
        }
        for sessionId in toRemove {
            if let session = sessions[sessionId] {
                releaseColor(session.color)
            }
            sessions.removeValue(forKey: sessionId)
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
        }
    }
}
