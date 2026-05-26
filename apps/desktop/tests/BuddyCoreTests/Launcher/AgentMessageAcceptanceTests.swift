import XCTest
import Security
import CryptoKit
@testable import BuddyCore

// MARK: - AgentMessageAcceptanceTests
//
// 验收测试：AgentMessage / AgentContent / AgentTool / AgentResponse Codable round-trip 契约
//
// 设计文档覆盖点（task 002 输出契约）：
//   A. AgentMessage(role:"user", content:[.text("hi")]) 编码后含 "role":"user" 和
//      "content":[{"type":"text","text":"hi"}]
//   B. AgentContent.toolUse 编码后含 type:"tool_use" + id + input
//   C. AgentContent.toolResult 编码后含 type:"tool_result" + tool_use_id + is_error
//   D. AgentTool 编码后 CodingKey 为 "input_schema"（不是 "inputSchema"）
//   E. AgentResponse 编码后含 "stop_reason"（不是 stopReason）+ usage 中 "input_tokens"/"output_tokens"
//   F. 全部结构体 encode → decode round-trip Equatable 一致
//   G. fixture JSON 解码还原对象（反向解码）
//
// 黑盒原则：只调公开 Codable API，不依赖内部实现细节。
// 测试 WILL NOT compile 直到蓝队合并实现 — 这是预期的 TDD 红灯。

