import XCTest
import SwiftUI
import SnapshotTesting
@testable import BuddyCore

// MARK: - LauncherCardSnapshotTests
//
// 蓝队快照基线：LauncherCardView（W3 通用卡片通道 UI，mockup 方案 B）。
// 新增 UI 组件 → 同步新增快照测试（工程规约）。纯静态渲染，无逐帧动画，
// 不涉测试冻结铁律。基线录制：SNAPSHOT_TESTING_RECORD=1 swift test --filter LauncherCardSnapshot。
// CI 上跳过（字体渲染差异，与既有快照测试同约定）。

final class LauncherCardSnapshotTests: XCTestCase {

    private var isCI: Bool { ProcessInfo.processInfo.environment["CI"] != nil }

    private var fixtureCard: PluginCard {
        PluginCard(
            title: "gcli 套餐限额 · 3 个",
            entries: [
                CardEntry(
                    name: "kimi",
                    level: "ok",
                    badge: "使用中",
                    windows: [
                        CardWindow(label: "5h", percent: 12, reset: "3h20m"),
                        CardWindow(label: "周窗", percent: 45, reset: "2d4h"),
                    ]
                ),
                CardEntry(
                    name: "glm-4.6",
                    level: "warn",
                    badge: nil,
                    windows: [
                        CardWindow(label: "5h", percent: 62, reset: "1h05m"),
                        CardWindow(label: "周窗", percent: 81, reset: "5d12h"),
                    ]
                ),
                CardEntry(
                    name: "glm flash lastest（等 2 个条目）",
                    level: "danger",
                    badge: nil,
                    windows: [
                        CardWindow(label: "5h", percent: 91, reset: "40m"),
                        CardWindow(label: "周窗", percent: 88, reset: "5d"),
                    ]
                ),
            ]
        )
    }

    func test_quotaCard_threeLevels() throws {
        try XCTSkipIf(isCI, "Snapshot tests skipped on CI (font rendering differs)")
        let view = LauncherCardView(card: fixtureCard)
            .frame(width: 480, alignment: .leading)
            .padding(16)
        let host = NSHostingView(rootView: view)
        assertSnapshot(
            of: host,
            as: .image(size: CGSize(width: 512, height: LauncherInputView.cardHeight(fixtureCard) + 32))
        )
    }

    func test_quotaCard_singleEntryWithBadge() throws {
        try XCTSkipIf(isCI, "Snapshot tests skipped on CI (font rendering differs)")
        let card = PluginCard(
            title: "gcli 套餐限额 · 1 个",
            entries: [
                CardEntry(
                    name: "kimi",
                    level: "ok",
                    badge: "使用中",
                    windows: [CardWindow(label: "5h", percent: 7, reset: nil)]
                )
            ]
        )
        let view = LauncherCardView(card: card)
            .frame(width: 480, alignment: .leading)
            .padding(16)
        let host = NSHostingView(rootView: view)
        assertSnapshot(
            of: host,
            as: .image(size: CGSize(width: 512, height: LauncherInputView.cardHeight(card) + 32))
        )
    }
}
