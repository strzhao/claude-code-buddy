import XCTest
@testable import BuddyCore

// MARK: - DependencyResolverTests
//
// 蓝队单测 T2：DependencyResolver（collectMissing + brewAvailability，契约 M2）。
//
// 契约引用（state.md ## 契约规约 M2 + 接口签名）：
//   struct DependencyStatus: Equatable { check: String; label: String?; isInstalled: Bool; brewPackage: String? }
//   enum BrewAvailability { case available(path: String); case missing }
//   func collectMissing(_ plugin: PluginManifest) -> [DependencyStatus]
//   func brewAvailability() -> BrewAvailability
//   合并 plugin.deps + plugin.requiredPath 按 check 名去重
//
// 测试策略：DependencyResolver 注入 binaryLocator + brewLocator seam（避免依赖真实系统状态）。
//
// TDD：本文件先于实现编写，最初编译失败（RED），实现后转 GREEN。

final class DependencyResolverTests: XCTestCase {

    // MARK: - Helpers

    /// 构造 command mode plugin（带 deps + requiredPath）。
    private func makePlugin(
        deps: [(check: String, brew: String?, label: String?)] = [],
        requiredPath: [String]? = nil
    ) -> PluginManifest {
        let depObjs = deps.map { PluginDep(check: $0.check, brew: $0.brew, label: $0.label) }
        let json = """
        {
            "name": "test-plugin", "version": "0.1.0", "description": "d", "keywords": [],
            "mode": "command", "cmd": "./x.sh",
            "requiredPath": \(requiredPath.map { "[\"\($0.joined(separator: "\",\""))\"]" } ?? "null"),
            "deps": \(depObjs.isEmpty ? "[]" : "[\(depObjs.map { "{\"check\":\"\($0.check)\"\($0.brew.map { ",\"brew\":\"\($0)\"" } ?? "")\($0.label.map { ",\"label\":\"\($0)\"" } ?? "")}" }.joined(separator: ","))]")
        }
        """
        let data = json.data(using: .utf8)!
        return try! JSONDecoder().decode(PluginManifest.self, from: data)
    }

    /// 构造 resolver 注入 mock binary/brew locator。
    private func makeResolver(
        installedBinaries: Set<String> = [],
        brewPath: String? = "/opt/homebrew/bin/brew"
    ) -> DependencyResolver {
        let binaryLocator: BinaryLocator = { name, _ in
            // 已装的返回占位 URL（测试只关心是否 nil）
            return installedBinaries.contains(name) ? URL(fileURLWithPath: "/usr/bin/\(name)") : nil
        }
        let brewLocator: () -> BrewAvailability = {
            guard let path = brewPath else { return .missing }
            return .available(path: path)
        }
        return DependencyResolver(binaryLocator: binaryLocator, brewLocator: brewLocator)
    }

    // MARK: - collectMissing

    /// 契约 M2：全部依赖已装 → collectMissing 返回空。
    func test_AT01_collectMissing_allInstalled_returnsEmpty() {
        let plugin = makePlugin(deps: [("qrencode", "qrencode", "二维码")], requiredPath: ["qrencode"])
        let r = makeResolver(installedBinaries: ["qrencode"])
        XCTAssertTrue(r.collectMissing(plugin).isEmpty, "全装 → 无缺失")
    }

    /// 契约 M2：deps 声明的依赖缺失 → collectMissing 含该依赖。
    func test_AT02_collectMissing_depMissing_included() {
        let plugin = makePlugin(deps: [("qrencode", "qrencode", "二维码")])
        let r = makeResolver(installedBinaries: [])
        let missing = r.collectMissing(plugin)
        XCTAssertEqual(missing.count, 1)
        XCTAssertEqual(missing.first?.check, "qrencode")
        XCTAssertEqual(missing.first?.brewPackage, "qrencode")
        XCTAssertEqual(missing.first?.label, "二维码")
        XCTAssertFalse(missing.first?.isInstalled ?? true)
    }

