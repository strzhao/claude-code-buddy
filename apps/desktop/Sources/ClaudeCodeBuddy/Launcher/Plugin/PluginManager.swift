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
            let disabledMarker = entry.appending(path: ".disabled")
            if FileManager.default.fileExists(atPath: disabledMarker.path) { continue }
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

    private func pluginDirURL(forName name: String) -> URL {
        rootDir.appending(path: name)
    }

    /// 创建 .disabled 标记文件；已禁用 no-op；目录不存在抛 pluginNotFound
    func disable(name: String) throws {
        let dir = pluginDirURL(forName: name)
        guard FileManager.default.fileExists(atPath: dir.path) else {
            throw LauncherError.pluginNotFound(name)
        }
        let marker = dir.appending(path: ".disabled")
        if !FileManager.default.fileExists(atPath: marker.path) {
            try Data().write(to: marker)
        }
    }

    /// 删除 .disabled 标记文件；未禁用 no-op；目录不存在抛 pluginNotFound
    func enable(name: String) throws {
        let dir = pluginDirURL(forName: name)
        guard FileManager.default.fileExists(atPath: dir.path) else {
            throw LauncherError.pluginNotFound(name)
        }
        let marker = dir.appending(path: ".disabled")
        if FileManager.default.fileExists(atPath: marker.path) {
            try FileManager.default.removeItem(at: marker)
        }
    }

    /// 扫描 rootDir，返回所有含 .disabled 标记的子目录名；rootDir 不存在返回 []
    func disabledNames() throws -> [String] {
        guard FileManager.default.fileExists(atPath: rootDir.path) else { return [] }
        let entries = try FileManager.default.contentsOfDirectory(
            at: rootDir,
            includingPropertiesForKeys: nil
        )
        var names: [String] = []
        for entry in entries {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: entry.path, isDirectory: &isDir),
                  isDir.boolValue else { continue }
            if FileManager.default.fileExists(atPath: entry.appending(path: ".disabled").path) {
                names.append(entry.lastPathComponent)
            }
        }
        return names
    }
}
