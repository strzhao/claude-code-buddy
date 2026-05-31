import XCTest
@testable import BuddyCore

// MARK: - SSELineParserAcceptanceTests
//
// 红队验收测试：P1 — SSE 行级 parser（OpenAICompatibleProvider.parseSSELines）
//
// 设计文档契约：
//   - 跳过空行 / 非 "data: " 开头行
//   - `data: [DONE]` → yield .done(reason: "stop") + finish
//   - `data: {"choices":[{"delta":{"content":"..."}}]}` → yield .text(content)
//   - delta.content 为 nil/空 → 不 yield
//   - 流自然结束（无 [DONE]）→ yield .done(reason: "stop") + finish
//
// 测试策略：
//   绕开 URLSession.AsyncBytes 的 mock 难题，把 SSE parser 抽成纯函数 parseSSELines，
//   用 AsyncStream<String> 直接 feed lines —— 不走网络、不走 URLProtocol、无 hang 风险。
//   每个测试都用 fulfillment(timeout:) 包裹防御性兜底。

final class SSELineParserAcceptanceTests: XCTestCase {

    /// 把 [String] 数组转成 AsyncStream<String>（按顺序 emit + finish）
    private func makeLineStream(_ lines: [String]) -> AsyncStream<String> {
        AsyncStream { continuation in
            for line in lines {
                continuation.yield(line)
            }
            continuation.finish()
        }
    }

