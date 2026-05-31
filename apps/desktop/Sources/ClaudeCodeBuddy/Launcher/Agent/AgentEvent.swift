import Foundation

/// Agent Loop 事件（流式 yield）
enum AgentEvent: Equatable {
    case text(String)                                       // 增量片段
    case toolCall(name: String, input: [String: AnyCodable])
    case toolResult(name: String, output: String, isError: Bool)
    case action(LauncherActionButton)                       // render-only 按钮声明（prompt mode meta tool）
    case done(reason: String)                              // "end_turn" / "max_tokens" / "max_iterations"
    case error(LauncherError)

    static func == (lhs: AgentEvent, rhs: AgentEvent) -> Bool {
        switch (lhs, rhs) {
        case (.text(let a), .text(let b)):
            return a == b
        case (.toolCall(let n1, let i1), .toolCall(let n2, let i2)):
            // 必须同时比较 name 和 input，避免假阳性（plan-reviewer BLOCKER-1 修复）
            // AnyCodable Equatable 已通过 JSONEncoder 字节级比较实现
            return n1 == n2 && i1 == i2
        case (.toolResult(let n1, let o1, let e1), .toolResult(let n2, let o2, let e2)):
            return n1 == n2 && o1 == o2 && e1 == e2
        case (.action(let a), .action(let b)):
            return a == b
        case (.done(let a), .done(let b)):
            return a == b
        case (.error, .error):
            return true  // error 不严格比较，测试用 if-case 判别
        default:
            return false
        }
    }
}

/// Agent Loop 配置
struct AgentLoopConfig: Equatable {
    let maxIterations: Int
    let systemPrompt: String?

    static let `default` = AgentLoopConfig(maxIterations: 10, systemPrompt: nil)

    init(maxIterations: Int = 10, systemPrompt: String? = nil) {
        precondition(maxIterations >= 1 && maxIterations <= 20, "maxIterations must be in [1, 20]")
        self.maxIterations = maxIterations
        self.systemPrompt = systemPrompt
    }
}
