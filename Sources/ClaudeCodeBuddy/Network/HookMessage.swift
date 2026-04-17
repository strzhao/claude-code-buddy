import Foundation

// MARK: - Event

enum HookEvent: String, Codable {
    case sessionStart = "session_start"
    case thinking   = "thinking"
    case toolStart  = "tool_start"
    case toolEnd    = "tool_end"
    case idle       = "idle"
    case sessionEnd = "session_end"
    case setLabel   = "set_label"
    case permissionRequest = "permission_request"
    case taskComplete = "task_complete"
    case morph      = "morph"
}

// MARK: - HookMessage

struct HookMessage: Codable {
    let sessionId: String
    let event: HookEvent
    let tool: String?
    let timestamp: TimeInterval
    let cwd: String?
    let label: String?
    let pid: Int?
    let terminalId: String?
    let description: String?
    let mode: String?

    init(sessionId: String,
         event: HookEvent,
         tool: String?,
         timestamp: TimeInterval,
         cwd: String?,
         label: String?,
         pid: Int?,
         terminalId: String?,
         description: String?,
         mode: String? = nil) {
        self.sessionId = sessionId
        self.event = event
        self.tool = tool
        self.timestamp = timestamp
        self.cwd = cwd
        self.label = label
        self.pid = pid
        self.terminalId = terminalId
        self.description = description
        self.mode = mode
    }

    enum CodingKeys: String, CodingKey {
        case sessionId  = "session_id"
        case event      = "event"
        case tool       = "tool"
        case timestamp  = "timestamp"
        case cwd        = "cwd"
        case label      = "label"
        case pid        = "pid"
        case terminalId = "terminal_id"
        case description = "description"
        case mode       = "mode"
    }

    // MARK: - State Mapping

    /// Maps this hook event to an EntityState (returns nil for lifecycle-only events).
    var entityState: EntityState? {
        switch event {
        case .sessionStart: return nil
        case .thinking:   return .thinking
        case .toolStart:  return .toolUse
        case .toolEnd:    return .thinking
        case .idle:       return .idle
        case .sessionEnd: return nil
        case .setLabel:   return nil
        case .permissionRequest: return .permissionRequest
        case .taskComplete: return .taskComplete
        case .morph:      return nil
        }
    }
}
