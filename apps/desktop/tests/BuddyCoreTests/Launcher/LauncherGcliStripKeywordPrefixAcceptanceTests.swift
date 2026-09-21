import XCTest
@testable import BuddyCore

// MARK: - LauncherGcliStripKeywordPrefixAcceptanceTests
//
// 红队验收测试（TDD 红灯）：W2 双层前缀触发词修复——Swift 侧 stripKeywordPrefix 六例
//
// 谓词映射（SSOT: state.md ## 验收场景）：
//   s2p5 [real-process] stripKeywordPrefix 六例：
//     gc→"" / gcli→"" / "gcli kimi"→"kimi" / 限→"" / kim→"kim" / ""→""
//     exit==0 失败数 0 ｜ artifact: /tmp/autopilot-artifacts/s2p5.out
//
// 契约逐字一致（## 契约规约 接口签名 invariant）：
//   static func stripKeywordPrefix(_ query: String, manifest: PluginManifest) -> String
//   优先级：1) queryLower 以某 prefix 开头 → 剥离剩余（既有）
//         2) 某 prefixLower.hasPrefix(queryLower) 且 !queryLower.isEmpty → ""（新增 W2）
//         3) 否则原样返回
//   manifest fixture：name "gcli"（W1 改名后）+ keywords ["gcli","限额","套餐","用量"]（W1 词表逐字）
//
// 红队红线：只用既有符号（stripKeywordPrefix / PluginManifest 既有签名），未读蓝队实现。
// 新增分支未实现时 gc/限 两例失败（其余既有分支用例通过）＝精确 TDD 红灯。
//
// Mutation-Survival 自检：
//   - No-op（不加分支 2）→ gc→"gc"、限→"限" ≠ "" → 失败（捕获）
//   - Conditional Flip（分支 2 条件写反/漏 !isEmpty）→ ""→非"" 或 gc→非"" → 失败（捕获）
//   - Boundary（真前缀误判含相等：prefix==query 走分支 1 剥离剩余语义，单列 gcli→"" 守护）

@MainActor
final class LauncherGcliStripKeywordPrefixAcceptanceTests: XCTestCase {

    // MARK: - fixture（W1 改名后词表，契约逐字）

    private func makeGcliManifest() -> PluginManifest {
        let json: [String: Any] = [
            "name": "gcli",
            "version": "0.2.0-test",
            "description": "gcli 套餐限额查询（红队 fixture）",
            "keywords": ["gcli", "限额", "套餐", "用量"],
            "mode": "command",
            "cmd": "echo",
            "args": [] as [String]
        ]
        return try! JSONDecoder().decode(PluginManifest.self,
                                         from: try JSONSerialization.data(withJSONObject: json))
    }

    private func writeArtifact(_ name: String, _ lines: [String]) {
        let dir = "/tmp/autopilot-artifacts"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let content = ([name] + lines).joined(separator: "\n") + "\n"
        try? content.write(toFile: dir + "/" + name, atomically: true, encoding: .utf8)
    }

    // MARK: - s2p5 六例（设计 ## 边界值 正例/边界/反例 逐字）

    /// s2p5 [real-process]：stripKeywordPrefix 六例全过（失败数 0）
    func test_s2p5_stripKeywordPrefix_sixCases_zeroFailures() {
        let manifest = makeGcliManifest()
        // (query, expected) —— 字面量逐字取自 s2p5 谓词
        let cases: [(String, String)] = [
            ("gc", ""),            // 正例：keyword "gcli" 的非空真前缀 → ""（W2 新分支）
            ("gcli", ""),          // 边界：既有完全剥离分支
            ("gcli kimi", "kimi"), // 边界：既有剥离剩余分支
            ("限", ""),             // 正例：中文 keyword "限额" 的前缀 → ""（W2 新分支）
            ("kim", "kim"),        // 反例：非任何 keyword 前缀 → 原样
            ("", ""),              // 反例：空早返
        ]
        var evidence: [String] = ["manifest: name=gcli keywords=[gcli,限额,套餐,用量]"]
        var failures = 0
        for (query, expected) in cases {
            let got = LauncherManager.stripKeywordPrefix(query, manifest: manifest)
            evidence.append("stripKeywordPrefix(\"\(query)\") = \"\(got)\" (expect \"\(expected)\")")
            if got != expected { failures += 1 }
        }
        evidence.append("failures=\(failures)/\(cases.count)")
        writeArtifact("s2p5.out", evidence)
        XCTAssertEqual(failures, 0,
            "s2p5: stripKeywordPrefix 六例必须全过（gc→空 与 限→空 为 W2 新分支），" +
            "失败 \(failures) 例；证据见 /tmp/autopilot-artifacts/s2p5.out")
    }

    // MARK: - 大小写归一（契约「queryLower/prefixLower」语义补充守护，无独立 artifact）

    /// 契约用 queryLower/prefixLower 描述 → 大写输入同语义："GC"→""、"GCLI KIMI"→"KIMI"
    func test_caseInsensitive_prefixBranch() {
        let manifest = makeGcliManifest()
        XCTAssertEqual(LauncherManager.stripKeywordPrefix("GC", manifest: manifest), "",
            "契约 lowercased 归一：「GC」是 keyword gcli 的前缀 → 空")
        XCTAssertEqual(LauncherManager.stripKeywordPrefix("GCLI KIMI", manifest: manifest), "KIMI",
            "契约 lowercased 归一：「GCLI KIMI」剥离剩余得 KIMI（保留参数原大小写）")
    }
}
