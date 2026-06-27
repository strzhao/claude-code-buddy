import Foundation

// MARK: - DependencyStatus

/// M2（依赖状态）：单个外部依赖的检查结果。
///
/// 字段（契约 state.md ## 数据结构）：
/// - `check`：命令名（如 "qrencode"）
/// - `label`：人话描述（如 "二维码生成库"）；nil = 无描述
/// - `isInstalled`：命令存在性检查结果（locateBinary 是否找到）
/// - `brewPackage`：brew 包名（nil = 无 brew 映射，只能手动装）
struct DependencyStatus: Equatable {
    let check: String
    let label: String?
    let isInstalled: Bool
    let brewPackage: String?
}

// MARK: - BrewAvailability

/// M2：Homebrew 可用性。
///
/// - `.available(path: String)`：brew 已装，path 为绝对路径
/// - `.missing`：brew 未装
enum BrewAvailability: Equatable {
    case available(path: String)
    case missing
}

// MARK: - BinaryLocator seam

/// M2：命令存在性检查闭包类型（seam，供测试注入 mock）。
///
/// 签名对齐 `StdinExecutor.locateBinary(_:in:)`：传入命令名 + 扩展 PATH，返回绝对路径或 nil。
/// 生产实现复用 `StdinExecutor.shared.locateBinary`；测试注入 mock 避免依赖真实系统状态。
typealias BinaryLocator = (_ name: String, _ extendedPath: String) -> URL?

// MARK: - DependencyResolver

/// M2（依赖收集 + 状态）：输入 PluginManifest，输出 `[DependencyStatus]` + brew 可用性。
///
/// 职责：
/// - 遍历 `plugin.deps` + `plugin.requiredPath`，按 check 名去重（deps 版本带元数据优先）
/// - 每个依赖用命令存在性检查（复用 StdinExecutor.locateBinary）查 isInstalled
/// - brew 存在性：locateBinary("brew") → BrewAvailability
///
/// 线程安全：无状态（除注入的 locator 闭包），可任意线程调用。
/// `collectMissing` 与 `collectStatuses` 关系：前者 = 后者 `.filter { !$0.isInstalled }`。
final class DependencyResolver {

    static let shared = DependencyResolver()

    /// 命令存在性检查 seam（默认复用 StdinExecutor.shared.locateBinary）。
    private let binaryLocator: BinaryLocator
    /// brew 可用性检查 seam（默认实现 locateBinary("brew")）。
    private let brewLocator: () -> BrewAvailability

    init(
        binaryLocator: @escaping BinaryLocator = DependencyResolver.defaultBinaryLocator,
        brewLocator: @escaping () -> BrewAvailability = DependencyResolver.defaultBrewLocator
    ) {
        self.binaryLocator = binaryLocator
        self.brewLocator = brewLocator
    }

    // MARK: - Public API（契约 state.md ## 接口签名）

    /// 收集插件缺失的依赖（isInstalled == false）。
    /// - Parameter plugin: 插件 manifest
    /// - Returns: 缺失依赖列表（合并 deps + requiredPath 去重后过滤 isInstalled == false）
    func collectMissing(_ plugin: PluginManifest) -> [DependencyStatus] {
        collectStatuses(plugin).filter { !$0.isInstalled }
    }

    /// 收集插件全部依赖状态（含已装），供弹框展示完整列表。
    func collectStatuses(_ plugin: PluginManifest) -> [DependencyStatus] {
        // 1. 合并 deps（带元数据）+ requiredPath（无元数据），按 check 名去重。
        //    deps 版本优先（带 brew/label），requiredPath 仅补 deps 未声明的命令。
        var byCheck: [String: (brew: String?, label: String?)] = [:]
        var orderedChecks: [String] = []
        for dep in plugin.deps where byCheck[dep.check] == nil {
            byCheck[dep.check] = (dep.brew, dep.label)
            orderedChecks.append(dep.check)
        }
        if let required = plugin.requiredPath {
            for cmd in required where byCheck[cmd] == nil {
                byCheck[cmd] = (nil, nil)
                orderedChecks.append(cmd)
            }
        }

        // 2. 每个依赖用 binaryLocator 查 isInstalled。
        let extPath = Self.makeExtendedPathPublic()
        return orderedChecks.map { check in
            let meta = byCheck[check] ?? (nil, nil)
            let isInstalled = binaryLocator(check, extPath) != nil
            return DependencyStatus(
                check: check,
                label: meta.label,
                isInstalled: isInstalled,
                brewPackage: meta.brew
            )
        }
    }

    /// brew 可用性（.available(path) | .missing）。
    func brewAvailability() -> BrewAvailability {
        brewLocator()
    }

    // MARK: - Default locators（生产实现，供 BrewProcessRunner 等跨文件复用）

    /// 默认命令存在性检查：复用 StdinExecutor.shared.locateBinary（同一扩展 PATH 规则）。
    /// 注：internal 暴露供 BrewProcessRunner 复用（避免重复实现扩展 PATH 规则）。
    static let defaultBinaryLocator: BinaryLocator = { name, extPath in
        StdinExecutor.shared.locateBinary(name, in: extPath)
    }

    /// 默认 brew 可用性检查：locateBinary("brew")。
    private static let defaultBrewLocator: () -> BrewAvailability = {
        let extPath = makeExtendedPathPublic()
        if let url = StdinExecutor.shared.locateBinary("brew", in: extPath) {
            return .available(path: url.path)
        }
        return .missing
    }

    /// 构造扩展 PATH（与 StdinExecutor.makeExtendedPath 同语义，镜像 LauncherConstants.pluginPathPrefixes）。
    /// internal 暴露供 BrewProcessRunner 复用（同一扩展 PATH 规则保证一致性）。
    static func makeExtendedPathPublic() -> String {
        let currentPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
        return (LauncherConstants.pluginPathPrefixes + [currentPath]).joined(separator: ":")
    }
}
