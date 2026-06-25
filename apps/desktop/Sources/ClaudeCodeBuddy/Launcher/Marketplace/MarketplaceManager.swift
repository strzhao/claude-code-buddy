import AppKit
import Foundation
import CryptoKit

// MARK: - MarketplaceInspection / MarketplaceMeta

/// inspect() 输出：marketplace cache + 目录扫描双视角。
///
/// - `plugins`: marketplace.json 中声明的插件（含官方 + 第三方）
/// - `sideloadedPlugins`: `~/.buddy/launcher-plugins/` 下未出现在 marketplace cache 中的目录（如 `buddy launcher add` 手动装的）
struct MarketplaceInspection: Codable, Equatable {
    let plugins: [PluginInspection]
    let sideloadedPlugins: [SideloadedInspection]
    let lastSyncedAt: Date?
    let consecutiveSyncFailures: Int

    struct PluginInspection: Codable, Equatable {
        let name: String
        let version: String
        let enabled: Bool        // !contains .disabled
        let source: String       // human-readable
        /// C6/M1：summary（降级后非空），从插件目录 plugin.json 运行时解析。
        /// 生产 inspect() 始终显式传值；默认空串仅为 Swift init 便利（不破坏旧测试 mock）。
        let summary: String
        /// C6/M1：description（详细，来自 plugin.json；读失败兜底空串）。
        let description: String

        /// 默认参数：summary/description 默认空串，让旧 mock 调用（仅传 name/version/enabled/source）仍可编译。
        /// 生产 inspect() 显式传运行时解析的真实值。
        init(name: String, version: String, enabled: Bool, source: String, summary: String = "", description: String = "") {
            self.name = name
            self.version = version
            self.enabled = enabled
            self.source = source
            self.summary = summary
            self.description = description
        }

        /// C1 降级 / 向后兼容：无 summary/description 的旧 inspect JSON 仍能 decode（decodeIfPresent 兜底空串）。
        /// 生产 inspect() 始终填 displaySummary（非空），此处仅容错外部/旧 JSON（红队 AT03）。
        private enum CodingKeys: String, CodingKey {  // swiftlint:disable:this nesting
            case name, version, enabled, source, summary, description
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decode(String.self, forKey: .name)
            version = try c.decode(String.self, forKey: .version)
            enabled = try c.decode(Bool.self, forKey: .enabled)
            source = try c.decode(String.self, forKey: .source)
            summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
            description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        }
    }

    struct SideloadedInspection: Codable, Equatable {
        let name: String
        let enabled: Bool
        /// C6/M1：summary（降级后非空）。
        let summary: String
        /// C6/M1：description（详细；读失败兜底空串）。
        let description: String

        init(name: String, enabled: Bool, summary: String = "", description: String = "") {
            self.name = name
            self.enabled = enabled
            self.summary = summary
            self.description = description
        }

        /// C1 降级 / 向后兼容：无 summary/description 的旧 inspect JSON 仍能 decode（红队 AT03 同语义）。
        private enum CodingKeys: String, CodingKey {  // swiftlint:disable:this nesting
            case name, enabled, summary, description
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decode(String.self, forKey: .name)
            enabled = try c.decode(Bool.self, forKey: .enabled)
            summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
            description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        }
    }
}

/// `~/.buddy/marketplace-meta.json` 数据结构。
struct MarketplaceMeta: Codable, Equatable {
    var lastSyncedAt: Date?
    var consecutiveSyncFailures: Int
}

// MARK: - MarketplaceManager

/// 统一管理 bundle seed + remote sync + 老用户迁移。
///
/// 单例 + init 注入（测试可替换 resolver / urlSession / now / paths）。
/// 公开 6 方法：seedFromBundle / syncFromRemote / install / migrateLegacy / reseed / inspect。
///
/// 关键设计：
/// - migrateLegacy 两阶段每 Phase 入口重读 state（B1 修复），crash safe + 幂等
/// - syncFromRemote 永不抛错，失败转 log + counter
/// - sideloaded conflict skip（B3 修复）
final class MarketplaceManager {
    static let shared = MarketplaceManager()

    private let resolver: PluginSourceResolving
    private let trustStore: TrustStore
    /// C4/C5：自动更新开关存储（sync updated 时读，ON → installPlugin 覆盖，OFF → 仅 cache）。
    private let autoUpdateStore: MarketplaceAutoUpdateStore
    private let pluginsDir: URL
    private let marketplacePath: URL
    private let metaPath: URL
    private let syncLogPath: URL
    private let bundleProvider: () -> Bundle
    private let urlSession: URLSession
    private let now: () -> Date
    private let remoteURL: URL

