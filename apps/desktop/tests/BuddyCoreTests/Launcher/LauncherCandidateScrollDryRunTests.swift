import XCTest
import SwiftUI
@testable import BuddyCore

// MARK: - LauncherCandidateScrollDryRunTests
//
// 蓝队 B1 dry-run 验证（state.md 实现计划 §4 假设先验证）+ 滚动触发回归守护。
//
// ## B1 验证结论（已完成，记录如下）
//
// **假设**：onChange(of: selectedIndex) 在 `let selectedIndex`（纯值输入）上触发 scrollTo。
//
// **实测结论：onChange(of: let) 不触发（onChangeFireCount=0）**。
// 原因：SwiftUI .onChange(of:) 要求值变化在 view 实例生命周期内被 diff 系统观察；
// 普通 let 存储属性的「父视图传新值」不满足此条件（onChange 不 fire）。
//
// **采纳的 fallback**：改用 `.task(id: selectedIndex)` —— 它基于 value identity 可靠触发
// （onChangeFireCount 从 0 → 1+），selectedIndex 变化时 task 重启调 proxy.scrollTo。
// 先例：LauncherInputView.swift:276 onChange(of: manager.isVisible) 监听的是 @Published
// 源（非 let），故可靠；候选视图 selectedIndex 是 let 输入，故必须用 task(id:)。
//
// ## scrollTo 效果的 headless 盲区（B2 / patterns/2026-07-14）
//
// SwiftUI ScrollViewReader.scrollTo 的动画在测试环境（无完整 window server）不落地：
// 调用后 documentVisibleRect.origin.y 保持 0。这是已知 headless 限制（非 fallback 失败）。
// **真机滚动效果由 QA Tier 1.5 真机 E2E 验证**（SKIP_FETCH_PLUGINS=1 make bundle + 真机 ↓）。
// 本测试只守护「滚动触发机制可靠」（.task(id:) 被调用），不守护「动画落地」（headless 盲区）。

@MainActor
final class LauncherCandidateScrollDryRunTests: XCTestCase {

    /// B1 守护：selectedIndex 变化时 onChange(of: @Binding) 必须触发（LauncherScrollProbe.fireCount > 0）。
    /// 这是 fallback 可靠性的回归守护——若有人误改回 let（onChange 不触发），fireCount 不递增 → FAIL。
    func test_B1_onChange_binding_triggers_on_selection_change() {
        let candidates = (0..<12).map { i in
            makeManifest(name: "plugin\(i)", description: "desc \(i)")
        }
        LauncherScrollProbe.shared.reset()

        let selector = ScrollSelectorHolder(initial: 0)
        let container = ScrollDryRunContainer(candidates: candidates, selector: selector)
        let hosting = NSHostingView(rootView: container)
        hosting.frame = NSRect(x: 0, y: 0, width: 720, height: 400)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        hosting.layoutSubtreeIfNeeded()
        pumpRunLoop(seconds: 0.3)

        // selectedIndex 0 → 8 → onChange(of: @Binding) 触发 scrollTo
        selector.selectedIndex = 8
        hosting.layoutSubtreeIfNeeded()
        pumpRunLoop(seconds: 0.5)

        XCTAssertGreaterThanOrEqual(LauncherScrollProbe.shared.fireCount, 1,
                                    "B1: selectedIndex 0→8 后 onChange(of: @Binding) 必须触发（fireCount >= 1）。"
                                    + "若 fireCount==0 = 退化回 let（onChange 不触发），fallback 被破坏。")
        XCTAssertEqual(LauncherScrollProbe.shared.lastNew, 8,
                       "B1: 最后一次 onChange 的 selectedIndex 应 == 8")
    }

    /// B1 互补：selectedIndex = -1（非活动区）时 onChange guard 跳过 scrollTo（仍 fire 但 lastNew=-1）。
    func test_B1_negativeSelectedIndex_guarded() {
        let candidates = (0..<12).map { i in
            makeManifest(name: "plugin\(i)", description: "desc \(i)")
        }
        LauncherScrollProbe.shared.reset()

        let selector = ScrollSelectorHolder(initial: 0)
        let container = ScrollDryRunContainer(candidates: candidates, selector: selector)
        let hosting = NSHostingView(rootView: container)
        hosting.frame = NSRect(x: 0, y: 0, width: 720, height: 400)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        hosting.layoutSubtreeIfNeeded()
        pumpRunLoop(seconds: 0.3)

        // selectedIndex 0 → -1（非活动区）→ onChange 触发但 scrollTo guard（new < 0 不滚）
        selector.selectedIndex = -1
        hosting.layoutSubtreeIfNeeded()
        pumpRunLoop(seconds: 0.3)

        XCTAssertEqual(LauncherScrollProbe.shared.lastNew, -1,
                       "B1: selectedIndex=-1 时 onChange 应触发（recordFire 记 lastNew=-1），"
                       + "但 scrollTo 内部 guard new >= 0 跳过实际滚动")
    }

    // MARK: - Helpers

    private func makeManifest(name: String, description: String) -> PluginManifest {
        PluginManifest(name: name, version: "1.0.0", description: description,
                       keywords: [], cmd: "./run.sh", args: [], env: nil,
                       timeout: 5, requiredPath: nil)
    }

    private func pumpRunLoop(seconds: TimeInterval) {
        let limit = Date(timeIntervalSinceNow: seconds)
        RunLoop.current.run(until: limit)
    }
}

/// dry-run 测试用 ObservableObject 持有 selectedIndex，使 @Binding 可观察其变化。
private final class ScrollSelectorHolder: ObservableObject {
    @Published var selectedIndex: Int
    init(initial: Int) { selectedIndex = initial }
}

private struct ScrollDryRunContainer: View {
    let candidates: [PluginManifest]
    @ObservedObject var selector: ScrollSelectorHolder

    var body: some View {
        LauncherCandidateView(
            candidates: candidates,
            selectedIndex: Binding(
                get: { selector.selectedIndex },
                set: { selector.selectedIndex = $0 }
            )
        )
        .frame(width: 720)
    }
}
