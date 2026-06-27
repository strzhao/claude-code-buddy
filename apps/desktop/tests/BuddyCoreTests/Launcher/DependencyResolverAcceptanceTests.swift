import XCTest
@testable import BuddyCore

// MARK: - DependencyResolverAcceptanceTests
//
// 红队验收测试（shimmering-bubbling-bonbon，依赖合并权限弹框，2026-06-25）
//
// 覆盖模块：M2 (T2) DependencyResolver（collectMissing + brewAvailability，合并 requiredPath 去重）
// 覆盖契约（state.md ## 契约规约）：
//   - 接口签名：
//     func collectMissing(_ plugin: PluginManifest) -> [DependencyStatus]
//     func brewAvailability() -> BrewAvailability   // .available(path) | .missing
//   - 数据结构：
//     struct DependencyStatus: Equatable { check: String; label: String?; isInstalled: Bool; brewPackage: String? }
//     enum BrewAvailability { case available(path: String); case missing }
//   - 设计文档 M2：遍历 plugin.deps + plugin.requiredPath，按 check 名去重；
//     每个用命令存在性检查（locateBinary）查 isInstalled；
//     brew 存在性：locateBinary("brew") → BrewAvailability
//     collectMissing 返回所有 isInstalled == false 的
//
// 覆盖验收场景：
//   - 场景 1 前置：qr 缺 qrencode → collectMissing 含 qrencode（1.P1 det-machine 依赖检测）
//   - 场景 2：qr 已信任 + 依赖齐 → collectMissing 返回 []（2.P1 放行短路前置）
//   - 场景 3：qr v2 缺 imagemagick → collectMissing 仅含 imagemagick（3.P2 仅列缺失依赖）
//   - 场景 5：无依赖插件 → collectMissing 返回 []（5.P1 无依赖区前置）
//   - 场景 6：brew 未装 → brewAvailability() == .missing（6.P1 brew 缺失分支前置）
//
// seam 设计：DependencyResolver 需注入 locateBinary 探测（mock 命令存在性）。
//
// 已对齐蓝队闭包 seam（CONTRACT_AMBIGUOUS 已解）：
//   蓝队 DependencyResolver 提供构造器注入 `binaryLocator: BinaryLocator` + `brewLocator: ()->BrewAvailability`
//   （闭包 seam，非 protocol，非单例无 seam）。红队 probe 闭包在 makeResolverWithProbe 内适配为双闭包注入。
//   BinaryLocator 签名 = (name: String, extPath: String) -> URL?（对齐 StdinExecutor.locateBinary）。
//
// 红队红线：不读 Sources/ClaudeCodeBuddy/Launcher/DependencyResolver.swift 等蓝队实现，
// 仅依据 state.md 的「## 契约规约 + ## 设计文档 M2」黑盒断言。

final class DependencyResolverAcceptanceTests: XCTestCase {

    // MARK: - Helpers