    /// 注入的 HUD（生产 = MarketHUD.shared；测试 = mock 或 nil）。
    ///
    /// nil 时 `?.show(...)` 短路（单测不依赖 UI）。
    /// 通过 `configureHUD(_:)` 一次性注入。
    private(set) var hud: MarketHUDDisplaying?

    /// 并发互斥（仅护 sync-vs-sync，B6：install/reseed vs sync 留 phase 2）。
    var syncInProgress = false
    let syncLock = NSLock()

    /// 1 小时 debounce 间隔。
    private static let syncDebounceSeconds: TimeInterval = 3600

    /// 默认 GitHub Raw URL（C10：指向官方插件 monorepo 的 marketplace.json）。
    /// 从旧 claude-code-buddy 仓库 marketplace/marketplace.json 迁移至 buddy-official-plugins 根。
    /// internal 供测试断言（C10 契约：必须含 buddy-official-plugins）。
    static let productionRemoteURLString = LauncherConstants.officialMarketplaceRawURL

    /// 默认远程 URL：读 env `BUDDY_MARKETPLACE_URL` 或 GitHub Raw 生产 fallback。
    ///
    /// 不使用 force-unwrap：若两层都返回 nil（理论不可能），最终用 file:// 静态 URL 兜底。
    static let defaultRemoteURL: URL = {
        let raw = ProcessInfo.processInfo.environment["BUDDY_MARKETPLACE_URL"]
            ?? productionRemoteURLString
        if let url = URL(string: raw) { return url }
        if let fallback = URL(string: productionRemoteURLString) { return fallback }
        return URL(fileURLWithPath: "/dev/null")
    }()

    init(
        resolver: PluginSourceResolving = PluginSourceResolver.shared,
        trustStore: TrustStore = .shared,
        autoUpdateStore: MarketplaceAutoUpdateStore = .shared,
        pluginsDir: URL = LauncherConstants.launcherPluginsDir,
        marketplacePath: URL = LauncherConstants.buddyDir.appendingPathComponent("marketplace.json"),
        metaPath: URL = LauncherConstants.buddyDir.appendingPathComponent("marketplace-meta.json"),
        syncLogPath: URL = LauncherConstants.buddyDir.appendingPathComponent("launcher-sync.log"),
        bundleProvider: @escaping () -> Bundle = { ResourceBundle.bundle },
        urlSession: URLSession = .shared,
        now: @escaping () -> Date = Date.init,
        remoteURL: URL = MarketplaceManager.defaultRemoteURL
    ) {
        self.resolver = resolver
        self.trustStore = trustStore
        self.autoUpdateStore = autoUpdateStore
        self.pluginsDir = pluginsDir
        self.marketplacePath = marketplacePath
        self.metaPath = metaPath
        self.syncLogPath = syncLogPath
        self.bundleProvider = bundleProvider
        self.urlSession = urlSession
        self.now = now
        self.remoteURL = remoteURL
    }

    // MARK: - 公开 API

    /// 首启时调；幂等。
    ///
    /// 步骤：
    /// 1. 清孤儿 temp（task 002 B5 要求）
    /// 2. 确保 pluginsDir 存在
    /// 3. 读 bundle 内 seed `marketplace.json`
    /// 4. 拷到 `~/.buddy/marketplace.json`（如不存在）
    /// 5. 遍历 plugins[]：resolver 解析 → 拷到 `~/.buddy/launcher-plugins/<name>/`
    ///    - 已存在且 plugin.json 内容相同 → skip
    ///    - 已存在但内容不同 → 删旧拷新（保留 .disabled）
    func seedFromBundle() async throws {
        PluginSourceResolver.cleanupOrphans()

        try FileManager.default.createDirectory(
            at: pluginsDir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755]
        )

        guard let seedURL = bundleProvider().url(
            forResource: "marketplace",
            withExtension: "json",
            subdirectory: "Marketplace"
        ) else {
            throw LauncherError.pluginInvalid("bundle marketplace.json not found")
        }
        let seedData = try Data(contentsOf: seedURL)
        let manifest = try JSONDecoder().decode(MarketplaceManifest.self, from: seedData)

        // 首启拷 cache（不覆盖已被 syncFromRemote 写过的版本）
        if !FileManager.default.fileExists(atPath: marketplacePath.path) {
            try seedData.write(to: marketplacePath)
        }

