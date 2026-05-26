import XCTest
@testable import BuddyCore

final class AgentMessageTests: XCTestCase {

    // MARK: - AgentMessage Codable Round-trip

    func test_agentMessage_textContent_roundTrip() throws {
        let msg = AgentMessage(role: "user", content: [.text("Hello, world!")])
        let data = try JSONEncoder().encode(msg)
        let decoded = try JSONDecoder().decode(AgentMessage.self, from: data)
        XCTAssertEqual(decoded, msg)
    }

    func test_agentMessage_toolUseContent_roundTrip() throws {
        let input: [String: AnyCodable] = ["path": AnyCodable("/tmp/test.txt")]
        let msg = AgentMessage(role: "assistant", content: [
            .toolUse(id: "toolu_01", name: "Read", input: input)
        ])
        let data = try JSONEncoder().encode(msg)
        let decoded = try JSONDecoder().decode(AgentMessage.self, from: data)
        XCTAssertEqual(decoded, msg)
    }

    func test_agentMessage_toolResultContent_roundTrip() throws {
        let msg = AgentMessage(role: "user", content: [
            .toolResult(toolUseId: "toolu_01", content: "file contents", isError: false)
        ])
        let data = try JSONEncoder().encode(msg)
        let decoded = try JSONDecoder().decode(AgentMessage.self, from: data)
        XCTAssertEqual(decoded, msg)
    }

    // MARK: - AgentTool Codable Round-trip

    func test_agentTool_roundTrip() throws {
        let schema: [String: AnyCodable] = [
            "type": AnyCodable("object"),
            "properties": AnyCodable(["path": ["type": "string"] as [String: Any]])
        ]
        let tool = AgentTool(name: "Read", description: "Read a file", inputSchema: schema)
        let data = try JSONEncoder().encode(tool)
        let decoded = try JSONDecoder().decode(AgentTool.self, from: data)
        XCTAssertEqual(decoded.name, tool.name)
        XCTAssertEqual(decoded.description, tool.description)
    }

    func test_agentTool_inputSchemaKey_isSnakeCase() throws {
        let tool = AgentTool(name: "T", description: "D", inputSchema: ["type": AnyCodable("object")])
        let data = try JSONEncoder().encode(tool)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertNotNil(json?["input_schema"], "inputSchema should encode as 'input_schema'")
        XCTAssertNil(json?["inputSchema"], "camelCase key should not exist")
    }

    // MARK: - AgentResponse Codable Round-trip

    func test_agentResponse_roundTrip() throws {
        let resp = AgentResponse(
            content: [.text("I can help with that.")],
            stopReason: "end_turn",
            usage: AgentUsage(inputTokens: 10, outputTokens: 20)
        )
        let data = try JSONEncoder().encode(resp)
        let decoded = try JSONDecoder().decode(AgentResponse.self, from: data)
        XCTAssertEqual(decoded, resp)
    }

    func test_agentResponse_stopReasonKey_isSnakeCase() throws {
        let resp = AgentResponse(content: [], stopReason: "end_turn", usage: nil)
        let data = try JSONEncoder().encode(resp)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertNotNil(json?["stop_reason"], "stopReason should encode as 'stop_reason'")
    }

    func test_agentUsage_keys_areSnakeCase() throws {
        let usage = AgentUsage(inputTokens: 5, outputTokens: 10)
        let data = try JSONEncoder().encode(usage)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertNotNil(json?["input_tokens"])
        XCTAssertNotNil(json?["output_tokens"])
    }
}
