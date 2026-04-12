import Foundation
@testable import BuddyCore

/// Factory helpers shared across all SessionManager test classes.
enum TestHelpers {

    static func makeManager(scene: MockScene = MockScene()) -> (SessionManager, MockScene) {
        let manager = SessionManager(scene: scene)
        return (manager, scene)
    }

    static func makeMessage(
        sessionId: String = "test-session",
        event: String = "idle",
        cwd: String? = nil,
        pid: Int? = nil,
        terminalId: String? = nil,
        tool: String? = nil,
        description: String? = nil,
        label: String? = nil,
        timestamp: TimeInterval = 1_700_000_000
    ) -> HookMessage {
        var dict: [String: Any] = [
            "session_id": sessionId,
            "event": event,
            "timestamp": timestamp
        ]
        if let cwd = cwd { dict["cwd"] = cwd }
        if let pid = pid { dict["pid"] = pid }
        if let tid = terminalId { dict["terminal_id"] = tid }
        if let tool = tool { dict["tool"] = tool }
        if let desc = description { dict["description"] = desc }
        if let lbl = label { dict["label"] = lbl }
        let data = try! JSONSerialization.data(withJSONObject: dict)
        return try! JSONDecoder().decode(HookMessage.self, from: data)
    }
}
