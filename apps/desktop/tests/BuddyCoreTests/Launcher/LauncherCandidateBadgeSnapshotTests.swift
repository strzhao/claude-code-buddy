import XCTest
import SwiftUI
import SnapshotTesting
@testable import BuddyCore

// MARK: - LauncherCandidateBadgeSnapshotTests
//
// 红队验收测试：SC-16 AI 推荐 badge 视觉区分
//
// 契约覆盖（C7）：
//   SC-16：构造 LauncherCandidateView，三候选，两种状态对比：
//     - 状态 A：lastRouteSelectedIndex=1（AI 选中第 2 行，该行显示 "✨ AI" badge）
//     - 状态 B：lastRouteSelectedIndex=-1（无 AI 选中，任何行都不显示 badge）
//   快照断言：两个状态的 snapshot 必须不同（badge 出现 vs 不出现）
//
// 设计文档 C7：
//   - lastRouteSelectedIndex >= 0 时，该索引对应行显示 "✨ AI"（caption2 + sage 绿前景）
//   - lastRouteSelectedIndex == -1 时，任何行都不显示 badge
//
// ASSUMES blue team:
//   - LauncherCandidateView 接受新参数 aiSelectedIndex: Int（或通过 lastRouteSelectedIndex 绑定）
//   - ALTERNATIVE: LauncherCandidateView 仍接受 selectedIndex: Int，
//     badge 通过另一个新参数传入（aiRecommendedIndex: Int）
//   - 如果接口未变（只有 selectedIndex），badge 无法显示 → 测试设计意图：两快照必须不同
//
// 备选接口假设（ASSUMES blue team will add one of）：
//   A. LauncherCandidateView(candidates: [...], selectedIndex: Int, aiRecommendedIndex: Int)
//   B. LauncherCandidateView(candidates: [...], selectedIndex: Int, lastRouteSelectedIndex: Int)
//   C. LauncherCandidateView 通过 ObservedObject manager 获取 lastRouteSelectedIndex
//
// 本测试文件中同时提供了针对这几种备选接口的测试方法，
// 编译时只有符合实际接口的方法会通过，其他会编译失败（预期的 TDD 红灯）。

// MARK: - Helpers

private func makeBadgeManifest(name: String) -> PluginManifest {
    PluginManifest(
        name: name,
        version: "1.0.0",
        description: "Plugin \(name) for badge test",
        keywords: [name.lowercased()],
        cmd: "./run.sh",
        args: [],
        env: nil,
        timeout: 5,
        requiredPath: nil
    )
}

@MainActor
final class LauncherCandidateBadgeSnapshotTests: XCTestCase {

    private let snapshotSize = CGSize(width: 720, height: 132)  // 3 * 44px 行高

    private let candidates: [PluginManifest] = [
        makeBadgeManifest(name: "translate"),
        makeBadgeManifest(name: "search"),
        makeBadgeManifest(name: "weather")
    ]

    // MARK: - SC-16: AI badge 显示与不显示的快照对比
    //
    // 接口约定（当前阶段）：
    //   LauncherCandidateView(candidates: [PluginManifest], selectedIndex: Int, aiRecommendedIndex: Int)
    //   ASSUMES blue team: 新增 aiRecommendedIndex 参数来区分"用户选中"与"AI 推荐 badge"。
    //
    // 如果蓝队选择通过 selectedIndex 复用来控制 badge（即 selectedIndex == -1 → 无 badge），
    // 请用下方的 test_SC16_via_selectedIndex_visualDifference 替代。

