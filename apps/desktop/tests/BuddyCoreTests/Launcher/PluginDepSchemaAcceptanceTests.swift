import XCTest
@testable import BuddyCore

// MARK: - PluginDepSchemaAcceptanceTests
//
// 红队验收测试（shimmering-bubbling-bonbon，依赖合并权限弹框，2026-06-25）
//
// 覆盖模块：M1 (T1) PluginDep schema + Codable + CLI mirror
// 覆盖契约（state.md ## 契约规约）：
//   - 接口签名：struct PluginDep: Codable, Equatable { let check: String; let brew: String?; let label: String? }
//   - 数据结构：check 非空命令名；brew=nil 无 brew 映射手装；label 人话描述
//   - 边界值：PluginDep.check.count >= 1（非空命令名）
//   - 错误契约：PluginDep.check 为空 → Codable decode 失败 → 插件加载失败
//   - CLI mirror 契约：BuddyCLI/Foundation-only 镜像 PluginDep Codable（decodeIfPresent ?? []），
//     inspect 输出含 deps 字段；降级逻辑与 app 逐字一致（无 deps → []）
//
// 覆盖验收场景（state.md ## 验收场景）：
//   - 场景 8：plugin.json 声明 deps → inspect CLI 显示 deps（8.P1 det-machine）
//   - 场景 9：legacy 插件（无 deps 字段）→ 向后兼容（9.P1 det-machine：deps 视为空 + exit=0）
//
// 跨系统数据流（红队铁律 4）：plugin.json deps → app PluginManifest → CLI inspect mirror
// 字段一致性（PluginDep 三字段 check/brew/label round-trip）。
//
// 红队红线：不读 Sources/ClaudeCodeBuddy/Launcher/Plugin/PluginManifest.swift 等蓝队实现，
// 仅依据 state.md 的「## 契约规约 + ## 设计文档 M1」黑盒断言。
//
// 已对齐蓝队闭包 seam（CONTRACT_AMBIGUOUS 已解）：
//   PluginManifest.deps 是非可选 [PluginDep]（decodeIfPresent ?? [] 在 init(from:) 内完成），
//   非 [PluginDep]?。红队原假设的 if let/guard let manifest.deps 已改为直接访问 manifest.deps。
//   断言值（check/brew/label 精确字符串 + count）原样保留。

final class PluginDepSchemaAcceptanceTests: XCTestCase {

    // MARK: - Helpers

