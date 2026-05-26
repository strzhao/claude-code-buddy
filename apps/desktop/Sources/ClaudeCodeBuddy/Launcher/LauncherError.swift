import Foundation

enum LauncherError: Error, LocalizedError {
    case hotkeyConflict(String)
    // task 002 追加：
    case providerNotConfigured
    case invalidAPIKey(String)              // 关联 reason: "missing" / "too short"
    case networkFailure(Error)
    case providerHTTPError(Int, String)     // status + body 前 200 字
    case secretStoreUnavailable
    // task 003 追加：
    case maxIterations

    var errorDescription: String? {
        switch self {
        case .hotkeyConflict(let combo):
            return "快捷键 \(combo) 被其他应用占用，请在设置中更改"
        case .providerNotConfigured:
            return "请先运行 `buddy launcher config set ...` 配置 provider"
        case .invalidAPIKey(let reason):
            return "API key 无效：\(reason)"
        case .networkFailure(let error):
            return "网络请求失败：\(error.localizedDescription)"
        case .providerHTTPError(let code, let body):
            return "Provider 返回 \(code)：\(body)"
        case .secretStoreUnavailable:
            return "无法安全存储 API key，请检查 ~/.buddy/ 权限"
        case .maxIterations:
            return "Agent 循环达到最大迭代次数（默认 10），可能存在递归 tool_use；请简化查询重试"
        }
    }
}
