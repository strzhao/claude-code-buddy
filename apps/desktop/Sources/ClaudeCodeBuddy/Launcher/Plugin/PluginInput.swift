import Foundation

struct PluginInput: Codable, Equatable {
    let query: String
    let sessionId: String   // UUID，每次唤起一个
    let cwd: String         // 用户当前工作目录
    /// 选中回调重入（C4）：插件首次查询为 nil；用户从候选列表选中某项后，框架以该候选的
    /// `LauncherCandidate.selection` 为此字段再次调用同一插件，插件据此路由执行（如 stop/start）。
    /// Codable 可选 → 老 JSON（无此键）解码不崩；Codable 编码时 nil 字段默认省略（向后兼容老插件）。
    /// **安全红线（C5）**：selection 仅标识字符串，禁含命令/路径；执行权留插件。
    let selection: String?

    /// 显式 init：selection 默认 nil，让现有 `PluginInput(query:sessionId:cwd:)` 调用点无需改动（向后兼容）。
    init(query: String, sessionId: String, cwd: String, selection: String? = nil) {
        self.query = query
        self.sessionId = sessionId
        self.cwd = cwd
        self.selection = selection
    }
}