    /// 契约 M2：requiredPath 缺失 → collectMissing 含该命令（无 brew/label 元数据）。
    func test_AT03_collectMissing_requiredPathMissing_includedNoBrew() {
        let plugin = makePlugin(requiredPath: ["some-tool"])
        let r = makeResolver(installedBinaries: [])
        let missing = r.collectMissing(plugin)
        XCTAssertEqual(missing.count, 1)
        XCTAssertEqual(missing.first?.check, "some-tool")
        XCTAssertNil(missing.first?.brewPackage, "requiredPath 衍生项无 brew 映射")
        XCTAssertNil(missing.first?.label, "requiredPath 衍生项无 label")
    }

    /// 契约 M2：requiredPath 与 deps.check 重名 → 去重（保留带元数据的 deps 版本）。
    func test_AT04_collectMissing_dedupesSameCheckName() {
        // deps 声明 qrencode（带 brew/label）+ requiredPath 也含 qrencode → 去重为 1 个
        let plugin = makePlugin(deps: [("qrencode", "qrencode", "二维码")], requiredPath: ["qrencode"])
        let r = makeResolver(installedBinaries: [])
        let missing = r.collectMissing(plugin)
        XCTAssertEqual(missing.count, 1, "同名 check 必须去重为 1 个")
        // 保留 deps 版本的元数据（brew/label）
        XCTAssertEqual(missing.first?.brewPackage, "qrencode")
        XCTAssertEqual(missing.first?.label, "二维码")
    }

    /// 契约 M2：部分装部分缺 → 只返回缺失的。
    func test_AT05_collectMissing_partialMissing() {
        let plugin = makePlugin(deps: [
            ("qrencode", "qrencode", "二维码"),
            ("imagemagick", "imagemagick", "图像处理")
        ])
        let r = makeResolver(installedBinaries: ["qrencode"])
        let missing = r.collectMissing(plugin)
        XCTAssertEqual(missing.count, 1)
        XCTAssertEqual(missing.first?.check, "imagemagick")
    }

    /// 契约 M2：无 deps 无 requiredPath 的 legacy 插件 → collectMissing 返回空。
    func test_AT06_collectMissing_noDepsNoRequiredPath_empty() {
        let plugin = makePlugin()
        let r = makeResolver(installedBinaries: [])
        XCTAssertTrue(r.collectMissing(plugin).isEmpty)
    }

    // MARK: - brewAvailability

    /// 契约 M2：brew 可用 → .available(path)。
    func test_AT07_brewAvailability_available() {
        let r = makeResolver(brewPath: "/opt/homebrew/bin/brew")
        if case .available(let path) = r.brewAvailability() {
            XCTAssertEqual(path, "/opt/homebrew/bin/brew")
        } else {
            XCTFail("brew 应可用")
        }
    }

    /// 契约 M2：brew 缺失 → .missing。
    func test_AT08_brewAvailability_missing() {
        let r = makeResolver(brewPath: nil)
        if case .missing = r.brewAvailability() {
            // ok
        } else {
            XCTFail("brew 缺失应返回 .missing")
        }
    }

    // MARK: - 全装状态（供弹框展示完整列表）

    /// 契约 M2 补充：collectStatuses 返回全部依赖状态（含已装），供弹框展示。
    /// collectMissing 是 collectStatuses.filter{ !$0.isInstalled }。
    func test_AT09_collectStatuses_includesInstalled() {
        let plugin = makePlugin(deps: [
            ("qrencode", "qrencode", "二维码"),
            ("imagemagick", "imagemagick", nil)
        ])
        let r = makeResolver(installedBinaries: ["qrencode"])
        let all = r.collectStatuses(plugin)
        XCTAssertEqual(all.count, 2)
        XCTAssertTrue(all.first { $0.check == "qrencode" }?.isInstalled ?? false)
        XCTAssertFalse(all.first { $0.check == "imagemagick" }?.isInstalled ?? true)
    }
}
