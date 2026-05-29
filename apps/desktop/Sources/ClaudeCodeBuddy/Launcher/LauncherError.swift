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
    case promptExecutorNotAvailable
    // task 004 追加：
    case pluginNotFound(String)
    case pluginMissingDependency(String)
    case pluginTimeout(Int)
    case pluginCrash(Int32, String)
    case pluginManifestInvalid(String)
    // task 006 追加：
    case pluginNotTrusted(String)
    // task 002 (market) 追加：PluginSourceResolver 用
    case pluginInvalid(String)

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
        case .promptExecutorNotAvailable:
            return "prompt mode plugin 无法执行：PromptExecutor 未实现（task 004）"
        case .pluginNotFound(let name):
            return "插件 \(name) 未安装"
        case .pluginMissingDependency(let bin):
            return "插件依赖的外部命令 \(bin) 未找到，请先安装"
        case .pluginTimeout(let sec):
            return "插件执行超过 \(sec) 秒未返回，已强制终止"
        case .pluginCrash(let code, let stderr):
            return "插件异常退出（退出码 \(code)）：\(stderr)"
        case .pluginManifestInvalid(let reason):
            return "plugin.json 格式无效：\(reason)"
        case .pluginNotTrusted(let name):
            return "插件 \(name) 未获信任授权，已拒绝执行"
        case .pluginInvalid(let reason):
            return "插件无效：\(reason)"
        }
    }
}