    private func decode<T: Decodable>(_ type: T.Type, from json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    /// qr 插件的契约级 fixture（对齐 state.md M8：deps=[{check:qrencode,brew:qrencode,label:二维码生成库}]）
    private func qrDepsJSON() -> String {
        """
        {"check":"qrencode","brew":"qrencode","label":"二维码生成库"}
        """
    }

    // MARK: - 场景 8.P1 / 契约-M1: PluginDep 三字段 Codable round-trip

    /// 契约 M1：PluginDep { check, brew, label } Codable 完整 fixture 编解码后字段精确相等。
    /// 对应 P#：场景 8.P1（plugin.json 声明 deps → inspect CLI 显示 deps）的契约前置。
    /// Mutation-Survival：若实现把 brew/label 当 String（非可选），无 brew 映射的依赖 decode 会挂。
    func test_M1_pluginDep_fullFixture_codableRoundTrip() throws {
        let dep = try decode(PluginDep.self, from: qrDepsJSON())

        XCTAssertEqual(dep.check, "qrencode",
                       "check 字段必须精确是 'qrencode'（M1 契约）")
        XCTAssertEqual(dep.brew, "qrencode",
                       "brew 字段必须精确是 'qrencode'（M1 契约）")
        XCTAssertEqual(dep.label, "二维码生成库",
                       "label 字段必须精确是 '二维码生成库'（M1 契约）")
    }

    // MARK: - 契约-M1: PluginDep brew=nil（无 brew 映射，只能手装）

    /// 契约 M1：brew=nil 表示无 brew 映射，只能手装。decode 后 brew 必须为 nil。
    /// 对应设计文档：「brewPackage: String?（nil=无 brew 映射，只能手动装）」。
    func test_M1_pluginDep_nilBrew_decodesAsNil() throws {
        let json = """
        {"check":"custom-tool","label":"自定义工具"}
        """
        let dep = try decode(PluginDep.self, from: json)

        XCTAssertEqual(dep.check, "custom-tool")
        XCTAssertNil(dep.brew, "缺 brew 字段时必须为 nil（M1：无 brew 映射手装）")
        XCTAssertEqual(dep.label, "自定义工具")
    }

    // MARK: - 契约-M1: PluginDep label=nil（无人话描述）

    /// 契约 M1：label=nil 表示无人话描述。decode 后 label 必须为 nil。
    func test_M1_pluginDep_nilLabel_decodesAsNil() throws {
        let json = """
        {"check":"qrencode","brew":"qrencode"}
        """
        let dep = try decode(PluginDep.self, from: json)

        XCTAssertEqual(dep.check, "qrencode")
        XCTAssertEqual(dep.brew, "qrencode")
        XCTAssertNil(dep.label, "缺 label 字段时必须为 nil")
    }

    // MARK: - 边界值契约: PluginDep.check.count >= 1（非空命令名）

    /// 契约 边界值：PluginDep.check.count >= 1（非空命令名）。空字符串 check 必须 decode 失败
    /// （错误契约：PluginDep.check 为空 → Codable decode 失败 → 插件加载失败）。
    ///
    /// Mutation-Survival：若实现不校验空 check，本测试挂。
    /// No-op kill：实现把 check decode 成 "" 也能 round-trip，但本测试断言 decode 抛错。
    func test_M1_pluginDep_emptyCheck_decodeFails() throws {
        let json = """
        {"check":"","brew":"qrencode","label":"空 check"}
        """
        XCTAssertThrowsError(try decode(PluginDep.self, from: json),
                             "PluginDep.check 为空字符串必须 decode 失败（边界值：check.count >= 1）")
    }

    // MARK: - 契约-M1: PluginDep 缺 check 字段 → decode 失败（keyNotFound）

    /// 契约 M1：check 是必填字段。缺 check 必须抛 keyNotFound。
    func test_M1_pluginDep_missingCheck_decodeFailsWithKeyNotFound() throws {
        let json = """
        {"brew":"qrencode","label":"无 check"}
        """
        XCTAssertThrowsError(try decode(PluginDep.self, from: json),
                             "PluginDep 缺 check 字段必须 decode 失败（M1：check 必填）")
    }

    // MARK: - 场景 8.P1 / 跨系统数据流: PluginManifest.deps 含 PluginDep 数组

    /// 契约 M1 / 场景 8.P1：plugin.json 含 deps 数组 → PluginManifest.deps 解析出 PluginDep 列表。
    /// 这是「plugin.json deps → app PluginManifest」的跨系统数据流第一跳。
    ///
    /// 对应 P#：场景 8.P1（plugin.json 声明 deps → inspect CLI 显示 deps）。
    func test_M1_pluginManifest_depsArray_decodesPluginDepList() throws {
        let json = """
        {
          "name":"qr","version":"0.1.0","description":"qr","keywords":["qr"],
          "mode":"command","cmd":"./qr-gen.sh","args":[],
          "deps":[{"check":"qrencode","brew":"qrencode","label":"二维码生成库"}]
        }
        """
        let manifest = try decode(PluginManifest.self, from: json)

        // deps 必须被解析为非空数组（蓝队：deps 非可选 [PluginDep]，decodeIfPresent ?? []）
        let deps = manifest.deps
        XCTAssertFalse(deps.isEmpty,
                       "PluginManifest.deps 必须解析出非空数组（场景 8.P1：plugin.json 声明 deps）")
        XCTAssertEqual(deps.count, 1, "qr 声明 1 个依赖")
        XCTAssertEqual(deps.first?.check, "qrencode",
                       "首个依赖 check 必须是 'qrencode'")
        XCTAssertEqual(deps.first?.brew, "qrencode")
        XCTAssertEqual(deps.first?.label, "二维码生成库")
    }

    // MARK: - 场景 9.P1 / 向后兼容: legacy 无 deps 字段 → deps 视为 []（decodeIfPresent ?? []）

    /// 契约 M1 / 场景 9.P1：legacy 插件无 deps 字段 → decode 成功，deps 视为空数组（decodeIfPresent ?? []）。
    /// 这是「向后兼容」契约的核心断言。
    ///
    /// 对应 P#：场景 9.P1（legacy 无 deps，inspect 正常输出，deps 视为空 + exit=0）。
    /// Mutation-Survival：若实现把 deps 当 [PluginDep]（非可选），无 deps 字段 decode 会挂。
    func test_M1_legacyPluginWithoutDeps_decodesAsEmptyArray() throws {
        let json = """
        {
          "name":"legacy-plugin","version":"0.1.0","description":"legacy","keywords":["old"],
          "mode":"stdin","cmd":"./run.sh"
        }
        """
        let manifest = try decode(PluginManifest.self, from: json)

        // 契约：无 deps 字段 → 视为空数组（蓝队：decodeIfPresent ?? [] 在 init(from:) 内完成）
        // 关键断言：decode 不抛错（走到这里即证明），且 deps 必须为空数组。
        XCTAssertTrue(manifest.deps.isEmpty,
                      "legacy 无 deps 字段时 deps 必须为空数组（场景 9.P1：向后兼容）")
    }

    // MARK: - 场景 9.P1: legacy 无 deps → inspect 不报错（exit=0 等价：decode 成功）

    /// 契约 M1 / 场景 9.P1：legacy inspect 不报错 deps 视为空。
    /// 单测层等价断言：decode 不抛错。CLI mirror 的 deps 输出一致性留跨系统测试。
    func test_M1_legacyPluginWithoutDeps_decodeSucceeds() throws {
        let json = """
        {"name":"legacy","version":"0.1.0","description":"d","keywords":[],"mode":"stdin","cmd":"./x"}
        """
        // 关键断言：不抛错（exit=0 的单测等价）
        let manifest = try decode(PluginManifest.self, from: json)
        XCTAssertEqual(manifest.name, "legacy")
    }

    // MARK: - 跨系统数据流: deps 含多个依赖（qrencode + imagemagick，对齐场景 3 v2 新增依赖）

    /// 契约 M1 / 场景 3 前置：plugin.json deps 从 [qrencode] 变 [qrencode, imagemagick]。
    /// 验证多依赖数组 round-trip（为场景 3「已信任 + 新增依赖重弹」做契约前置）。
    func test_M1_pluginManifest_multipleDeps_roundTrip() throws {
        let json = """
        {
          "name":"qr","version":"0.2.0","description":"qr v2","keywords":["qr"],
          "mode":"command","cmd":"./qr-gen.sh","args":[],
          "deps":[
            {"check":"qrencode","brew":"qrencode","label":"二维码生成库"},
            {"check":"convert","brew":"imagemagick","label":"图像处理库"}
          ]
        }
        """
        let manifest = try decode(PluginManifest.self, from: json)
        // 蓝队：deps 非可选 [PluginDep]，直接访问
        let deps = manifest.deps
        XCTAssertEqual(deps.count, 2, "v2 声明 2 个依赖（场景 3：新增 imagemagick）")

        let checks = deps.map(\.check)
        XCTAssertEqual(checks, ["qrencode", "convert"],
                       "两个依赖 check 必须分别是 qrencode / convert")
        XCTAssertEqual(deps.last?.brew, "imagemagick",
                       "第二个依赖 brew 必须是 'imagemagick'")
    }

    // MARK: - 跨系统数据流: PluginManifest encode 后含 deps 字段（round-trip 一致性）

    /// 契约 M1：PluginManifest encode 后 JSON 必须含 "deps" key（当 deps 非空）。
    /// 验证 plugin.json deps 在 app 层无损保留，CLI inspect 读同一 plugin.json 能拿到。
    func test_M1_pluginManifest_encodeIncludesDepsKey() throws {
        let json = """
        {
          "name":"qr","version":"0.1.0","description":"qr","keywords":["qr"],
          "mode":"command","cmd":"./qr-gen.sh","args":[],
          "deps":[{"check":"qrencode","brew":"qrencode","label":"二维码生成库"}]
        }
        """
        let manifest = try decode(PluginManifest.self, from: json)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(manifest)
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertNotNil(obj["deps"], "encode 后 JSON 必须含 deps 字段（跨系统一致性）")
        let depsArray = try XCTUnwrap(obj["deps"] as? [[String: Any]])
        XCTAssertEqual(depsArray.count, 1)
        XCTAssertEqual(depsArray.first?["check"] as? String, "qrencode")
        XCTAssertEqual(depsArray.first?["brew"] as? String, "qrencode")
        XCTAssertEqual(depsArray.first?["label"] as? String, "二维码生成库")
    }

    // MARK: - CLI mirror 契约: PluginDep Equatable（app 与 CLI mirror 字段比对基础）

    /// 契约 M1：PluginDep: Equatable。相同字段值必须相等。
    /// 这是 CLI mirror 与 app PluginManifest 字段一致性比对的契约基础（跨系统数据流）。
    func test_M1_pluginDep_equatable_sameValuesEqual() {
        let d1 = PluginDep(check: "qrencode", brew: "qrencode", label: "二维码生成库")
        let d2 = PluginDep(check: "qrencode", brew: "qrencode", label: "二维码生成库")
        XCTAssertEqual(d1, d2, "相同字段值的 PluginDep 必须 Equatable 相等（M1）")
    }

    /// PluginDep Equatable Mutation 探针：check 不同则不等。
    func test_M1_pluginDep_equatable_differentCheckNotEqual() {
        let d1 = PluginDep(check: "qrencode", brew: "qrencode", label: nil)
        let d2 = PluginDep(check: "convert", brew: "imagemagick", label: nil)
        XCTAssertNotEqual(d1, d2, "check 不同时 PluginDep 不应相等（Mutation 探针）")
    }

    /// PluginDep Equatable Mutation 探针：brew 一个 nil 一个非 nil 则不等。
    func test_M1_pluginDep_equatable_brewNilVsValueNotEqual() {
        let d1 = PluginDep(check: "x", brew: nil, label: nil)
        let d2 = PluginDep(check: "x", brew: "x", label: nil)
        XCTAssertNotEqual(d1, d2, "brew nil vs 非 nil 必须 unequal（Mutation 探针）")
    }
}
