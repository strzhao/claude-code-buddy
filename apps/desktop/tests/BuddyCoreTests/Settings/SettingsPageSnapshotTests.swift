import XCTest
import AppKit
import SnapshotTesting
@testable import BuddyCore

// MARK: - 红队验收测试：5 页面 light/dark 快照回归（SC-SET-09/14）
//
// 设计权威源（状态文件 `## 验证方案` Tier 1 + `## 验收场景` SC-SET-09/14）：
//
// 验证方案 Tier 1（det-machine）：`swift test --filter Snapshot`（5 页 × light/dark）。
//   为 General/About/Keyboard/Plugin **新增**快照测试，Skin 更新基线（Skin 已有 SkinCardSnapshotTests，不重复写）。
//
// SC-SET-09 [det-machine]：When `swift test --filter Snapshot`, 5 页 × light/dark 快照无回归。
//   assert: 全 snapshot 通过（Skin 更新基线 + General/About/Keyboard/Plugin 新增快照）。
//   artifact: 快照 png（≥10 张）
//
// SC-SET-14 [det-machine]：When UI 变更完成, 5 页快照基线重录提交。
//   assert: 5 VC light+dark baseline 均本次修改, 无残留旧基线。
//   （本测试首次运行会生成新基线；蓝队合流后需 `git add __Snapshots__` 提交。）
//
// 契约 C2（loadView 固定 frame）：各页 root view 保持固定 frame（General/About/Keyboard 580×480，Plugin 600×500）
//   + 默认 autoresize；root 不设 translatesAutoresizingMaskIntoConstraints=false。
//   快照尺寸用各页 loadView 的固定 frame，保证渲染完整布局。
//
// ⚠️ API 假设：
//   - GeneralSettingsViewController() / AboutSettingsViewController() / KeyboardShortcutsViewController()
//     / PluginGalleryViewController() 均无参构造（现有代码已确认，非蓝队新改动）。
//   - PluginGalleryViewController 需 marketplace/plugins 注入（参考 SettingsSidebarAcceptanceTests.SC13）；
//     若蓝队未暴露无参便利构造器，快照测试会用 mock 注入构造器（SnapshotMockMarketplace/PluginToggle）。
//     CONTRACT_AMBIGUITY: PluginGalleryViewController 的无参构造器是否存在未在设计中明列。
//     本测试先尝试无参构造，失败则回退 mock 注入。
//
// 外观设置：通过 `view.effectiveAppearance = NSAppearance(named:)` + `performAsCurrentDrawingAppearance`
//   在快照前切换 light/dark 上下文，确保 dynamic NSColor 正确 resolve。
//
// 红队原则：所有断言代表"设计意图应该满足"，不代表"实现实际做了什么"。
// 本测试首次运行 WILL FAIL（无基线）——需 `__Snapshots__` 生成后提交（SC-SET-14 基线重录）。

@MainActor
final class SettingsPageSnapshotTests: XCTestCase {

    // 契约 C2 各页固定 frame
    private let standardSize = CGSize(width: 580, height: 480)  // General/About/Keyboard
    private let pluginSize = CGSize(width: 600, height: 500)    // Plugin
    private var isCI: Bool { ProcessInfo.processInfo.environment["CI"] != nil }

    // MARK: - SC-SET-09 GeneralSettingsViewController × light/dark

    func test_generalSettings_light() throws {
        try XCTSkipIf(isCI, "Snapshot tests skipped on CI (font rendering differs)")
        let vc = GeneralSettingsViewController()
        let view = prepareView(vc, size: standardSize, appearanceName: .aqua)
        assertSnapshot(of: view, as: .image(size: standardSize), named: "light")
    }

    func test_generalSettings_dark() throws {
        try XCTSkipIf(isCI, "Snapshot tests skipped on CI (font rendering differs)")
        let vc = GeneralSettingsViewController()
        let view = prepareView(vc, size: standardSize, appearanceName: .darkAqua)
        assertSnapshot(of: view, as: .image(size: standardSize), named: "dark")
    }

    // MARK: - SC-SET-09 AboutSettingsViewController × light/dark

    func test_aboutSettings_light() throws {
        try XCTSkipIf(isCI, "Snapshot tests skipped on CI (font rendering differs)")
        let vc = AboutSettingsViewController()
        let view = prepareView(vc, size: standardSize, appearanceName: .aqua)
        assertSnapshot(of: view, as: .image(size: standardSize), named: "light")
    }

