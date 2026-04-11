import Foundation

// MARK: - Event

enum HookEvent: String, Codable {
    case thinking   = "thinking"
    case toolStart  = "tool_start"
    case toolEnd    = "tool_end"
    case idle       = "idle"
    case sessionEnd = "session_end"
}

// MARK: - HookMessage

struct HookMessage: Codable {
    let sessionId: String
    let event: HookEvent
    let tool: String?
    let timestamp: TimeInterval

    enum CodingKeys: String, CodingKey {
        case sessionId  = "session_id"
        case event      = "event"
        case tool       = "tool"
        case timestamp  = "timestamp"
    }

    // MARK: - State Mapping

    /// Maps this hook event to a CatState (returns nil for session_end).
    var catState: CatState? {
        switch event {
        case .thinking:   return .thinking
        case .toolStart:  return .coding
        case .toolEnd:    return .thinking
        case .idle:       return .idle
        case .sessionEnd: return nil
        }
    }
}
