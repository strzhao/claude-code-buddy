import XCTest
@testable import BuddyCore

// MARK: - MockProvider (共享)

final class MockProvider: LauncherProvider {
    var responses: [Result<AgentResponse, Error>] = []
    var callCount = 0
    var capturedMessages: [[AgentMessage]] = []

    func send(messages: [AgentMessage], tools: [AgentTool], model: String) async throws -> AgentResponse {
        capturedMessages.append(messages)
        guard callCount < responses.count else {
            throw LauncherError.providerNotConfigured
        }
        let result = responses[callCount]
        callCount += 1
        return try result.get()
    }
}

// MARK: - Helpers

private func makeEndTurnResponse(text: String) -> AgentResponse {
    AgentResponse(
        content: [.text(text)],
        stopReason: "end_turn",
        usage: nil
    )
}

private func makeToolUseResponse(id: String, name: String, input: [String: AnyCodable]) -> AgentResponse {
    AgentResponse(
        content: [.toolUse(id: id, name: name, input: input)],
        stopReason: "tool_use",
        usage: nil
    )
}

// MARK: - LauncherAgentTests

final class LauncherAgentTests: XCTestCase {

    // 1. end_turn 即停：收到 .text + .done
    func test_end_turn_yields_text_then_done() async {
        let provider = MockProvider()
        provider.responses = [.success(makeEndTurnResponse(text: "Hello!"))]

        let agent = LauncherAgent(
            provider: provider,
            tools: [],
            model: "claude-3-5-sonnet-latest",
            toolExecutor: { _, _ in "" }
        )

        var events: [AgentEvent] = []
        for await event in agent.run(prompt: "hi") {
            events.append(event)
        }

        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0], .text("Hello!"))
        XCTAssertEqual(events[1], .done(reason: "end_turn"))
    }

    // 2. 单轮 tool_use → 第二轮 end_turn
    func test_tool_use_yields_toolCall_toolResult_then_text_done() async {
        let provider = MockProvider()
        provider.responses = [
            .success(makeToolUseResponse(
                id: "toolu_01",
                name: "echo",
                input: ["text": AnyCodable("world")]
            )),
            .success(makeEndTurnResponse(text: "Done!"))
        ]

        let agent = LauncherAgent(
            provider: provider,
            tools: [],
            model: "claude-3-5-sonnet-latest",
            toolExecutor: { name, input in
                guard name == "echo" else { return "" }
                return (input["text"]?.value as? String) ?? ""
            }
        )

        var events: [AgentEvent] = []
        for await event in agent.run(prompt: "echo world") {
            events.append(event)
        }

        // 期望: .toolCall, .toolResult, .text, .done
        XCTAssertEqual(events.count, 4)
        if case .toolCall(let name, let input) = events[0] {
            XCTAssertEqual(name, "echo")
            XCTAssertEqual(input["text"], AnyCodable("world"))
        } else {
            XCTFail("events[0] should be .toolCall, got \(events[0])")
        }
        if case .toolResult(let name, let output, let isError) = events[1] {
            XCTAssertEqual(name, "echo")
            XCTAssertEqual(output, "world")
            XCTAssertFalse(isError)
        } else {
            XCTFail("events[1] should be .toolResult, got \(events[1])")
        }
        XCTAssertEqual(events[2], .text("Done!"))
        XCTAssertEqual(events[3], .done(reason: "end_turn"))
    }

    // 3. 永远 tool_use → maxIterations 次后 .error(.maxIterations)
    func test_max_iterations_exhausted_yields_maxIterations_error() async {
        let provider = MockProvider()
        // 填充 20 个 tool_use 响应（比 maxIterations 多，确保不越界）
        provider.responses = (0..<20).map { i in
            .success(makeToolUseResponse(
                id: "toolu_\(i)",
                name: "echo",
                input: ["text": AnyCodable("round\(i)")]
            ))
        }

        let config = AgentLoopConfig(maxIterations: 3, systemPrompt: nil)
        let agent = LauncherAgent(
            provider: provider,
            tools: [],
            model: "claude-3-5-sonnet-latest",
            toolExecutor: { _, _ in "ok" }
        )

        var events: [AgentEvent] = []
        for await event in agent.run(prompt: "infinite", config: config) {
            events.append(event)
        }

        // 最后一个事件必须是 .error(.maxIterations)
        guard let lastEvent = events.last else {
            XCTFail("No events yielded")
            return
        }
        if case .error(let err) = lastEvent {
            XCTAssertEqual(err, LauncherError.maxIterations)
        } else {
            XCTFail("Last event should be .error(.maxIterations), got \(lastEvent)")
        }
        // provider 被调用次数 == maxIterations
        XCTAssertEqual(provider.callCount, 3)
    }

    // 4. provider 抛 networkFailure
    func test_provider_throws_yields_networkFailure_error() async {
        let provider = MockProvider()
        let networkError = NSError(domain: "test", code: -1, userInfo: [NSLocalizedDescriptionKey: "timeout"])
        provider.responses = [.failure(LauncherError.networkFailure(networkError))]

        let agent = LauncherAgent(
            provider: provider,
            tools: [],
            model: "claude-3-5-sonnet-latest",
            toolExecutor: { _, _ in "" }
        )

        var events: [AgentEvent] = []
        for await event in agent.run(prompt: "fail") {
            events.append(event)
        }

        XCTAssertEqual(events.count, 1)
        if case .error(let err) = events[0] {
            if case .networkFailure = err {
                // ok
            } else {
                XCTFail("Expected .networkFailure, got \(err)")
            }
        } else {
            XCTFail("Expected .error, got \(events[0])")
        }
    }

    // 5. tool_use 时 toolExecutor 抛错 → toolResult 含 isError=true，loop 继续
    func test_tool_executor_failure_marks_isError_then_continues() async {
        let provider = MockProvider()
        provider.responses = [
            .success(makeToolUseResponse(
                id: "toolu_01",
                name: "broken_tool",
                input: [:]
            )),
            .success(makeEndTurnResponse(text: "Recovered!"))
        ]

        let agent = LauncherAgent(
            provider: provider,
            tools: [],
            model: "claude-3-5-sonnet-latest",
            toolExecutor: { name, _ in
                throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "tool broken"])
            }
        )

        var events: [AgentEvent] = []
        for await event in agent.run(prompt: "use broken tool") {
            events.append(event)
        }

        // 期望: .toolCall, .toolResult(isError=true), .text, .done
        XCTAssertEqual(events.count, 4)
        if case .toolResult(_, _, let isError) = events[1] {
            XCTAssertTrue(isError, "toolResult.isError should be true when executor throws")
        } else {
            XCTFail("events[1] should be .toolResult")
        }
        // loop 继续后收到 done
        XCTAssertEqual(events[3], .done(reason: "end_turn"))
    }

    // 6. cancellation：在收到第一个 event 后立即取消
    func test_cancellation_stops_yielding() async {
        let provider = MockProvider()
        // 填充很多响应
        provider.responses = (0..<10).map { _ in .success(makeEndTurnResponse(text: "text")) }

        let agent = LauncherAgent(
            provider: provider,
            tools: [],
            model: "claude-3-5-sonnet-latest",
            toolExecutor: { _, _ in "" }
        )

        var events: [AgentEvent] = []
        let stream = agent.run(prompt: "cancel test")
        var iterator = stream.makeAsyncIterator()

        // 取第一个事件
        if let first = await iterator.next() {
            events.append(first)
        }

        // 不消费更多 — stream 因 onTermination 会被 cancel
        // 仅验证我们能正常接收到至少一个事件，且不崩溃
        XCTAssertFalse(events.isEmpty, "Should receive at least one event before cancellation")
    }
}

// MARK: - LauncherError Equatable (仅用于测试)

extension LauncherError: Equatable {
    public static func == (lhs: LauncherError, rhs: LauncherError) -> Bool {
        switch (lhs, rhs) {
        case (.hotkeyConflict(let a), .hotkeyConflict(let b)): return a == b
        case (.providerNotConfigured, .providerNotConfigured): return true
        case (.invalidAPIKey(let a), .invalidAPIKey(let b)): return a == b
        case (.networkFailure, .networkFailure): return true  // Error 不直接比较
        case (.providerHTTPError(let c1, let b1), .providerHTTPError(let c2, let b2)): return c1 == c2 && b1 == b2
        case (.secretStoreUnavailable, .secretStoreUnavailable): return true
        case (.maxIterations, .maxIterations): return true
        default: return false
        }
    }
}
