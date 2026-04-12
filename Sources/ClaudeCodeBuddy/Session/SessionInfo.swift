import Foundation

struct SessionInfo {
    let sessionId: String
    var label: String
    var color: SessionColor
    var cwd: String?
    var pid: Int?
    var terminalId: String?
    var state: EntityState
    var lastActivity: Date
    var toolDescription: String?
    var model: String?
    var startedAt: Date?
    var totalTokens: Int
    var toolCallCount: Int
}
