import Foundation

struct PluginManifest: Codable, Equatable {
    let name: String
    let version: String
    let description: String
    let keywords: [String]
    let cmd: String               // 相对路径，禁止绝对路径
    let args: [String]
    let env: [String: String]?
    let timeout: Int?             // 秒，缺省 30，上限 120
    let requiredPath: [String]?   // 预检查外部 binary

    /// 字段校验（manifest 解析后立即执行）
    /// - 失败抛 LauncherError.pluginManifestInvalid(reason)
    func validate(againstDirName dirName: String) throws {
        // 1. name 与父目录名一致，或与目录名最后一段一致（user-repo → name=repo）
        let dirNameLastSegment = dirName.split(separator: "-").last.map(String.init) ?? dirName
        guard name == dirName || name == dirNameLastSegment else {
            throw LauncherError.pluginManifestInvalid("name '\(name)' 与目录名 '\(dirName)' 不一致")
        }
        // 2. cmd 必须是不含 .. 的相对路径
        guard !cmd.hasPrefix("/") else {
            throw LauncherError.pluginManifestInvalid("cmd '\(cmd)' 不能是绝对路径")
        }
        guard !cmd.contains("/.."), !cmd.contains("../") else {
            throw LauncherError.pluginManifestInvalid("cmd '\(cmd)' 不能包含 ..")
        }
        // 3. timeout 边界
        if let t = timeout {
            guard t >= 1, t <= LauncherConstants.pluginMaxTimeoutSec else {
                throw LauncherError.pluginManifestInvalid("timeout \(t) 必须在 [1, \(LauncherConstants.pluginMaxTimeoutSec)]")
            }
        }
        // 4. requiredPath 数组长度
        if let paths = requiredPath, paths.count > LauncherConstants.pluginRequiredPathMaxCount {
            throw LauncherError.pluginManifestInvalid("requiredPath 数组长度 \(paths.count) 超过上限 \(LauncherConstants.pluginRequiredPathMaxCount)")
        }
    }

    var effectiveTimeout: Int { timeout ?? LauncherConstants.pluginDefaultTimeoutSec }
}
