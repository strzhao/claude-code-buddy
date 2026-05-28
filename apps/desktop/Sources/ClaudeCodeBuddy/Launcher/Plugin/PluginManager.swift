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

    /// 用 manifest 定位插件目录（供 StdinExecutor.execute 调用）
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

    /// 首次启动时把 bundled plugins 拷贝到 ~/.buddy/launcher-plugins/
    /// 幂等：plugin.json 内容相等则跳过；不等则删旧拷新
    func installBundledPlugins() throws {
        try FileManager.default.createDirectory(
            at: rootDir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755]
        )
        try installBundledPlugin(bundleSubdir: "HelloPlugin", targetName: "builtin-hello")
        try installBundledPlugin(bundleSubdir: "TranslatePlugin", targetName: "builtin-translate")
    }

    // swiftlint:disable:next function_body_length
    private func installBundledPlugin(bundleSubdir: String, targetName: String) throws {
        guard let bundleDirURL = ResourceBundle.bundle.url(
            forResource: bundleSubdir,
            withExtension: nil,
            subdirectory: "Plugins"
        ) else {
            NSLog("[PluginManager] bundled \(bundleSubdir) 未找到（ResourceBundle.bundle 失败）")
            return
        }

        let targetDir = rootDir.appending(path: targetName)
        let targetManifest = targetDir.appending(path: "plugin.json")
        let sourceManifest = bundleDirURL.appending(path: "plugin.json")

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
        try FileManager.default.copyItem(at: bundleDirURL, to: targetDir)

        // 读 manifest 判断 mode：仅 stdin mode 需要 chmod 可执行文件
        guard let manifestData = try? Data(contentsOf: sourceManifest),
              let manifest = try? JSONDecoder().decode(PluginManifest.self, from: manifestData) else {
            NSLog("[PluginManager] \(bundleSubdir) plugin.json 无法解析，跳过 chmod")
            return
        }

        // Bundle 资源是只读，stdin mode 的脚本拷贝后需手动赋执行权限
        // prompt mode 无可执行文件，跳过 chmod（避免对不存在文件 setAttributes 抛异常）
        if case .stdin(let cfg) = manifest.modeConfig {
            let exeBaseName = (cfg.cmd as NSString).lastPathComponent
            let exePath = targetDir.appending(path: exeBaseName).path
            if FileManager.default.fileExists(atPath: exePath) {
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o755],
                    ofItemAtPath: exePath
                )
            }
        }
    }
}
