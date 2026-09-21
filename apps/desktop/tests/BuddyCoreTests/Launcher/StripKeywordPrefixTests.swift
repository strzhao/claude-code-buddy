import XCTest
@testable import BuddyCore

// MARK: - StripKeywordPrefixTests
//
// 蓝队单测：stripKeywordPrefix 半截触发词前缀分支（W2，2026-09-21 gcli 插件改名修复）。
//
// 契约（state.md ## 契约规约 接口签名，语义不变式）：
//   static func stripKeywordPrefix(_ query: String, manifest: PluginManifest) -> String
//   优先级：1) queryLower 以某 prefix 开头 → 剥离剩余（既有，严格分隔）
//          2) 某 prefixLower.hasPrefix(queryLower) 且 !queryLower.isEmpty → ""（新增）
//          3) 否则原样返回
//
// 根因：搜索层给「query 是 name 前缀」800 分保证可发现（如 "gc" ⊂ "gcli"），
// 但回车分发把原始 query 下发；旧实现只认完整触发词，半截词 "gc" 穿透到插件侧
// 被当条目名过滤词 → 插件报「没有名称匹配」。新分支：半截触发词 = 无参数 → ""。
//
// 边界值（设计文档 边界值 章节，正/边界/反 六例 1:1）：
//   正例  "gc"       → ""      （"gc" 是 keyword "gcli" 的非空真前缀）
//   边界  "gcli"     → ""      （既有完全剥离分支）
//   边界  "gcli kimi" → "kimi" （既有剥离剩余分支）
//   边界  "限"       → ""      （中文 keyword "限额" 的前缀）
//   反例  "kim"      → "kim"  （非本插件任何 keyword 的前缀，原样）
//   反例  ""         → ""      （空早返）

final class StripKeywordPrefixTests: XCTestCase {

    /// gcli 插件 manifest（name + keywords 逐字对齐 plugins/quota/plugin.json 改名后形态）
    private var gcliManifest: PluginManifest {
        let json: [String: Any] = [
            "name": "gcli",
            "version": "0.2.0",
            "description": "套餐限额查询",
            "keywords": ["gcli", "限额", "套餐", "用量"],
            "mode": "command",
            "cmd": "./quota.py",
            "args": [] as [String]
        ]
        return try! JSONDecoder().decode(
            PluginManifest.self,
            from: try JSONSerialization.data(withJSONObject: json))
    }

    private func strip(_ query: String) -> String {
        LauncherManager.stripKeywordPrefix(query, manifest: gcliManifest)
    }

    // MARK: - 六例（s2p5 谓词 1:1）

    func test_正例_gc_是gcli前缀_返回空() {
        XCTAssertEqual(strip("gc"), "", "「gc」是 keyword「gcli」的非空真前缀 → \"\"（半截触发词=无参数）")
    }

    func test_边界_gcli_完整词_返回空() {
        XCTAssertEqual(strip("gcli"), "", "query 恰是 keyword 本身 → \"\"（既有完全剥离分支）")
    }

    func test_边界_gcli空格kimi_剥离剩余() {
        XCTAssertEqual(strip("gcli kimi"), "kimi", "既有剥离剩余分支不受新分支影响")
    }

    func test_边界_中文单字限_返回空() {
        XCTAssertEqual(strip("限"), "", "「限」是中文 keyword「限额」的前缀 → \"\"")
    }

    func test_反例_kim_非任何keyword前缀_原样() {
        XCTAssertEqual(strip("kim"), "kim", "「kim」不是本插件任何 keyword 的前缀 → 原样（作过滤词）")
    }

    func test_反例_空串_返回空() {
        XCTAssertEqual(strip(""), "", "空 query → \"\"（空早返）")
    }

    // MARK: - 既有严格分隔语义回归守护（新分支不得引入错切）

    func test_trace_不被tr类前缀错切() {
        let trManifest: PluginManifest = {
            let json: [String: Any] = [
                "name": "tr",
                "version": "1.0.0",
                "description": "翻译",
                "keywords": ["tr", "translate", "翻译"],
                "mode": "command",
                "cmd": "./run.sh",
                "args": [] as [String]
            ]
            return try! JSONDecoder().decode(
                PluginManifest.self,
                from: try JSONSerialization.data(withJSONObject: json))
        }()
        // "trace" 是 "tr" 的超集（方向相反，既有分支不切）；也不是 "translate" 的前缀
        // （t-r-a-n vs t-r-a-c 第 4 字母分叉）→ 原样保留
        XCTAssertEqual(
            LauncherManager.stripKeywordPrefix("trace", manifest: trManifest),
            "trace",
            "新前缀分支不得把「trace」错切（它既非「translate」前缀，也非任何 keyword 完整前缀命中）")
    }

    func test_gclix_非gcli前缀_原样() {
        XCTAssertEqual(strip("gclix"), "gclix", "「gclix」比 keyword「gcli」长且非完整命中 → 原样")
    }

    func test_大小写不敏感_GC_返回空() {
        XCTAssertEqual(strip("GC"), "", "前缀判定大小写不敏感（queryLower 通道）")
    }
}