    func test_aboutSettings_dark() throws {
        try XCTSkipIf(isCI, "Snapshot tests skipped on CI (font rendering differs)")
        let vc = AboutSettingsViewController()
        let view = prepareView(vc, size: standardSize, appearanceName: .darkAqua)
        assertSnapshot(of: view, as: .image(size: standardSize), named: "dark")
    }

    // MARK: - SC-SET-09 KeyboardShortcutsViewController × light/dark

    func test_keyboardShortcuts_light() throws {
        try XCTSkipIf(isCI, "Snapshot tests skipped on CI (font rendering differs)")
        let vc = KeyboardShortcutsViewController()
        let view = prepareView(vc, size: standardSize, appearanceName: .aqua)
        assertSnapshot(of: view, as: .image(size: standardSize), named: "light")
    }

    func test_keyboardShortcuts_dark() throws {
        try XCTSkipIf(isCI, "Snapshot tests skipped on CI (font rendering differs)")
        let vc = KeyboardShortcutsViewController()
        let view = prepareView(vc, size: standardSize, appearanceName: .darkAqua)
        assertSnapshot(of: view, as: .image(size: standardSize), named: "dark")
    }

    // MARK: - SC-SET-09 PluginGalleryViewController × light/dark
    //
    // CONTRACT_AMBIGUITY: PluginGalleryViewController 构造器签名。
    //   现有代码（SettingsSidebarAcceptanceTests.SC13）显示有 init(marketplace:plugins:) 注入构造器。
    //   本测试尝试两种路径：① 无参构造 ② mock 注入。先尝试无参，失败用 mock。

    func test_pluginGallery_light() throws {
        try XCTSkipIf(isCI, "Snapshot tests skipped on CI (font rendering differs)")
        let vc = makePluginGalleryVC()
        let view = prepareView(vc, size: pluginSize, appearanceName: .aqua)
        assertSnapshot(of: view, as: .image(size: pluginSize), named: "light")
    }

    func test_pluginGallery_dark() throws {
        try XCTSkipIf(isCI, "Snapshot tests skipped on CI (font rendering differs)")
        let vc = makePluginGalleryVC()
        let view = prepareView(vc, size: pluginSize, appearanceName: .darkAqua)
        assertSnapshot(of: view, as: .image(size: pluginSize), named: "dark")
    }

    // MARK: - 辅助方法

    /// 实例化 VC + force loadView + 设置 appearance + layout，返回 ready-to-snapshot view。
    /// light/dark 双主题：设 vc.view.appearance + 切 current drawing appearance 让 dynamic NSColor resolve。
    private func prepareView(
        _ vc: NSViewController,
        size: CGSize,
        appearanceName: NSAppearance.Name
    ) -> NSView {
        let appearance = NSAppearance(named: appearanceName) ?? NSAppearance(named: .aqua)!
        // force loadView（各页 loadView 设固定 frame，契约 C2）
        _ = vc.view

        // 1. 设视图 appearance（让 AppKit 在渲染时用该 appearance 求值 dynamic NSColor）
        vc.view.appearance = appearance
        // 2. 切 current drawing appearance（让 layout 期间 resolve 用正确上下文）
        appearance.performAsCurrentDrawingAppearance {
            vc.view.layoutSubtreeIfNeeded()
        }
        vc.view.layoutSubtreeIfNeeded()

        return vc.view
    }

    /// 构造 PluginGalleryViewController：用无参构造器（init(marketplace:plugins:) 有默认参数
    /// marketplace=MarketplaceManager.shared, plugins=PluginManager.shared）。
    /// 用注入构造器可避免单例真实网络/磁盘 IO（与 SettingsSidebarAcceptanceTests.SC13 同款 mock）。
    private func makePluginGalleryVC() -> NSViewController {
        let plugins = SnapshotMockPluginToggle()
        let market = SnapshotMockMarketplace()
        return PluginGalleryViewController(marketplace: market, plugins: plugins)
    }
}

// MARK: - SC-SET-09 独立 Mock（红队不复用蓝队/其他测试的 mock）

private final class SnapshotMockMarketplace: MarketplaceInspecting {
    var inspection: MarketplaceInspection

    init(inspection: MarketplaceInspection = .init(
        plugins: [], sideloadedPlugins: [], lastSyncedAt: nil, consecutiveSyncFailures: 0
    )) {
        self.inspection = inspection
    }

    func inspect() throws -> MarketplaceInspection { inspection }
    func reseed() async throws {}
}

private final class SnapshotMockPluginToggle: PluginToggling {
    func disable(name: String) throws {}
    func enable(name: String) throws {}
}
