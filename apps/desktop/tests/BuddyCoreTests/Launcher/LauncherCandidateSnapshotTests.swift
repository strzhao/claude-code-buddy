import XCTest
import SwiftUI
import SnapshotTesting
@testable import BuddyCore

// MARK: - LauncherCandidateSnapshotTests
//
// 红队验收测试：C3 selectionIndicator 视觉契约（快照）
//
// 覆盖契约：
//   C3: LauncherCandidateView 渲染选中行时，左侧必须存在 width=3 的 sage Capsule。
//       未选中行不应有该指示条。
//
// 测试策略：
//   构造 LauncherCandidateView(candidates: [mockManifest1, mockManifest2], selectedIndex: 0)，
//   用 assertSnapshot(of: view, as: .image(size:)) 与基线比对。
//   基线由本测试首次运行时自动录制，之后提交到 __Snapshots__/。
//
// 注意：C3 的视觉断言依赖快照基线，首次运行会录制基线（绿灯），
//       后续运行与基线比对（若 sage Capsule 消失则红灯）。
//
// 测试 WILL NOT compile 直到蓝队合并实现 — 这是预期的 TDD 红灯。

@MainActor
final class LauncherCandidateSnapshotTests: XCTestCase {

    override func setUpWithError() throws {
        // CI 字体/SF Symbol 渲染与本地不同，快照必失配；与 SkinGallerySnapshotTests 一致在 CI 跳过，本地仍跑。
        try XCTSkipIf(ProcessInfo.processInfo.environment["CI"] != nil,
                      "Snapshot tests skipped on CI (font rendering differs)")
    }

    // MARK: - Mock 构造辅助

    private func makeManifest(name: String, description: String) -> PluginManifest {
        PluginManifest(
            name: name,
            version: "1.0.0",
            description: description,
            keywords: [name.lowercased()],
            cmd: "./run.sh",
            args: [],
            env: nil,
            timeout: 5,
            requiredPath: nil
        )
    }

    // MARK: - C3: 选中行左侧有 sage Capsule 指示条（快照）

    /// C3：selectedIndex=0 时，第一行左侧有 width=3 sage Capsule 选中指示条
    ///
    /// 快照策略：
    ///   - 首次运行：录制基线到 __Snapshots__/LauncherCandidateSnapshotTests/
    ///   - 后续：与基线比对，若 sage Capsule 消失或位移则失败
    ///
    /// 设计意图契约（不是实现细节）：
    ///   视觉上，选中行左侧必须有一个明显的竖向指示条，颜色为 sage（LauncherTheme.primary 或相近绿色），
    ///   宽约 3pt，以胶囊（圆头）形式呈现，且仅选中行拥有。
    func test_C3_selectedRow_hasSageIndicatorBar() {
        let candidates = [
            makeManifest(name: "translate", description: "翻译文字内容"),
            makeManifest(name: "search",    description: "搜索互联网内容")
        ]
        // selectedIndex=0：第一行选中
        let view = LauncherCandidateView(candidates: candidates, selectedIndex: 0)
        let hostingController = NSHostingController(rootView: view)
        // 两行 × 44pt 行高
        hostingController.view.frame = NSRect(x: 0, y: 0, width: 720, height: 88)

        assertSnapshot(
            of: hostingController,
            as: .image(size: CGSize(width: 720, height: 88)),
            named: "C3_selectedRow0_sageIndicator"
        )
    }

    /// C3 对比：selectedIndex=1 时，第一行不应有选中指示条（确认快照视觉差异）
    ///
    /// 设计意图：指示条仅跟随"当前选中行"，非选中行无指示条。
    func test_C3_unselectedRow_noIndicatorBar() {
        let candidates = [
            makeManifest(name: "translate", description: "翻译文字内容"),
            makeManifest(name: "search",    description: "搜索互联网内容")
        ]
        // selectedIndex=1：第二行选中，第一行没有指示条
        let view = LauncherCandidateView(candidates: candidates, selectedIndex: 1)
        let hostingController = NSHostingController(rootView: view)
        hostingController.view.frame = NSRect(x: 0, y: 0, width: 720, height: 88)

        assertSnapshot(
            of: hostingController,
            as: .image(size: CGSize(width: 720, height: 88)),
            named: "C3_unselectedRow0_noIndicator"
        )
    }

    // MARK: - C3 补充：两快照必须像素不同（mutation 探针）

    /// mutation 探针：selected=0 与 selected=1 的快照必须不同。
    ///
    /// 若两者像素完全相同，说明选中指示条完全未渲染，或两行视觉无差异，
    /// 违反 C3 契约（"选中行必须有可见指示条"）。
    func test_C3_selectedVsUnselected_pixelsDiffer() {
        let candidates = [
            makeManifest(name: "translate", description: "翻译文字内容"),
            makeManifest(name: "search",    description: "搜索互联网内容")
        ]

        // selectedIndex=0：有指示条
        let viewSelected = LauncherCandidateView(candidates: candidates, selectedIndex: 0)
        let hcSelected = NSHostingController(rootView: viewSelected)
        hcSelected.view.frame = NSRect(x: 0, y: 0, width: 720, height: 88)

        // selectedIndex=1：无指示条在第一行
        let viewUnselected = LauncherCandidateView(candidates: candidates, selectedIndex: 1)
        let hcUnselected = NSHostingController(rootView: viewUnselected)
        hcUnselected.view.frame = NSRect(x: 0, y: 0, width: 720, height: 88)

        // 触发渲染
        let _ = hcSelected.view
        let _ = hcUnselected.view

        let imageSelected   = hcSelected.view.snapshotNSImage()
        let imageUnselected = hcUnselected.view.snapshotNSImage()

        XCTAssertFalse(
            nsiImagesAreIdentical(imageSelected, imageUnselected),
            """
            C3 mutation 探针：selectedIndex=0 与 selectedIndex=1 的快照像素完全相同。
            这意味着选中指示条（sage Capsule width=3）未渲染，或行间视觉无差异。
            违反 C3 契约：选中行左侧必须有可见 sage 指示条，未选中行不应有。
            """
        )
    }
}

// MARK: - NSView 快照辅助

private extension NSView {
    func snapshotNSImage() -> NSImage? {
        let bounds = self.bounds
        guard let bitmapRep = self.bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        self.cacheDisplay(in: bounds, to: bitmapRep)
        let image = NSImage(size: bounds.size)
        image.addRepresentation(bitmapRep)
        return image
    }
}

/// 比较两个 NSImage 是否像素级完全相同
private func nsiImagesAreIdentical(_ a: NSImage?, _ b: NSImage?) -> Bool {
    guard let a, let b else { return false }
    guard let dataA = a.tiffRepresentation,
          let dataB = b.tiffRepresentation else { return false }
    return dataA == dataB
}
