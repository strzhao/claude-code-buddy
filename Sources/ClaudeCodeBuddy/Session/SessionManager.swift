import Foundation

// MARK: - SessionManager

/// Bridges incoming socket messages to BuddyScene actions.
/// Also enforces session timeouts.
class SessionManager {

    // MARK: - Properties

    private let scene: BuddyScene
    private let server = SocketServer()

    /// Tracks the last-activity timestamp for each session.
    private var lastActivity: [String: Date] = [:]

    /// Called whenever the active session count changes.
    var onSessionCountChanged: ((Int) -> Void)?

    private var timeoutTimer: Timer?

    // MARK: - Timeout Config

    /// After this interval with no messages, the cat reverts to idle.
    private let idleTimeout: TimeInterval   = 5 * 60    // 5 minutes
    /// After this interval, the session is auto-removed.
    private let removeTimeout: TimeInterval = 15 * 60   // 15 minutes

    // MARK: - Init

    init(scene: BuddyScene) {
        self.scene = scene
    }

    // MARK: - Start / Stop

    func start() {
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

    // MARK: - Message Handling

    private func handle(message: HookMessage) {
        let sessionId = message.sessionId
        lastActivity[sessionId] = Date()

        switch message.event {
        case .sessionEnd:
            scene.removeCat(sessionId: sessionId)
            lastActivity.removeValue(forKey: sessionId)

        default:
            // Spawn cat on first message from this session
            if scene.activeCatCount < 8 {
                scene.addCat(sessionId: sessionId)
            }

            // Update state
            if let catState = message.catState {
                scene.updateCatState(sessionId: sessionId, state: catState)
            }
        }

        onSessionCountChanged?(scene.activeCatCount)
    }

    // MARK: - Timeouts

    private func checkTimeouts() {
        let now = Date()
        for (sessionId, lastSeen) in lastActivity {
            let elapsed = now.timeIntervalSince(lastSeen)
            if elapsed >= removeTimeout {
                scene.removeCat(sessionId: sessionId)
                lastActivity.removeValue(forKey: sessionId)
                onSessionCountChanged?(scene.activeCatCount)
            } else if elapsed >= idleTimeout {
                scene.updateCatState(sessionId: sessionId, state: .idle)
            }
        }
    }
}
