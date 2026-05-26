import Foundation

struct PluginInput: Codable, Equatable {
    let query: String
    let sessionId: String   // UUID，每次唤起一个
    let cwd: String         // 用户当前工作目录
}
