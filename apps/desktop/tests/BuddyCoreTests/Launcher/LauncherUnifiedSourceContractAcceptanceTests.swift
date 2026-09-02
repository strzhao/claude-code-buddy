import XCTest
@testable import BuddyCore

// MARK: - LauncherUnifiedSourceContractAcceptanceTests
//
// 红队验收测试（TDD 红灯）：退役符号源码契约（fs-grep）——场景11.P2 + D3/D6
//
// 设计文档契约引用：
//   D3：退役 commandRouteCandidates / 自动锁定 / lastRoutePluginName chip；CandidateZone 删 .commandRoute
//   D6：单列表 LauncherInstantCandidateView；删 LauncherCandidateView / PluginWatermarkChip /
//       commandRoute 区 / panelHeight 删 commandRouteExtra
//   场景11.P2：源码 grep PluginWatermarkChip==0 且 commandRouteCandidates==0（fs-grep，
//   读 Sources 目录文件字符串断言）
//   场景5.P2：[visual-residue] 插件行与 app 行高亮一致——留 QA 真机（VISUAL_RESIDUE 注释登记）
//
// 源码文本契约说明（沿用 LauncherSourceContractAcceptanceTests 先例）：
//   这些是「源码文本契约」而非「运行时行为契约」，grep 策略完全准确——
//   退役符号只要还在源码里出现，就说明分区/水印实现残留。
//
// 文件缺失即失败（XCTFail），绝无 XCTSkip / 条件 warn——退役是硬契约。

final class LauncherUnifiedSourceContractAcceptanceTests: XCTestCase {

    // MARK: - 路径与扫描辅助

    private var projectRoot: String {
        var url = URL(fileURLWithPath: #file)
        for _ in 0..<12 {
            url = url.deletingLastPathComponent()
            if FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path) {
                return url.path
            }
        }
        return "/Users/stringzhao/workspace_sync/personal_projects/claude-code-buddy"
    }

    private var appSourcesDir: String {
        "\(projectRoot)/apps/desktop/Sources/ClaudeCodeBuddy"
    }

    /// 递归收集目录下全部 .swift 文件路径
    private func swiftFiles(in dir: String) throws -> [String] {
        guard FileManager.default.fileExists(atPath: dir) else {
            XCTFail("源码目录必须存在：\(dir)")
            return []
        }
        var results: [String] = []
        let enumerator = FileManager.default.enumerator(atPath: dir)
        while let relative = enumerator?.nextObject() as? String {
            if relative.hasSuffix(".swift") {
                results.append(dir + "/" + relative)
            }
        }
        return results
    }

    /// 断言全部源文件中 token 出现次数为 0；返回是否全通过（供统一汇总断言）
    @discardableResult
    private func assertTokenRetired(_ token: String, files: [String]) -> Bool {
        var offenders: [String] = []
        for path in files {
            guard let source = try? String(contentsOfFile: path, encoding: .utf8) else {
                XCTFail("源文件必须可读：\(path)")
                return false
            }
            if source.contains(token) {
                offenders.append(path)
            }
        }
        XCTAssertTrue(offenders.isEmpty,
            """
            退役符号源码契约违反：「\(token)」仍出现在 \(offenders.count) 个源文件中：
            \(offenders.joined(separator: "\n"))
            设计要求：该符号属旧 command 路由分区/水印 chip 实现，本次「插件候选一等公民统一混排」
            必须整体退役（D3/D6），任何残留引用（含注释中的类型名）均判失败。
            """)
        return offenders.isEmpty
    }

    // MARK: - 场景11.P2 [fs-grep]：PluginWatermarkChip 与 commandRouteCandidates 全源码退役

    /// 场景11.P2：grep PluginWatermarkChip==0 且 commandRouteCandidates==0。
    func test_scenario11_P2_watermarkChipAndCommandRouteCandidates_fullyRetired() throws {
        let files = try swiftFiles(in: appSourcesDir)
        XCTAssertFalse(files.isEmpty, "场景11.P2 前置: 必须扫描到源文件：\(appSourcesDir)")

        assertTokenRetired("PluginWatermarkChip", files: files)
        assertTokenRetired("commandRouteCandidates", files: files)
    }

    // MARK: - D3/D6 退役扩展：CandidateZone .commandRoute case 与 commandRouteExtra 高度项

    /// D3/D6：CandidateZone 删 .commandRoute case；panelHeight 删 commandRouteExtra。
    /// grep token：`commandRoute`（覆盖 .commandRoute case 与 commandRouteExtra 命名族——
    /// 退役后源码不应再有任何 commandRoute 命名残留）。
    func test_D3_D6_commandRouteFamily_fullyRetired() throws {
        let files = try swiftFiles(in: appSourcesDir)
        XCTAssertFalse(files.isEmpty, "D3/D6 前置: 必须扫描到源文件：\(appSourcesDir)")

        assertTokenRetired("commandRoute", files: files)
        assertTokenRetired("LauncherCandidateView", files: files)
    }

    // MARK: - 场景5.P2 [visual-residue]：插件行与 app 行高亮一致（登记，不写 UI 快照测试）

    // ⚠️ 按预注册谓词，场景5.P2 不写 XCTest 用例（「标注 VISUAL_RESIDUE 注释即可，不写 UI 快照测试」）。
    // VISUAL_RESIDUE（QA 真机判定清单，随 manifest 上报）：
    //   - [ ] 插件行选中态高亮与 app 行选中态高亮一致（同 sage pill、同圆角、同 alpha）
    //   - [ ] 插件行 emoji icon（iconEmoji）渲染尺寸与 app 行 NSImage icon 视觉均衡
    //   - [ ] manifest.icon==nil 时插件行 fallback 统一 SF Symbol 与 app 行 fallback 同形
    //   - [ ] LockedCommandChip（Tab 锁定后）替代旧 PluginWatermarkChip 的视觉呈现正确
}
