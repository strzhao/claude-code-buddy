import XCTest
import AppKit
import SwiftUI
@testable import BuddyCore

// MARK: - LauncherWindowAppearanceAcceptanceTests
//
// 红队验收测试：C5 面板外观契约
//
// 覆盖契约：
//   C5-A: panel.backgroundColor == NSColor.clear
//   C5-B: panel.isOpaque == false
//   C5-C: panel.hasShadow == false（关闭系统阴影，硬阴影由 SwiftUI 层统一管）
//   C5-D: panel.styleMask 含 .nonactivatingPanel（行为契约保留）
//   C5-E: LauncherWindow 是 NSPanel 的子类
//   C5-F: panel.level == .floating
//
// 初始化方法：直接 LauncherWindow() 实例化（不通过 LauncherManager，避免 setup 副作用）
// 参照 LauncherHotkeyAcceptanceTests M-Q 节的模式。
//
// 测试 WILL NOT compile 直到蓝队合并实现 — 这是预期的 TDD 红灯。

@MainActor
final class LauncherWindowAppearanceAcceptanceTests: XCTestCase {

    private var window: LauncherWindow!

    override func setUp() async throws {
        try await super.setUp()
        window = LauncherWindow()
    }

    override func tearDown() async throws {
        window?.close()
        window = nil
        try await super.tearDown()
    }

    // MARK: - C5-E: LauncherWindow 必须是 NSPanel 子类

    /// LauncherWindow 必须继承自 NSPanel（浮动面板，非 NSWindow）
    func test_C5E_launcherWindow_isNSPanel() {
        XCTAssertTrue(
            window is NSPanel,
            "LauncherWindow 必须是 NSPanel 的子类（当前: \(type(of: window))）"
        )
    }

    // MARK: - C5-A: panel.backgroundColor == NSColor.clear

    /// backgroundColor 必须 == .clear（系统阴影关闭后自定义 SwiftUI 硬阴影才正确渲染）
    func test_C5A_panel_backgroundColor_isClear() {
        XCTAssertEqual(
            window.backgroundColor,
            NSColor.clear,
            "LauncherWindow.backgroundColor 必须 == NSColor.clear（消除系统背景渲染）"
        )
    }

    // MARK: - C5-B: panel.isOpaque == false

    /// isOpaque 必须 == false（配合 .clear 背景实现透明度）
    func test_C5B_panel_isOpaque_isFalse() {
        XCTAssertFalse(
            window.isOpaque,
            "LauncherWindow.isOpaque 必须 == false（透明面板，配合 clear backgroundColor）"
        )
    }

    // MARK: - C5-C: panel.hasShadow == true（迁移自 task 008 旧契约，task 010 UI 升级改为系统阴影）

    /// hasShadow 必须 == true（task 010 UI 升级：硬阴影 → 系统阴影，配合 NSVisualEffectView 毛玻璃）
    func test_C5C_panel_hasShadow_isTrue() {
        XCTAssertTrue(
            window.hasShadow,
            "LauncherWindow.hasShadow 必须 == true（task 010 起改为系统阴影，替代旧的 SwiftUI 硬阴影 shadow(radius:0,x:4,y:4)）"
        )
    }

    // MARK: - C5-D: panel.styleMask 含 .nonactivatingPanel

    /// styleMask 必须保留 .nonactivatingPanel（召唤时不抢夺 focus，行为契约）
    func test_C5D_panel_styleMask_containsNonactivatingPanel() {
        XCTAssertTrue(
            window.styleMask.contains(.nonactivatingPanel),
            "LauncherWindow.styleMask 必须含 .nonactivatingPanel（召唤时不抢占 key window，行为契约保留）"
        )
    }

    // MARK: - C5-F: panel.level == .floating

    /// panel level 必须 == .floating（保持在普通窗口上方）
    func test_C5F_panel_level_isFloating() {
        XCTAssertEqual(
            window.level,
            .floating,
            "LauncherWindow.level 必须 == .floating（悬浮在普通窗口上方）"
        )
    }

    // MARK: - C5: canBecomeKey == true（键盘输入能进入面板）

    /// canBecomeKey 必须 == true（允许输入框接受键盘事件）
    func test_C5_panel_canBecomeKey_isTrue() {
        XCTAssertTrue(
            window.canBecomeKey,
            "LauncherWindow.canBecomeKey 必须 == true（输入框需要 key window 状态接受键盘输入）"
        )
    }

    // MARK: - C5: titlebarAppearsTransparent == true

    /// titlebar 透明（无标题栏视觉遮挡）
    func test_C5_panel_titlebarAppearsTransparent_isTrue() {
        XCTAssertTrue(
            window.titlebarAppearsTransparent,
            "LauncherWindow.titlebarAppearsTransparent 必须 == true（无标题栏外观）"
        )
    }

    // MARK: - C5: frame.width == LauncherConstants.windowWidth (720)

    /// 初始 frame.width 必须等于新的 windowWidth == 720
    func test_C5_panel_initialFrameWidth_is720() {
        XCTAssertEqual(
            window.frame.size.width,
            LauncherConstants.windowWidth,
            accuracy: 2.0,
            "LauncherWindow 初始 frame.width 必须 == LauncherConstants.windowWidth(\(LauncherConstants.windowWidth))"
        )
    }

    // MARK: - C5: collectionBehavior 含 .canJoinAllSpaces

    /// collectionBehavior 含 .canJoinAllSpaces（在所有 Spaces 均可见）
    func test_C5_panel_collectionBehavior_containsCanJoinAllSpaces() {
        XCTAssertTrue(
            window.collectionBehavior.contains(.canJoinAllSpaces),
            "LauncherWindow.collectionBehavior 必须含 .canJoinAllSpaces（跨 Spaces 可见）"
        )
    }
}
