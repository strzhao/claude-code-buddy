import Foundation

/// Handles query messages from the CLI and generates JSON responses.
/// Queries are distinguished from hook messages by the presence of an "action" field.
final class QueryHandler {
    private let sessionManager: SessionManager
    private let scene: any SceneControlling
    private let eventStore: EventStore

    init(sessionManager: SessionManager, scene: any SceneControlling, eventStore: EventStore) {
        self.sessionManager = sessionManager
        self.scene = scene
        self.eventStore = eventStore
    }

    // MARK: - Public

    /// Process a query and return the JSON response data.
    func handle(query: [String: Any]) -> Data {
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