    private func decode<T: Decodable>(_ type: T.Type, from json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    /// 构造 qr manifest（command mode + deps，对齐 M8 契约）
    private func makeQRManifest(deps: String = "[]",
                                requiredPath: String = "[\"qrencode\"]") -> PluginManifest {
        let json = """
        {
          "name":"qr","version":"0.1.0","description":"qr","keywords":["qr"],
          "mode":"command","cmd":"./qr-gen.sh","args":[],
          "requiredPath":\(requiredPath),
          "deps":\(deps)
        }
        """
        // swiftlint:disable:next force_try
        return try! decode(PluginManifest.self, from: json)
    }

    // MARK: - 契约-M2: DependencyStatus 数据结构（check/isInstalled/brewPackage/label）

    /// 契约 M2 数据结构：DependencyStatus 四字段。
    /// 构造一个 status 验证字段可读 + Equatable。
    /// Mutation-Survival：若实现漏字段，编译挂。
    func test_M2_dependencyStatus_fieldsAccessible() {
        let status = DependencyStatus(
            check: "qrencode",
            label: "二维码生成库",
            isInstalled: false,
            brewPackage: "qrencode"
        )
        XCTAssertEqual(status.check, "qrencode", "check 字段必须可读（M2 数据结构）")
        XCTAssertEqual(status.label, "二维码生成库")
        XCTAssertEqual(status.isInstalled, false)
        XCTAssertEqual(status.brewPackage, "qrencode")
    }

    /// DependencyStatus Equatable：相同字段相等。
    func test_M2_dependencyStatus_equatable_sameValuesEqual() {
        let s1 = DependencyStatus(check: "x", label: nil, isInstalled: true, brewPackage: nil)
        let s2 = DependencyStatus(check: "x", label: nil, isInstalled: true, brewPackage: nil)
        XCTAssertEqual(s1, s2)
    }

    /// DependencyStatus Equatable Mutation 探针：isInstalled 不同则不等。
    func test_M2_dependencyStatus_equatable_isInstalledMutationNotEqual() {
        let s1 = DependencyStatus(check: "x", label: nil, isInstalled: true, brewPackage: nil)
        let s2 = DependencyStatus(check: "x", label: nil, isInstalled: false, brewPackage: nil)
        XCTAssertNotEqual(s1, s2, "isInstalled 不同时 DependencyStatus 必须 unequal（Mutation 探针）")
    }

    // MARK: - 契约-M2: BrewAvailability 二态枚举

    /// 契约 M2：BrewAvailability { case available(path: String); case missing }。
    /// 验证 available 关联值含 path。
    func test_M2_brewAvailability_availableCase_hasPath() {
        let avail: BrewAvailability = .available(path: "/opt/homebrew/bin/brew")
        guard case .available(let path) = avail else {
            return XCTFail("期望 .available，实际: \(avail)")
        }
        XCTAssertEqual(path, "/opt/homebrew/bin/brew",
                       ".available 关联值 path 必须精确（M2 BrewAvailability）")
    }

    /// 契约 M2：BrewAvailability.missing 无关联值。
    func test_M2_brewAvailability_missingCase_noAssoc() {
        let avail: BrewAvailability = .missing
        guard case .missing = avail else {
            return XCTFail("期望 .missing，实际: \(avail)")
        }
    }

    // MARK: - 场景 6 前置 / 契约-M2: brewAvailability() 在 brew 缺失时返回 .missing
    //
    // 已对齐蓝队闭包 seam（CONTRACT_AMBIGUOUS 已解）：
    //   brewAvailability() 通过构造器注入的 brewLocator 闭包控制（见 makeResolverWithProbe）。
    //   红队 probe 闭包适配为 binaryLocator + brewLocator 双闭包注入。

    /// 契约 M2 / 场景 6 前置：brew 未装 → brewAvailability() 返回 .missing。
    /// 用注入探测闭包（恒返 nil = 所有命令都「不存在」）模拟 brew 缺失。
    ///
    /// 对应 P#：场景 6（brew 未装 + 有 brew 依赖 → 失败 + 引导 brew.sh）的前置检测。
    func test_M2_brewAvailability_missing_whenBrewNotOnPath() throws {
        let resolver = try makeResolverWithProbe { name in
            // 所有命令都不存在（含 brew）
            return nil
        }
        let avail = resolver.brewAvailability()
        guard case .missing = avail else {
            return XCTFail("brew 缺失时 brewAvailability 必须返回 .missing（场景 6 前置），实际: \(avail)")
        }
    }

    /// 契约 M2 / 对照：brew 已装 → brewAvailability() 返回 .available(path:)。
    func test_M2_brewAvailability_available_whenBrewOnPath() throws {
        let resolver = try makeResolverWithProbe { name in
            return name == "brew" ? "/opt/homebrew/bin/brew" : nil
        }
        let avail = resolver.brewAvailability()
        guard case .available(let path) = avail else {
            return XCTFail("brew 已装时 brewAvailability 必须返回 .available(path:)，实际: \(avail)")
        }
        XCTAssertEqual(path, "/opt/homebrew/bin/brew")
    }

    // MARK: - 场景 1 前置 / 契约-M2: collectMissing 全缺 → 返回全部依赖

    /// 契约 M2 / 场景 1 前置：qr 缺 qrencode → collectMissing 含 qrencode（isInstalled=false）。
    /// 用注入探测闭包（恒返 nil = 全缺）模拟。
    ///
    /// 对应 P#：场景 1.P1（首次 + 缺 qrencode → 弹合并框）的依赖检测前置。
    /// Mutation-Survival：若 collectMissing 返回了 isInstalled=true 的项，本测试断言 isInstalled==false 挂。
    func test_M2_collectMissing_allMissing_returnsAllDeps() throws {
        let manifest = makeQRManifest(
            deps: "[{\"check\":\"qrencode\",\"brew\":\"qrencode\",\"label\":\"二维码生成库\"}]",
            requiredPath: "null"
        )
        let resolver = try makeResolverWithProbe { _ in nil } // 全缺

        let missing = resolver.collectMissing(manifest)

        XCTAssertEqual(missing.count, 1, "qr 声明 1 依赖且全缺 → collectMissing 返回 1 项")
        XCTAssertEqual(missing.first?.check, "qrencode")
        XCTAssertEqual(missing.first?.isInstalled, false, "缺失依赖 isInstalled 必须 false（场景 1）")
        XCTAssertEqual(missing.first?.brewPackage, "qrencode")
    }

    // MARK: - 场景 2 前置 / 契约-M2: collectMissing 全装 → 返回空（放行短路前置）

    /// 契约 M2 / 场景 2 前置：qr 依赖齐全 → collectMissing 返回 []。
    /// 用注入探测闭包（qrencode 命中）模拟。
    ///
    /// 对应 P#：场景 2.P1（已信任 + 依赖齐 → 不弹直接执行）的依赖检测前置。
    /// Mutation-Survival：若 collectMissing 漏过滤已装的，返回非空，本测试 count==0 挂。
    func test_M2_collectMissing_allInstalled_returnsEmpty() throws {
        let manifest = makeQRManifest(
            deps: "[{\"check\":\"qrencode\",\"brew\":\"qrencode\",\"label\":\"二维码生成库\"}]",
            requiredPath: "null"
        )
        let resolver = try makeResolverWithProbe { name in
            return name == "qrencode" ? "/opt/homebrew/bin/qrencode" : nil
        }

        let missing = resolver.collectMissing(manifest)

        XCTAssertTrue(missing.isEmpty,
                      "qr 依赖齐全时 collectMissing 必须返回空数组（场景 2：放行短路前置）")
    }

    // MARK: - 场景 3 前置 / 契约-M2: collectMissing 部分缺 → 仅返回缺失的

    /// 契约 M2 / 场景 3 前置：qr v2 deps=[qrencode, imagemagick]，qrencode 已装、imagemagick 缺
    /// → collectMissing 仅含 imagemagick（不列已装的 qrencode）。
    ///
    /// 对应 P#：场景 3.P2（重弹仅列缺失依赖，不列已装）的依赖检测前置。
    /// Mutation-Survival：若 collectMissing 把已装的也列出来，本测试 count==1 挂（应 2）。
    /// No-op kill：断言 missing 仅含 imagemagick（不含 qrencode）+ count==1。
    func test_M2_collectMissing_partialMissing_returnsOnlyMissing() throws {
        let manifest = makeQRManifest(
            deps: "[{\"check\":\"qrencode\",\"brew\":\"qrencode\",\"label\":\"二维码生成库\"},"
                + "{\"check\":\"convert\",\"brew\":\"imagemagick\",\"label\":\"图像处理库\"}]",
            requiredPath: "null"
        )
        let resolver = try makeResolverWithProbe { name in
            // qrencode 已装，convert(imagemagick) 缺
            return name == "qrencode" ? "/opt/homebrew/bin/qrencode" : nil
        }

        let missing = resolver.collectMissing(manifest)

        XCTAssertEqual(missing.count, 1, "部分缺时 collectMissing 仅返回缺失的（场景 3）")
        XCTAssertEqual(missing.first?.check, "convert",
                       "缺失的必须是 convert（imagemagick），不是已装的 qrencode")
        XCTAssertEqual(missing.first?.brewPackage, "imagemagick")
        XCTAssertFalse(missing.contains { $0.check == "qrencode" },
                       "collectMissing 不应含已装的 qrencode（场景 3.P2 negate）")
    }

    // MARK: - 场景 5 前置 / 契约-M2: 无依赖插件 → collectMissing 返回空

    /// 契约 M2 / 场景 5 前置：无依赖插件（deps=[] 或无 deps）→ collectMissing 返回 []。
    ///
    /// 对应 P#：场景 5.P1（无依赖插件首次 → 简洁信任框无依赖区）。
    func test_M2_collectMissing_noDeps_returnsEmpty() throws {
        let manifest = makeQRManifest(deps: "[]", requiredPath: "null")
        let resolver = try makeResolverWithProbe { _ in nil }

        let missing = resolver.collectMissing(manifest)

        XCTAssertTrue(missing.isEmpty,
                      "无依赖插件 collectMissing 必须返回空（场景 5：无依赖区前置）")
    }

    // MARK: - 契约-M2: collectMissing 合并 requiredPath + deps 去重

    /// 契约 M2：「遍历 plugin.deps + plugin.requiredPath，按 check 名去重」。
    /// qr 同时声明 deps=[qrencode] + requiredPath=[qrencode] → collectMissing 去重后只列 1 次。
    ///
    /// Mutation-Survival：若实现不去重，missing 会含两条 qrencode，count==1 挂（应 2）。
    /// No-op kill：断言 count==1 + 仅一条 check==qrencode。
    func test_M2_collectMissing_dedupes_requiredPathAndDeps() throws {
        // deps 和 requiredPath 都含 qrencode（设计文档：「requiredPath 保留；deps.check 等价」）
        let manifest = makeQRManifest(
            deps: "[{\"check\":\"qrencode\",\"brew\":\"qrencode\",\"label\":\"二维码生成库\"}]",
            requiredPath: "[\"qrencode\"]"
        )
        let resolver = try makeResolverWithProbe { _ in nil } // qrencode 缺

        let missing = resolver.collectMissing(manifest)

        XCTAssertEqual(missing.count, 1,
                       "deps + requiredPath 同名 check 必须去重为 1 条（M2 契约：按 check 名去重）")
        let qrencodeEntries = missing.filter { $0.check == "qrencode" }
        XCTAssertEqual(qrencodeEntries.count, 1, "去重后只能有一条 qrencode")
    }

    /// 契约 M2 去重 Mutation 探针：requiredPath 有但 deps 没有 → 仍计入 collectMissing。
    /// （设计文档：requiredPath 保留，与 deps 合并；requiredPath 单独声明也算依赖）
    func test_M2_collectMissing_requiredPathOnly_stillCounted() throws {
        let manifest = makeQRManifest(deps: "[]", requiredPath: "[\"legacy-tool\"]")
        let resolver = try makeResolverWithProbe { _ in nil }

        let missing = resolver.collectMissing(manifest)

        XCTAssertTrue(missing.contains { $0.check == "legacy-tool" },
                      "requiredPath 单独声明的命令也应计入 collectMissing（M2 合并）")
    }

    // MARK: - 契约-M2: DependencyStatus.brewPackage nil（无 brew 映射手装）

    /// 契约 M2：deps 里 brew=nil 的依赖 → DependencyStatus.brewPackage=nil（只能手装）。
    /// 设计文档：「brewPackage: String?（nil=无 brew 映射，只能手动装）」。
    func test_M2_collectMissing_depWithoutBrew_brewPackageNil() throws {
        let manifest = makeQRManifest(
            deps: "[{\"check\":\"custom-tool\",\"label\":\"自定义工具\"}]",
            requiredPath: "null"
        )
        let resolver = try makeResolverWithProbe { _ in nil }

        let missing = resolver.collectMissing(manifest)

        XCTAssertEqual(missing.first?.check, "custom-tool")
        XCTAssertNil(missing.first?.brewPackage,
                     "无 brew 映射的依赖 brewPackage 必须 nil（M2：只能手装）")
    }

    // MARK: - seam helper（已对齐蓝队闭包 seam，CONTRACT_AMBIGUOUS 已解）

    /// 构造一个注入探测闭包的 DependencyResolver。
    /// 蓝队真相：DependencyResolver(binaryLocator: BinaryLocator, brewLocator: ()->BrewAvailability)
    ///   - BinaryLocator = (name: String, extPath: String) -> URL?
    ///   - brewLocator: () -> BrewAvailability
    /// 红队 probe: (String) -> String?（返路径字符串或 nil）适配为：
    ///   - binaryLocator: 把 probe 返回的路径字符串转 URL?
    ///   - brewLocator: 复用 probe("brew") 判定（返路径 → .available(path)，nil → .missing）
    /// 断言值（check/qrencode/imagemagick 精确字符串 + count + isInstalled）原样保留。
    private func makeResolverWithProbe(_ probe: @escaping (String) -> String?) throws -> DependencyResolver {
        let binaryLocator: BinaryLocator = { name, _ in
            guard let path = probe(name) else { return nil }
            return URL(fileURLWithPath: path)
        }
        let brewLocator: () -> BrewAvailability = {
            guard let path = probe("brew") else { return .missing }
            return .available(path: path)
        }
        return DependencyResolver(binaryLocator: binaryLocator, brewLocator: brewLocator)
    }
}