    /// 收集 stream 全部 chunks（带 5s timeout，防御性）
    private func collectChunks(
        _ stream: AsyncThrowingStream<ProviderChunk, Error>,
        timeoutSec: Double = 5.0
    ) async throws -> [ProviderChunk] {
        try await withThrowingTaskGroup(of: [ProviderChunk].self) { group in
            group.addTask {
                var chunks: [ProviderChunk] = []
                for try await chunk in stream {
                    chunks.append(chunk)
                }
                return chunks
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeoutSec * 1_000_000_000))
                throw NSError(domain: "SSELineParserTest", code: -1,
                              userInfo: [NSLocalizedDescriptionKey: "collect timed out after \(timeoutSec)s"])
            }
            guard let result = try await group.next() else {
                throw NSError(domain: "SSELineParserTest", code: -2, userInfo: nil)
            }
            group.cancelAll()
            return result
        }
    }

    // MARK: - P1-A: 多 chunk 顺序保持 + 累积内容正确

    /// 3 个 delta chunk + DONE → yield 3 个 .text + 1 个 .done，顺序与累积正确
    func test_parseSSELines_multiChunks_preserveOrderAndAccumulate() async throws {
        let lines = [
            #"data: {"choices":[{"delta":{"content":"Hello"}}]}"#,
            #"data: {"choices":[{"delta":{"content":" world"}}]}"#,
            #"data: {"choices":[{"delta":{"content":"!"}}]}"#,
            "data: [DONE]"
        ]
        let stream = OpenAICompatibleProvider.parseSSELines(makeLineStream(lines))
        let chunks = try await collectChunks(stream)

        // 提取 text + done
        var texts: [String] = []
        var doneCount = 0
        for c in chunks {
            switch c {
            case .text(let s): texts.append(s)
            case .action: break
            case .done: doneCount += 1
            }
        }
        XCTAssertEqual(texts, ["Hello", " world", "!"], "chunks 顺序必须保持")
        XCTAssertEqual(texts.joined(), "Hello world!", "累积内容必须等于 delta.content 拼接")
        XCTAssertEqual(doneCount, 1, "应有恰好 1 个 .done chunk")
    }

    // MARK: - P1-B: [DONE] 后 stream 正确 finish（不 hang）

    /// [DONE] 之后 stream 必须正常 finish（不挂起）— 用 timeout 保护
    func test_parseSSELines_afterDONE_streamFinishes() async throws {
        let lines = [
            #"data: {"choices":[{"delta":{"content":"finite"}}]}"#,
            "data: [DONE]"
        ]
        let stream = OpenAICompatibleProvider.parseSSELines(makeLineStream(lines))
        let chunks = try await collectChunks(stream, timeoutSec: 2.0)
        XCTAssertGreaterThanOrEqual(chunks.count, 2, "至少应收 1 text + 1 done")
        // 最后一个必须是 .done
        if case .done = chunks.last { /* OK */ } else {
            XCTFail("[DONE] 后最后一个 chunk 必须是 .done")
        }
    }

    // MARK: - P1-C: delta.content 为 nil/空 时不 yield .text

    /// role-only chunk（无 content）+ 空字符串 chunk + 有效 chunk → 只 yield 1 个 text
    func test_parseSSELines_emptyDeltaContent_notYielded() async throws {
        let lines = [
            #"data: {"choices":[{"delta":{"role":"assistant"}}]}"#,    // 无 content
            #"data: {"choices":[{"delta":{"content":""}}]}"#,           // 空字符串
            #"data: {"choices":[{"delta":{"content":"real"}}]}"#,       // 有效
            "data: [DONE]"
        ]
        let stream = OpenAICompatibleProvider.parseSSELines(makeLineStream(lines))
        let chunks = try await collectChunks(stream)

        let texts: [String] = chunks.compactMap { if case .text(let s) = $0 { return s }; return nil }
        XCTAssertEqual(texts, ["real"], "delta.content 为空/nil 不应 yield，只 yield 非空内容")
    }

    // MARK: - P1-D: 跳过空行和非 "data: " 开头

    /// SSE 流可能含 keep-alive 空行、event: 等其他字段 → 必须跳过
    func test_parseSSELines_skipsEmptyLinesAndNonDataLines() async throws {
        let lines = [
            "",                                                          // 空行
            "event: ping",                                               // 非 data 开头
            ": this is a comment",                                       // 注释
            #"data: {"choices":[{"delta":{"content":"X"}}]}"#,
            "",
            "data: [DONE]"
        ]
        let stream = OpenAICompatibleProvider.parseSSELines(makeLineStream(lines))
        let chunks = try await collectChunks(stream)
        let texts: [String] = chunks.compactMap { if case .text(let s) = $0 { return s }; return nil }
        XCTAssertEqual(texts, ["X"], "应只 yield 有效 data: 行的内容")
    }

    // MARK: - P1-E: 流自然结束（无 [DONE]）也要 yield .done + finish

    /// 服务端意外断开（无 [DONE]）→ parseSSELines 应兜底 yield .done + finish，不 hang
    func test_parseSSELines_streamEndsWithoutDONE_yieldsDoneAndFinishes() async throws {
        let lines = [
            #"data: {"choices":[{"delta":{"content":"partial"}}]}"#
            // 注意：没有 [DONE]，lines stream 直接结束
        ]
        let stream = OpenAICompatibleProvider.parseSSELines(makeLineStream(lines))
        let chunks = try await collectChunks(stream, timeoutSec: 2.0)
        XCTAssertEqual(chunks.count, 2, "应有 1 text + 1 自然结束的 done")
        if case .text(let s) = chunks[0] { XCTAssertEqual(s, "partial") }
        if case .done = chunks[1] { /* OK */ } else {
            XCTFail("流结束后必须 yield .done 兜底")
        }
    }

    // MARK: - P1-F: 损坏的 JSON 行被静默跳过，不影响后续

    /// 中间有一行非法 JSON → 跳过该行，后续有效行仍能被 yield
    func test_parseSSELines_invalidJSON_silentlySkipped() async throws {
        let lines = [
            #"data: {"choices":[{"delta":{"content":"ok1"}}]}"#,
            "data: {malformed json",                                     // 非法
            #"data: {"choices":[{"delta":{"content":"ok2"}}]}"#,
            "data: [DONE]"
        ]
        let stream = OpenAICompatibleProvider.parseSSELines(makeLineStream(lines))
        let chunks = try await collectChunks(stream)
        let texts: [String] = chunks.compactMap { if case .text(let s) = $0 { return s }; return nil }
        XCTAssertEqual(texts, ["ok1", "ok2"], "非法 JSON 行被跳过，前后有效行仍 yield")
    }

    // MARK: - P2: 流式 tool_calls → attach_action 按钮（render-only meta tool）

    /// 单个 attach_action：首片带 name，后续片按 index 累积 arguments 碎片 →
    /// [DONE] 时解析成一个 .action(LauncherActionButton)。
    func test_parseSSELines_streamingToolCall_assembledIntoActionButton() async throws {
        // 模拟 OpenAI 流式 tool_call 分片：arguments 被拆成多段
        let lines = [
            #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"x","type":"function","function":{"name":"attach_action","arguments":"{\"kind\":\""}}]}}]}"#,
            #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"speak\",\"text\":\"buddy\""}}]}}]}"#,
            #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":",\"label\":\"🔊 朗读\"}"}}]}}]}"#,
            "data: [DONE]"
        ]
        let stream = OpenAICompatibleProvider.parseSSELines(makeLineStream(lines))
        let chunks = try await collectChunks(stream)
        let actions: [LauncherActionButton] = chunks.compactMap {
            if case .action(let b) = $0 { return b }; return nil
        }
        XCTAssertEqual(actions.count, 1, "应解析出 1 个按钮")
        XCTAssertEqual(actions.first?.kind, .speak)
        XCTAssertEqual(actions.first?.text, "buddy")
        XCTAssertEqual(actions.first?.label, "🔊 朗读")
    }

    /// 两个不同 index 的 tool_call 交错 → 各自累积 → 解析出 2 个按钮，保序。
    func test_parseSSELines_multipleToolCalls_byIndex() async throws {
        let lines = [
            #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"name":"attach_action","arguments":"{\"kind\":\"speak\",\"text\":\"hi\"}"}}]}}]}"#,
            #"data: {"choices":[{"delta":{"tool_calls":[{"index":1,"function":{"name":"attach_action","arguments":"{\"kind\":\"copy\",\"text\":\"你好\"}"}}]}}]}"#,
            "data: [DONE]"
        ]
        let stream = OpenAICompatibleProvider.parseSSELines(makeLineStream(lines))
        let chunks = try await collectChunks(stream)
        let actions: [LauncherActionButton] = chunks.compactMap {
            if case .action(let b) = $0 { return b }; return nil
        }
        XCTAssertEqual(actions.count, 2)
        XCTAssertEqual(actions[0].kind, .speak)
        XCTAssertEqual(actions[0].text, "hi")
        XCTAssertEqual(actions[1].kind, .copy)
        XCTAssertEqual(actions[1].text, "你好")
    }

    /// 未知 kind / 缺 text 的 tool_call → soft-fail 丢弃，不产生按钮，不崩。
    func test_parseSSELines_invalidToolCall_softFailDropped() async throws {
        let lines = [
            #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"name":"attach_action","arguments":"{\"kind\":\"explode\",\"text\":\"x\"}"}}]}}]}"#,
            #"data: {"choices":[{"delta":{"tool_calls":[{"index":1,"function":{"name":"attach_action","arguments":"{\"kind\":\"copy\"}"}}]}}]}"#,
            "data: [DONE]"
        ]
        let stream = OpenAICompatibleProvider.parseSSELines(makeLineStream(lines))
        let chunks = try await collectChunks(stream)
        let actions: [LauncherActionButton] = chunks.compactMap {
            if case .action(let b) = $0 { return b }; return nil
        }
        XCTAssertTrue(actions.isEmpty, "未知 kind 与缺 text 的 tool_call 应被丢弃")
    }
}