final class AgentMessageAcceptanceTests: XCTestCase {

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }()
    private let decoder = JSONDecoder()

    // MARK: - A. AgentMessage 文本内容编码

    /// AgentMessage(role:"user", content:[.text("hi")]) 编码后 JSON 必须含
    /// "role":"user" 和 content 数组第一项含 "type":"text" + "text":"hi"。
    func test_agentMessage_textContent_encodesCorrectly() throws {
        // Given
        let msg = AgentMessage(role: "user", content: [.text("hi")])

        // When
        let data = try encoder.encode(msg)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        // Then
        XCTAssertEqual(json?["role"] as? String, "user",
                       "role 字段必须是 \"user\"")
        let contentArr = json?["content"] as? [[String: Any]]
        XCTAssertEqual(contentArr?.count, 1,
                       "content 数组必须有 1 项")
        XCTAssertEqual(contentArr?.first?["type"] as? String, "text",
                       "content[0].type 必须是 \"text\"")
        XCTAssertEqual(contentArr?.first?["text"] as? String, "hi",
                       "content[0].text 必须是 \"hi\"")
    }

    /// assistant role 消息编码后 role == "assistant"
    func test_agentMessage_assistantRole_encodesCorrectly() throws {
        let msg = AgentMessage(role: "assistant", content: [.text("Hello!")])
        let data = try encoder.encode(msg)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(json?["role"] as? String, "assistant",
                       "assistant role 必须编码为 \"assistant\"")
    }

    // MARK: - B. AgentContent.toolUse 编码

    /// toolUse 编码后含 "type":"tool_use" + "id":"t1" + "name":"weather" + "input":{"city":"sf"}
    func test_agentContent_toolUse_encodesCorrectly() throws {
        // Given
        let content = AgentContent.toolUse(
            id: "t1",
            name: "weather",
            input: ["city": AnyCodable("sf")]
        )
        let msg = AgentMessage(role: "assistant", content: [content])

        // When
        let data = try encoder.encode(msg)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let contentArr = json?["content"] as? [[String: Any]]
        let item = contentArr?.first

        // Then
        XCTAssertEqual(item?["type"] as? String, "tool_use",
                       "toolUse 必须编码 type=\"tool_use\"")
        XCTAssertEqual(item?["id"] as? String, "t1",
                       "toolUse id 必须是 \"t1\"")
        XCTAssertEqual(item?["name"] as? String, "weather",
                       "toolUse name 必须是 \"weather\"")
        let inputDict = item?["input"] as? [String: Any]
        XCTAssertEqual(inputDict?["city"] as? String, "sf",
                       "toolUse input.city 必须是 \"sf\"")
    }

    // MARK: - C. AgentContent.toolResult 编码

    /// toolResult 编码后含 "type":"tool_result" + "tool_use_id" + "is_error"
    func test_agentContent_toolResult_encodesCorrectly() throws {
        // Given
        let content = AgentContent.toolResult(
            toolUseId: "t1",
            content: "42°F",
            isError: false
        )
        let msg = AgentMessage(role: "user", content: [content])

        // When
        let data = try encoder.encode(msg)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let contentArr = json?["content"] as? [[String: Any]]
        let item = contentArr?.first

        // Then
        XCTAssertEqual(item?["type"] as? String, "tool_result",
                       "toolResult 必须编码 type=\"tool_result\"")
        XCTAssertEqual(item?["tool_use_id"] as? String, "t1",
                       "CodingKey 必须是 tool_use_id（不是 toolUseId）")
        XCTAssertEqual(item?["content"] as? String, "42°F",
                       "toolResult content 必须是 \"42°F\"")
        // is_error 是 false，验证字段存在且值正确
        XCTAssertEqual(item?["is_error"] as? Bool, false,
                       "CodingKey 必须是 is_error（不是 isError），值为 false")
    }

    // MARK: - D. AgentTool CodingKey 为 input_schema

    /// AgentTool 编码后 inputSchema → "input_schema"（CodingKey 契约）
    func test_agentTool_inputSchema_codingKey() throws {
        // Given
        let tool = AgentTool(
            name: "x",
            description: "y",
            inputSchema: ["type": AnyCodable("object")]
        )

        // When
        let data = try encoder.encode(tool)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        // Then
        XCTAssertNil(json?["inputSchema"],
                     "原始 Swift 属性名 inputSchema 不应出现在 JSON 中")
        let inputSchema = json?["input_schema"] as? [String: Any]
        XCTAssertNotNil(inputSchema,
                        "JSON 必须含 input_schema 字段（不是 inputSchema）")
        XCTAssertEqual(inputSchema?["type"] as? String, "object",
                       "input_schema.type 必须是 \"object\"")
        XCTAssertEqual(json?["name"] as? String, "x",
                       "name 字段必须是 \"x\"")
        XCTAssertEqual(json?["description"] as? String, "y",
                       "description 字段必须是 \"y\"")
    }

    // MARK: - E. AgentResponse 编码：stop_reason + input_tokens/output_tokens

    /// AgentResponse 编码后含 "stop_reason"（不是 stopReason）
    /// usage 含 "input_tokens" / "output_tokens"（不是驼峰命名）
    func test_agentResponse_stopReason_codingKey() throws {
        // Given
        let resp = AgentResponse(
            content: [.text("Hello!")],
            stopReason: "end_turn",
            usage: AgentUsage(inputTokens: 10, outputTokens: 20)
        )

        // When
        let data = try encoder.encode(resp)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        // Then
        XCTAssertNil(json?["stopReason"],
                     "驼峰 stopReason 不应出现在 JSON 中")
        XCTAssertEqual(json?["stop_reason"] as? String, "end_turn",
                       "CodingKey 必须是 stop_reason，值为 \"end_turn\"")

        let usage = json?["usage"] as? [String: Any]
        XCTAssertNotNil(usage, "usage 字段必须存在")
        XCTAssertNil(usage?["inputTokens"],
                     "驼峰 inputTokens 不应出现在 JSON 中")
        XCTAssertEqual(usage?["input_tokens"] as? Int, 10,
                       "CodingKey 必须是 input_tokens，值为 10")
        XCTAssertEqual(usage?["output_tokens"] as? Int, 20,
                       "CodingKey 必须是 output_tokens，值为 20")
    }

    /// AgentResponse.usage 为 nil 时 JSON 中 usage 字段编码行为（不崩溃）
    func test_agentResponse_nullUsage_encodesWithoutCrash() throws {
        let resp = AgentResponse(content: [.text("ok")], stopReason: "end_turn", usage: nil)
        let data = try encoder.encode(resp)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(json?["stop_reason"] as? String, "end_turn",
                       "stop_reason 必须正常编码即使 usage 为 nil")
    }

    // MARK: - F. Round-trip Equatable 验证

    /// AgentMessage text round-trip：encode 后 decode 结果 == 原始值
    func test_agentMessage_text_roundTrip() throws {
        // Given
        let original = AgentMessage(role: "user", content: [.text("hello world")])

        // When
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(AgentMessage.self, from: data)

        // Then: Equatable 精确断言（不只是 XCTAssertNotNil）
        XCTAssertEqual(decoded, original,
                       "AgentMessage text round-trip 必须 Equatable 相等")
    }

    /// AgentMessage toolUse round-trip
    func test_agentMessage_toolUse_roundTrip() throws {
        let original = AgentMessage(
            role: "assistant",
            content: [
                .toolUse(id: "call-1", name: "search", input: ["q": AnyCodable("swift")])
            ]
        )
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(AgentMessage.self, from: data)
        XCTAssertEqual(decoded, original,
                       "AgentMessage toolUse round-trip 必须 Equatable 相等")
    }

    /// AgentMessage toolResult round-trip
    func test_agentMessage_toolResult_roundTrip() throws {
        let original = AgentMessage(
            role: "user",
            content: [
                .toolResult(toolUseId: "call-1", content: "result text", isError: true)
            ]
        )
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(AgentMessage.self, from: data)
        XCTAssertEqual(decoded, original,
                       "AgentMessage toolResult round-trip 必须 Equatable 相等")
    }

    /// AgentTool round-trip
    func test_agentTool_roundTrip() throws {
        let original = AgentTool(
            name: "calculator",
            description: "Does math",
            inputSchema: [
                "type": AnyCodable("object"),
                "properties": AnyCodable(["a": ["type": "number"]])
            ]
        )
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(AgentTool.self, from: data)
        XCTAssertEqual(decoded, original,
                       "AgentTool round-trip 必须 Equatable 相等")
    }

    /// AgentResponse round-trip
    func test_agentResponse_roundTrip() throws {
        let original = AgentResponse(
            content: [.text("Sure!")],
            stopReason: "end_turn",
            usage: AgentUsage(inputTokens: 5, outputTokens: 15)
        )
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(AgentResponse.self, from: data)
        XCTAssertEqual(decoded, original,
                       "AgentResponse round-trip 必须 Equatable 相等")
    }

    // MARK: - G. fixture JSON 反向解码

    /// 从官方格式 fixture JSON 解码 AgentMessage（反向解码契约）
    func test_agentMessage_decodeFromFixtureJSON() throws {
        let json = """
        {
            "role": "user",
            "content": [
                { "type": "text", "text": "What is the weather?" }
            ]
        }
        """
        let data = json.data(using: .utf8)!
        let msg = try decoder.decode(AgentMessage.self, from: data)

        XCTAssertEqual(msg.role, "user", "role 必须解码为 \"user\"")
        XCTAssertEqual(msg.content.count, 1, "content 数组必须有 1 项")
        if case .text(let t) = msg.content[0] {
            XCTAssertEqual(t, "What is the weather?",
                           "text content 必须解码为原始文本")
        } else {
            XCTFail("content[0] 必须是 .text case")
        }
    }

    /// 从 Anthropic 响应 fixture JSON 解码 AgentResponse（含 stop_reason）
    func test_agentResponse_decodeFromFixtureJSON() throws {
        let json = """
        {
            "content": [
                { "type": "text", "text": "Hello!" }
            ],
            "stop_reason": "end_turn",
            "usage": {
                "input_tokens": 12,
                "output_tokens": 8
            }
        }
        """
        let data = json.data(using: .utf8)!
        let resp = try decoder.decode(AgentResponse.self, from: data)

        XCTAssertEqual(resp.stopReason, "end_turn",
                       "stop_reason 必须正确解码到 stopReason")
        XCTAssertEqual(resp.usage?.inputTokens, 12,
                       "input_tokens 必须解码到 inputTokens")
        XCTAssertEqual(resp.usage?.outputTokens, 8,
                       "output_tokens 必须解码到 outputTokens")
        if case .text(let t) = resp.content[0] {
            XCTAssertEqual(t, "Hello!", "content text 必须解码正确")
        } else {
            XCTFail("content[0] 必须是 .text case")
        }
    }

    /// 从 tool_use fixture JSON 解码 AgentContent.toolUse
    func test_agentContent_decodeToolUseFromFixtureJSON() throws {
        let json = """
        {
            "role": "assistant",
            "content": [
                {
                    "type": "tool_use",
                    "id": "toolu_01",
                    "name": "get_weather",
                    "input": { "location": "London" }
                }
            ]
        }
        """
        let data = json.data(using: .utf8)!
        let msg = try decoder.decode(AgentMessage.self, from: data)

        XCTAssertEqual(msg.content.count, 1)
        if case .toolUse(let id, let name, let input) = msg.content[0] {
            XCTAssertEqual(id, "toolu_01", "id 必须解码正确")
            XCTAssertEqual(name, "get_weather", "name 必须解码正确")
            XCTAssertEqual(input["location"]?.value as? String, "London",
                           "input.location 必须解码为 \"London\"")
        } else {
            XCTFail("content[0] 必须是 .toolUse case")
        }
    }

    /// 多种 content 类型混合 round-trip
    func test_agentMessage_mixedContent_roundTrip() throws {
        let original = AgentMessage(
            role: "user",
            content: [
                .text("Please check:"),
                .toolResult(toolUseId: "t0", content: "done", isError: false)
            ]
        )
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(AgentMessage.self, from: data)
        XCTAssertEqual(decoded, original,
                       "混合 content 类型 round-trip 必须 Equatable 相等")
    }
}