        let bundleRoot = seedURL.deletingLastPathComponent()
        for plugin in manifest.plugins {
            try await seedOne(plugin: plugin, bundleRoot: bundleRoot)
        }

        // CLI reseed 配套（task 007）：seed 完成后读 reseed-pending-disabled.json → 恢复 .disabled → 删 pending
        let pendingPath = LauncherConstants.buddyDir.appendingPathComponent("reseed-pending-disabled.json")
        if let pendingData = try? Data(contentsOf: pendingPath),
           let pendingNames = try? JSONDecoder().decode([String].self, from: pendingData) {
            for name in pendingNames {
                let dir = pluginsDir.appendingPathComponent(name)
                guard FileManager.default.fileExists(atPath: dir.path) else { continue }
                let marker = dir.appendingPathComponent(".disabled")
                if !FileManager.default.fileExists(atPath: marker.path) {
                    try? Data().write(to: marker)
                }
            }
            try? FileManager.default.removeItem(at: pendingPath)
        }
    }

    /// 异步从远程拉取最新 marketplace.json。
    ///
    /// 行为契约：永不抛错（所有失败转为 log + counter）。
    ///
    /// - 1h debounce
    /// - JSON malformed / schemaVersion 不兼容 → cache 不写，failures+=1
    /// - 成功 → 写 cache，failures=0，diff 应用（保留 .disabled）
    /// - 每次执行追加结构化 JSON 行到 `~/.buddy/launcher-sync.log`
    func syncFromRemote() async {
        // B6：sync-vs-sync 并发互斥（install/reseed vs sync 不在本 task 范围内）
        // NSLock 操作封装在同步 helper 内（避免 Swift 6 async-context-lock 警告）
        guard tryAcquireSyncLock() else {
            appendSyncLog(["status": "noop", "reason": "concurrent-skipped"])
            return
        }
        defer { releaseSyncLock() }

        var meta = readMeta() ?? MarketplaceMeta(lastSyncedAt: nil, consecutiveSyncFailures: 0)

        // 1h debounce
        if let last = meta.lastSyncedAt,
           now().timeIntervalSince(last) < Self.syncDebounceSeconds {
            appendSyncLog(["status": "noop", "reason": "debounce"])
            return
        }

        do {
            var request = URLRequest(url: remoteURL)
            request.timeoutInterval = 30
            let (data, response) = try await urlSession.data(for: request)

            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                meta.consecutiveSyncFailures += 1
                writeMeta(meta)
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                appendSyncLog([
                    "status": "failed",
                    "error": "http \(status)",
                    "consecutiveFailures": meta.consecutiveSyncFailures
                ])
                if meta.consecutiveSyncFailures >= 3 {
                    await hud?.show(
                        text: "无法连接 Market（连续 \(meta.consecutiveSyncFailures) 次失败）",
                        actions: [.init(label: "查看日志", handler: { [weak self] in self?.openSyncLog() })]
                    )
                }
                return
            }

            // JSON decode
            let remoteManifest: MarketplaceManifest
            do {
                remoteManifest = try JSONDecoder().decode(MarketplaceManifest.self, from: data)
            } catch {
                meta.consecutiveSyncFailures += 1
                writeMeta(meta)
                appendSyncLog([
                    "status": "failed",
                    "error": "malformed",
                    "consecutiveFailures": meta.consecutiveSyncFailures
                ])
                if meta.consecutiveSyncFailures >= 3 {
                    await hud?.show(
                        text: "无法连接 Market（连续 \(meta.consecutiveSyncFailures) 次失败）",
                        actions: [.init(label: "查看日志", handler: { [weak self] in self?.openSyncLog() })]
                    )
                }
                return
            }

            // schemaVersion 兼容（仅接受 1）
            guard remoteManifest.schemaVersion == 1 else {
                meta.consecutiveSyncFailures += 1
                writeMeta(meta)
                appendSyncLog([
                    "status": "failed",
                    "error": "schemaVersion incompatible: \(remoteManifest.schemaVersion)",
                    "consecutiveFailures": meta.consecutiveSyncFailures
                ])
                return
            }

            // diff 本地（cache 可能不存在 → 当作 plugins=[]）
            let localManifest: MarketplaceManifest?
            if FileManager.default.fileExists(atPath: marketplacePath.path),
               let localData = try? Data(contentsOf: marketplacePath) {
                localManifest = try? JSONDecoder().decode(MarketplaceManifest.self, from: localData)
            } else {
                localManifest = nil
            }
            let localPlugins = localManifest?.plugins ?? []
            let added = remoteManifest.plugins.filter { remote in
                !localPlugins.contains { $0.name == remote.name }
            }.map { $0.name }
            let updated: [String] = remoteManifest.plugins.compactMap { remote in
                guard let local = localPlugins.first(where: { $0.name == remote.name }),
                      local.version != remote.version else { return nil }
                return remote.name
            }
            let removed = localPlugins.filter { local in
                !remoteManifest.plugins.contains { $0.name == local.name }
            }.map { $0.name }

            // 写 cache
            try data.write(to: marketplacePath)

            // 应用变更（remote 视角：added → 新装；updated → autoUpdate ON 时覆盖，OFF 时仅 cache）
            // C5：added 始终安装（新插件，replacing=false）；updated 仅在 autoUpdate ON 时 installPlugin(replacing: true)。
            // autoUpdate OFF 时 updated 不覆盖（cache 已写，下次用户手动 install 或 reseed 时生效）。
            // 注：sync 的 installPlugin 本就不调 checkAndPrompt（I-NEW3），故「绕过 TOFU」已是事实。
            let autoUpdateOn = autoUpdateStore.isEnabled
            for name in added {
                guard let plugin = remoteManifest.plugins.first(where: { $0.name == name }) else { continue }
                do {
                    try await installPlugin(plugin, manifest: remoteManifest, replacing: false)
                } catch {
                    BuddyLogger.shared.error("marketplace install during sync failed", subsystem: "plugin", meta: ["name": name, "kind": "added", "error": "\(error)"])
                }
            }
            for name in updated {
                guard autoUpdateOn else {
                    BuddyLogger.shared.info("marketplace sync skip update (autoUpdate OFF)", subsystem: "plugin", meta: ["name": name])
                    continue
                }
                guard let plugin = remoteManifest.plugins.first(where: { $0.name == name }) else { continue }
                do {
                    try await installPlugin(plugin, manifest: remoteManifest, replacing: true)
                } catch {
                    BuddyLogger.shared.error("marketplace install during sync failed", subsystem: "plugin", meta: ["name": name, "kind": "updated", "error": "\(error)"])
                }
            }
            // removed: 留旧目录不删

            meta.lastSyncedAt = now()
            meta.consecutiveSyncFailures = 0
            writeMeta(meta)

            let oldHash: String
            if let encoded = try? JSONEncoder().encode(localManifest) {
                oldHash = sha256Hex(encoded)
            } else {
                oldHash = "none"
            }
            let newHash = sha256Hex(data)
            let status: String = (added.isEmpty && updated.isEmpty && removed.isEmpty) ? "noop" : "updated"
            appendSyncLog([
                "status": status,
                "oldHash": oldHash,
                "newHash": newHash,
                "added": added,
                "updated": updated,
                "removed": removed
            ])

            if let diffText = makeDiffText(added: added, updated: updated, remoteManifest: remoteManifest) {
                await hud?.show(
                    text: diffText,
                    actions: [.init(label: "查看", handler: { [weak self] in self?.openBuddyStore() })]
                )
            }
        } catch {
            meta.consecutiveSyncFailures += 1
            writeMeta(meta)
            appendSyncLog([
                "status": "failed",
                "error": String(describing: error),
                "consecutiveFailures": meta.consecutiveSyncFailures
            ])
            if meta.consecutiveSyncFailures >= 3 {
                await hud?.show(
                    text: "无法连接 Market（连续 \(meta.consecutiveSyncFailures) 次失败）",
                    actions: [.init(label: "查看日志", handler: { [weak self] in self?.openSyncLog() })]
                )
            }
        }
    }

    /// CLI / UI 主动安装：从当前 cache 找到 entry → resolver 解析 → 覆盖目标目录。
    func install(name: String) async throws {
        let manifest = try readLocalManifest()
        guard let plugin = manifest.plugins.first(where: { $0.name == name }) else {
            throw LauncherError.pluginNotFound(name)
        }
        try await installPlugin(plugin, manifest: manifest, replacing: true)
    }

    /// 老 builtin 迁移：两阶段，幂等 + crash safe。
    ///
    /// 设计铁律（B1）：每个 Phase 入口都重读 state，不复用前 Phase 的快照变量。
    /// 单条迁移失败不影响其他（log + continue）。
    func migrateLegacy() throws {
        let migrations: [(oldName: String, newName: String)] = [
            ("builtin-translate", "translate"),
            ("builtin-hello", "hello")
        ]
        for migration in migrations {
            do {
                try migrateOne(oldName: migration.oldName, newName: migration.newName)
            } catch {
                BuddyLogger.shared.warn("marketplace migrateLegacy failed", subsystem: "plugin", meta: ["oldName": migration.oldName, "newName": migration.newName, "error": "\(error)"])
            }
        }
    }

    /// CLI `buddy launcher reseed`：强制 reseed，保留 .disabled。
    ///
    /// 仅删除 marketplace cache 列出的 plugin 目录（不删用户手动 add 的第三方）。
    func reseed() async throws {
        // 收集当前 disabled 名（含 sideloaded，避免误删后丢标记）
        let disabledNames = collectDisabledNames()

        // 删除 marketplace 列出的目录
        if FileManager.default.fileExists(atPath: marketplacePath.path) {
            if let manifest = try? readLocalManifest() {
                for plugin in manifest.plugins {
                    let dir = pluginsDir.appendingPathComponent(plugin.name)
                    try? FileManager.default.removeItem(at: dir)
                }
            }
            try FileManager.default.removeItem(at: marketplacePath)
        }

        try await seedFromBundle()

        // 恢复 .disabled
        for name in disabledNames {
            let dir = pluginsDir.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: dir.path) {
                let marker = dir.appendingPathComponent(".disabled")
                if !FileManager.default.fileExists(atPath: marker.path) {
                    try? Data().write(to: marker)
                }
            }
        }
    }

    /// 导出当前 marketplace 状态（含 sideloaded 双视角，B4 修复）。
    /// C6/M1：plugins + sideloadedPlugins 两分支都逐目录读 plugin.json → PluginManifest → displaySummary（C1 降级）。
    func inspect() throws -> MarketplaceInspection {
        let manifest = (try? readLocalManifest()) ?? MarketplaceManifest(
            schemaVersion: 1,
            name: "buddy-official",
            description: nil,
            owner: MarketplaceOwner(name: "", email: nil, homepage: nil),
            plugins: []
        )
        let meta = readMeta() ?? MarketplaceMeta(lastSyncedAt: nil, consecutiveSyncFailures: 0)

        let marketNames = Set(manifest.plugins.map { $0.name })

        let plugins: [MarketplaceInspection.PluginInspection] = manifest.plugins.map { entry in
            let dir = pluginsDir.appendingPathComponent(entry.name)
            let disabled = FileManager.default.fileExists(
                atPath: dir.appendingPathComponent(".disabled").path
            )
            // M1：逐目录读 plugin.json 解析 summary/description（非 marketplace-meta）
            let (summary, description) = readSummaryAndDescription(from: dir, fallbackName: entry.name)
            return MarketplaceInspection.PluginInspection(
                name: entry.name,
                version: entry.version,
                enabled: !disabled,
                source: sourceLabel(entry.source),
                summary: summary,
                description: description
            )
        }

        var sideloaded: [MarketplaceInspection.SideloadedInspection] = []
        if let entries = try? FileManager.default.contentsOfDirectory(
            at: pluginsDir,
            includingPropertiesForKeys: nil
        ) {
            for entry in entries {
                let name = entry.lastPathComponent
                if marketNames.contains(name) { continue }
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: entry.path, isDirectory: &isDir),
                      isDir.boolValue,
                      FileManager.default.fileExists(
                        atPath: entry.appendingPathComponent("plugin.json").path
                      ) else { continue }
                let disabled = FileManager.default.fileExists(
                    atPath: entry.appendingPathComponent(".disabled").path
                )
                // M1：逐目录读 plugin.json
                let (summary, description) = readSummaryAndDescription(from: entry, fallbackName: name)
                sideloaded.append(.init(
                    name: name,
                    enabled: !disabled,
                    summary: summary,
                    description: description
                ))
            }
        }

        return MarketplaceInspection(
            plugins: plugins,
            sideloadedPlugins: sideloaded,
            lastSyncedAt: meta.lastSyncedAt,
            consecutiveSyncFailures: meta.consecutiveSyncFailures
        )
    }

    /// M1：从插件目录读 plugin.json → PluginManifest → displaySummary（C1 降级）+ description。
    /// 读失败/无 plugin.json 返回 fallbackName（summary）+ 空串（description），不抛错（容错降级）。
    private func readSummaryAndDescription(from pluginDir: URL, fallbackName: String) -> (summary: String, description: String) {
        let manifestURL = pluginDir.appendingPathComponent("plugin.json")
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(PluginManifest.self, from: data) else {
            return (fallbackName, "")
        }
        return (manifest.displaySummary, manifest.description)
    }

    // MARK: - 私有 helper

    private func seedOne(plugin: MarketplacePlugin, bundleRoot: URL) async throws {
        let targetDir = pluginsDir.appendingPathComponent(plugin.name)
        let targetManifestPath = targetDir.appendingPathComponent("plugin.json")
        let resolvedURL = try await resolver.resolve(plugin.source, bundleRoot: bundleRoot)
        let resolvedManifestPath = resolvedURL.appendingPathComponent("plugin.json")
        let resolvedIsTemp = resolvedURL.path.contains(PluginSourceResolver.tempPrefix)

        defer {
            if resolvedIsTemp {
                try? FileManager.default.removeItem(at: resolvedURL)
            }
        }

        if FileManager.default.fileExists(atPath: targetDir.path) {
            // 比内容（避免反复 copyItem 浪费 IO）
            if let existing = try? Data(contentsOf: targetManifestPath),
               let source = try? Data(contentsOf: resolvedManifestPath),
               existing == source {
                return
            }
            // 内容不同 → 删旧拷新，保留 .disabled
            let wasDisabled = FileManager.default.fileExists(
                atPath: targetDir.appendingPathComponent(".disabled").path
            )
            try FileManager.default.removeItem(at: targetDir)
            try FileManager.default.copyItem(at: resolvedURL, to: targetDir)
            try ensureStdinChmod(in: targetDir)
            if wasDisabled {
                try Data().write(to: targetDir.appendingPathComponent(".disabled"))
            }
        } else {
            try FileManager.default.copyItem(at: resolvedURL, to: targetDir)
            try ensureStdinChmod(in: targetDir)
        }
    }

    /// installPlugin：被 install / syncFromRemote 复用。
    ///
    /// B3 conflict 处理：targetExists && !replacing → skip + log（sideloaded 冲突）。
    private func installPlugin(
        _ plugin: MarketplacePlugin,
        manifest: MarketplaceManifest,
        replacing: Bool
    ) async throws {
        guard let seedURL = bundleProvider().url(
            forResource: "marketplace",
            withExtension: "json",
            subdirectory: "Marketplace"
        ) else {
            throw LauncherError.pluginInvalid("bundle root missing")
        }
        let bundleRoot = seedURL.deletingLastPathComponent()
        let targetDir = pluginsDir.appendingPathComponent(plugin.name)
        let targetExists = FileManager.default.fileExists(atPath: targetDir.path)

        // B3：sideloaded conflict 时 skip，不抛错
        if targetExists && !replacing {
            BuddyLogger.shared.info("marketplace skip install (existing dir)", subsystem: "plugin", meta: ["name": plugin.name, "dir": targetDir.path])
            appendSyncLog(["status": "skip-conflict", "plugin": plugin.name])
            return
        }

        let resolvedURL = try await resolver.resolve(plugin.source, bundleRoot: bundleRoot)
        let resolvedIsTemp = resolvedURL.path.contains(PluginSourceResolver.tempPrefix)
        defer {
            if resolvedIsTemp {
                try? FileManager.default.removeItem(at: resolvedURL)
            }
        }

        let wasDisabled = FileManager.default.fileExists(
            atPath: targetDir.appendingPathComponent(".disabled").path
        )
        if targetExists && replacing {
            try FileManager.default.removeItem(at: targetDir)
        }
        try FileManager.default.copyItem(at: resolvedURL, to: targetDir)
        try ensureStdinChmod(in: targetDir)
        if wasDisabled {
            try Data().write(to: targetDir.appendingPathComponent(".disabled"))
        }
    }

    private func migrateOne(oldName: String, newName: String) throws {
        let oldDir = pluginsDir.appendingPathComponent(oldName)
        let newDir = pluginsDir.appendingPathComponent(newName)

        // ============ Phase 1: 写新目录 ============
        // 入口重读 state（B1）
        let phase1OldExists = FileManager.default.fileExists(atPath: oldDir.path)
        let phase1NewExists = FileManager.default.fileExists(atPath: newDir.path)
        if phase1OldExists && !phase1NewExists {
            try FileManager.default.copyItem(at: oldDir, to: newDir)
            // 改新 plugin.json 的 name 字段
            try renamePluginJSON(at: newDir.appendingPathComponent("plugin.json"), to: newName)
        }

        // ============ Phase 1.5: 写新 trust ============
        // 入口重读 state（B1）
        let phase15Records = (try? trustStore.list()) ?? []
        let phase15HasOld = phase15Records.contains { $0.pluginName == oldName }
        let phase15HasNew = phase15Records.contains { $0.pluginName == newName }
        if phase15HasOld && !phase15HasNew,
           let oldRecord = phase15Records.first(where: { $0.pluginName == oldName }) {
            try trustStore.addRecord(TrustRecord(
                trustKey: oldRecord.trustKey,
                pluginName: newName,
                approvedAt: oldRecord.approvedAt
            ))
        }

        // ============ Phase 2: 删旧目录 + 旧 trust ============
        // 入口重读 state（B1），不复用 phase1/phase15 变量
        let phase2OldDirExists = FileManager.default.fileExists(atPath: oldDir.path)
        let phase2NewDirExists = FileManager.default.fileExists(atPath: newDir.path)
        if phase2NewDirExists && phase2OldDirExists {
            try FileManager.default.removeItem(at: oldDir)
        }
        let phase2Records = (try? trustStore.list()) ?? []
        let phase2HasNew = phase2Records.contains { $0.pluginName == newName }
        let phase2HasOld = phase2Records.contains { $0.pluginName == oldName }
        if phase2HasNew && phase2HasOld {
            try trustStore.remove(pluginName: oldName)
        }
    }

    /// 改 plugin.json 的 name 字段。
    ///
    /// PluginManifest.name 是 `let`，所以走 dictionary 路径而非 PluginManifest decode/encode：
    /// 用 JSONSerialization 改 name 后写回（保留所有原字段，无字段顺序保证但语义稳定）。
    private func renamePluginJSON(at path: URL, to newName: String) throws {
        let data = try Data(contentsOf: path)
        guard var dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LauncherError.pluginManifestInvalid("plugin.json not a JSON object")
        }
        dict["name"] = newName
        let newData = try JSONSerialization.data(
            withJSONObject: dict,
            options: [.prettyPrinted, .sortedKeys]
        )
        try newData.write(to: path)
    }

    private func readLocalManifest() throws -> MarketplaceManifest {
        let data = try Data(contentsOf: marketplacePath)
        return try JSONDecoder().decode(MarketplaceManifest.self, from: data)
    }

    private func readMeta() -> MarketplaceMeta? {
        guard FileManager.default.fileExists(atPath: metaPath.path),
              let data = try? Data(contentsOf: metaPath) else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(MarketplaceMeta.self, from: data)
    }

    private func writeMeta(_ meta: MarketplaceMeta) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(meta) else { return }
        try? FileManager.default.createDirectory(
            at: metaPath.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755]
        )
        try? data.write(to: metaPath)
    }

    /// 结构化 JSON 行追加。
    ///
    /// 每行一个独立 JSON 对象（jsonl 格式），便于 grep / jq 分析。
    /// 自动加 "timestamp" 字段（ISO 8601）。
    private func appendSyncLog(_ payload: [String: Any]) {
        var withTimestamp = payload
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        withTimestamp["timestamp"] = formatter.string(from: now())
        guard let line = try? JSONSerialization.data(
            withJSONObject: withTimestamp,
            options: [.sortedKeys]
        ) else { return }
        try? FileManager.default.createDirectory(
            at: syncLogPath.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755]
        )

        if FileManager.default.fileExists(atPath: syncLogPath.path),
           let handle = try? FileHandle(forWritingTo: syncLogPath) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
            try? handle.write(contentsOf: Data("\n".utf8))
        } else {
            var combined = line
            combined.append(contentsOf: Data("\n".utf8))
            try? combined.write(to: syncLogPath)
        }
    }

    /// stdin/command mode 插件的 cmd 文件 chmod 0o755（仅当文件存在）。
    ///
    /// Bundle 资源是只读，拷到 launcher-plugins 后需手动赋执行权限。
    /// stdin + command mode 都有可执行子进程；prompt mode 无可执行文件，跳过。
    /// 引用知识库：2026-05-26-spm-copy-executable-script-chmod-755
    private func ensureStdinChmod(in dir: URL) throws {
        let manifestPath = dir.appendingPathComponent("plugin.json")
        guard FileManager.default.fileExists(atPath: manifestPath.path),
              let data = try? Data(contentsOf: manifestPath),
              let manifest = try? JSONDecoder().decode(PluginManifest.self, from: data) else {
            return
        }
        // stdin 与 command 共享 cmd 字段路径，统一 chmod
        let cmdStr: String?
        switch manifest.modeConfig {
        case .stdin(let cfg): cmdStr = cfg.cmd
        case .command(let cfg): cmdStr = cfg.cmd
        case .prompt: cmdStr = nil
        }
        if let cmd = cmdStr {
            let exeBase = (cmd as NSString).lastPathComponent
            let exePath = dir.appendingPathComponent(exeBase).path
            if FileManager.default.fileExists(atPath: exePath) {
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o755],
                    ofItemAtPath: exePath
                )
            }
        }
    }

    /// 扫描 pluginsDir 下所有含 `.disabled` 标记的目录名。
    private func collectDisabledNames() -> Set<String> {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: pluginsDir,
            includingPropertiesForKeys: nil
        ) else { return [] }
        var result = Set<String>()
        for entry in entries {
            let marker = entry.appendingPathComponent(".disabled")
            if FileManager.default.fileExists(atPath: marker.path) {
                result.insert(entry.lastPathComponent)
            }
        }
        return result
    }

    private func sourceLabel(_ source: PluginSourceConfig) -> String {
        switch source {
        case .localSubdir(let path):
            return "local-subdir: \(path)"
        case .file(let path):
            return "file: \(path)"
        case .gitURL(let url, _):
            return "git-url: \(url)"
        case .gitSubdir(let url, let path, _, _):
            return "git-subdir: \(url)/\(path)"
        }
    }

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - task 006 HUD 注入 / 文案 / 跳转

    /// HUD 注入入口（B3 修复语义）。
    ///
    /// - 同实例两次调用：no-op（idempotent）
    /// - 不同实例两次调用：precondition trap
    /// - LauncherManager.setup 调用一次，注入 `MarketHUD.shared`
    func configureHUD(_ hud: MarketHUDDisplaying) {
        if self.hud === hud { return }
        precondition(self.hud == nil, "HUD already configured with a different instance")
        self.hud = hud
    }

    /// 测试 helper（B4 修复）：测试间重置注入的 hud + 并发标志。
    ///
    /// internal 可见，仅 `@testable import` 使用。
    internal func resetHUDForTesting() {
        self.hud = nil
        releaseSyncLock()
    }

    /// 同步获取 syncLock；返回 true 表示进入临界区，false 表示已有 sync 在进行。
    private func tryAcquireSyncLock() -> Bool {
        syncLock.lock()
        defer { syncLock.unlock() }
        if syncInProgress { return false }
        syncInProgress = true
        return true
    }

    /// 同步释放 syncLock；幂等。
    private func releaseSyncLock() {
        syncLock.lock()
        syncInProgress = false
        syncLock.unlock()
    }

    /// diff 文案：B1 安全 optional 解构 + 多项时计数（不丢信息）。
    ///
    /// - 0 项 → nil（HUD 不弹）
    /// - 1 项：updated 单项显示 `<name> 已更新到 v<version>`；added 单项显示 `新增插件：<name>`
    /// - 多项：`Market 同步完成：N 个已更新，M 个新增`
    func makeDiffText(
        added: [String],
        updated: [String],
        remoteManifest: MarketplaceManifest
    ) -> String? {
        let totalCount = added.count + updated.count
        if totalCount == 0 { return nil }
        if totalCount == 1 {
            if let updatedName = updated.first,
               let plugin = remoteManifest.plugins.first(where: { $0.name == updatedName }) {
                return "\(updatedName) 已更新到 v\(plugin.version)"
            }
            if let addedName = added.first {
                return "新增插件：\(addedName)"
            }
            return nil
        }
        var parts: [String] = []
        if !updated.isEmpty { parts.append("\(updated.count) 个已更新") }
        if !added.isEmpty { parts.append("\(added.count) 个新增") }
        return "Market 同步完成：" + parts.joined(separator: "，")
    }

    /// 打开 ~/.buddy/launcher-sync.log（HUD "查看日志" 按钮）。
    func openSyncLog() {
        NSWorkspace.shared.open(syncLogPath)
    }

    /// 触发 Buddy Store 打开（HUD "查看" 按钮）。AppDelegate 订阅同名通知后调 showSettings()。
    func openBuddyStore() {
        NotificationCenter.default.post(name: .buddyStoreShouldOpen, object: nil)
    }
}

// MARK: - Notification.Name 契约

extension Notification.Name {
    /// HUD "查看" 按钮触发；AppDelegate 订阅后调 showSettings()。无 userInfo。
    static let buddyStoreShouldOpen = Notification.Name("BuddyStoreShouldOpen")
}
