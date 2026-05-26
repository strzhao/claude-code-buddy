import Foundation

/// AI 工具定义（用于 tool_use 功能）
struct AgentTool: Codable, Equatable {
    let name: String
    let description: String
    let inputSchema: [String: AnyCodable]

    private enum CodingKeys: String, CodingKey {
        case name, description
        case inputSchema = "input_schema"
    }
}