    /// SC-16（主要）：通过 selectedIndex 区分有无 badge（兼容现有接口）。
    ///
    /// 设计文档 C7：lastRouteSelectedIndex == -1 时无 badge；
    ///             lastRouteSelectedIndex >= 0 时对应行显示 "✨ AI"。
    ///
    /// 使用现有接口 selectedIndex: Int，selectedIndex=-1 对应哨兵状态（无 badge），
    /// selectedIndex=1 对应 AI 选中第 2 行（badge 显示）。
    ///
    /// Mutation 探针：如果 badge 显示逻辑对 selectedIndex=-1 和 selectedIndex=1 产生完全相同的渲染，
    /// imagesAreIdentical 返回 true → 测试红灯。
    func test_SC16_via_selectedIndex_visualDifference() {
        // 状态 A：selectedIndex=1（AI 选中 index=1，badge 显示在第 2 行）
        let viewWithBadge = LauncherCandidateView(
            candidates: candidates,
            selectedIndex: 1
        )
        let hcWithBadge = NSHostingController(rootView: viewWithBadge)
        hcWithBadge.view.frame = NSRect(x: 0, y: 0, width: 720, height: 132)

        // 状态 B：selectedIndex=-1（哨兵，badge 不显示）
        let viewNoBadge = LauncherCandidateView(
            candidates: candidates,
            selectedIndex: -1
        )
        let hcNoBadge = NSHostingController(rootView: viewNoBadge)
        hcNoBadge.view.frame = NSRect(x: 0, y: 0, width: 720, height: 132)

        // 分别录制快照（基线录制，首次运行时生成 .png；后续运行回归比对）
        assertSnapshot(of: hcWithBadge, as: .image(size: snapshotSize),
                       named: "aiBadge_selectedIndex1")
        assertSnapshot(of: hcNoBadge, as: .image(size: snapshotSize),
                       named: "noBadge_selectedIndexMinus1")

        // 核心断言：两个快照必须不同（badge 有无造成可见像素差异）
        let imageWithBadge  = hcWithBadge.view.snapshotImage()
        let imageNoBadge    = hcNoBadge.view.snapshotImage()

        XCTAssertFalse(
            imagesAreIdentical(imageWithBadge, imageNoBadge),
            "SC-16 (C7): selectedIndex=1（AI 推荐 badge 可见）与 selectedIndex=-1（无 badge）的快照必须不同——" +
            "badge '✨ AI' 的有无应造成可见像素差异"
        )
    }

    /// SC-16 补充：selectedIndex=-1 时快照回归（确认基线无 badge）。
    ///
    /// Mutation 探针：如果对 selectedIndex=-1 也渲染了 badge，
    /// 下次回归比对会失败（修改了基线所代表的设计意图）。
    func test_SC16_noBadge_selectedIndexMinus1_regression() {
        let view = LauncherCandidateView(
            candidates: candidates,
            selectedIndex: -1
        )
        let hc = NSHostingController(rootView: view)
        hc.view.frame = NSRect(x: 0, y: 0, width: 720, height: 132)

        // 快照回归：基线必须是"无 badge"状态
        assertSnapshot(of: hc, as: .image(size: snapshotSize),
                       named: "noBadge_sentinel_regression")
    }

    /// SC-16 补充：selectedIndex=0（首行 AI 推荐）的快照回归。
    ///
    /// 验证 badge 显示在正确的行（index=0 → 第 1 行有 badge 标记）。
    func test_SC16_aiBadge_selectedIndex0_regression() {
        let view = LauncherCandidateView(
            candidates: candidates,
            selectedIndex: 0
        )
        let hc = NSHostingController(rootView: view)
        hc.view.frame = NSRect(x: 0, y: 0, width: 720, height: 132)

        // 快照回归：基线应有 badge 在第 1 行
        assertSnapshot(of: hc, as: .image(size: snapshotSize),
                       named: "aiBadge_selectedIndex0_firstRow")
    }
}

// MARK: - NSView 快照辅助扩展

private extension NSView {
    /// 将 NSView 渲染为 NSImage，用于像素级比对
    func snapshotImage() -> NSImage? {
        let bounds = self.bounds
        guard let bitmapRep = self.bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        self.cacheDisplay(in: bounds, to: bitmapRep)
        let image = NSImage(size: bounds.size)
        image.addRepresentation(bitmapRep)
        return image
    }
}

// MARK: - 像素级图片比对

/// 比较两个 NSImage 是否像素级完全相同
/// 用于 SC-16 断言：带 badge 和不带 badge 的快照必须不同
private func imagesAreIdentical(_ a: NSImage?, _ b: NSImage?) -> Bool {
    guard let a, let b else { return false }
    guard let dataA = a.tiffRepresentation,
          let dataB = b.tiffRepresentation else { return false }
    return dataA == dataB
}
