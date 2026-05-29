import Foundation

final class PluginManager {
    static let shared = PluginManager()

    let rootDir: URL

    init(rootDir: URL = LauncherConstants.launcherPluginsDir) {
        self.rootDir = rootDir
    }

    /// 扫描 rootDir 子目录，返回所有合法 manifest（跳过非法目录，不抛错）
    func list() throws -> [PluginManifest] {
        guard FileManager.default.fileExists(atPath: rootDir.path) else { return [] }
        let entries = try FileManager.default.contentsOfDirectory(
            at: rootDir,
            includingPropertiesForKeys: nil
        )
        var manifests: [PluginManifest] = []
        for entry in entries {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: entry.path, isDirectory: &isDir),
                  isDir.boolValue else { continue }
            let manifestURL = entry.appending(path: "plugin.json")
            guard FileManager.default.fileExists(atPath: manifestURL.path) else {
                NSLog("[PluginManager] 跳过无 plugin.json 的目录: \(entry.lastPathComponent)")
                continue
            }
            do {
                let data = try Data(contentsOf: manifestURL)
                let manifest = try JSONDecoder().decode(PluginManifest.self, from: data)
                try manifest.validate(againstDirName: entry.lastPathComponent)
                manifests.append(manifest)
            } catch {
                NSLog("[PluginManager] 跳过无效 plugin.json (\(entry.lastPathComponent)): \(error)")
                continue
            }
        }
        return manifests
    }

    func find(name: String) throws -> PluginManifest? {
        try list().first { $0.name == name }
    }

    /// 用 manifest 定位插件目录（供 PluginExecutor.execute 调用）
    func pluginDir(for manifest: PluginManifest) throws -> URL {
        // 优先直接匹配（builtin-hello 目录名 == manifest.name）
        let direct = rootDir.appending(path: manifest.name)
        if FileManager.default.fileExists(atPath: direct.path) { return direct }
        // 后缀匹配（user-repo 目录，manifest.name == "repo"）
        let entries = try FileManager.default.contentsOfDirectory(
            at: rootDir,
            includingPropertiesForKeys: nil
        )
        if let match = entries.first(where: {
            $0.lastPathComponent.hasSuffix("-\(manifest.name)")
        }) {
            return match
        }
        throw LauncherError.pluginNotFound(manifest.name)
    }

    /// （task 010 retry 2 起停用）首次启动时把 bundled HelloPlugin 拷贝到 ~/.buddy/launcher-plugins/hello/
    /// 停用理由：示例插件 description 含通用词（stdin/stdout/markdown/示例），narrow 算法
    /// 在大量无关 query 下都将其排到候选首位，干扰真实使用。需要 demo 时用户手动 add 即可。
    /// 双保险：LauncherManager 已不再调用本方法；本方法内部也直接 return，防止其他路径意外触发。
    func installBundledPlugins() throws {
        return  // 直接返回，不再自动安装示例插件
    }

    /// 原始实现保留备份（未使用），如需恢复 demo 自动安装可调用此方法
    private func _installBundledPlugins_legacy() throws {
        try FileManager.default.createDirectory(
            at: rootDir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755]
        )

        // 用 ResourceBundle.bundle（不是 Bundle.module）—— 解决 .app 签名问题
        guard let bundleHelloURL = ResourceBundle.bundle.url(
            forResource: "HelloPlugin",
            withExtension: nil,
            subdirectory: "Plugins"
        ) else {
            NSLog("[PluginManager] bundled HelloPlugin 未找到（ResourceBundle.bundle 失败）")
            return
        }

        let targetDir = rootDir.appending(path: "builtin-hello")
        let targetManifest = targetDir.appending(path: "plugin.json")
        let sourceManifest = bundleHelloURL.appending(path: "plugin.json")

        // 幂等：比较 plugin.json 内容相等则跳过
        if FileManager.default.fileExists(atPath: targetManifest.path),
           let targetData = try? Data(contentsOf: targetManifest),
           let sourceData = try? Data(contentsOf: sourceManifest),
           targetData == sourceData {
            return
        }

        // 删除旧版本（如有），重新拷贝
        if FileManager.default.fileExists(atPath: targetDir.path) {
            try FileManager.default.removeItem(at: targetDir)
        }
        try FileManager.default.copyItem(at: bundleHelloURL, to: targetDir)

        // Bundle 资源是只读，hello.sh 拷贝后需手动赋执行权限
        let helloScript = targetDir.appending(path: "hello.sh")
        if FileManager.default.fileExists(atPath: helloScript.path) {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: helloScript.path
            )
        }
    }
}
