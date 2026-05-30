import XCTest
import AppKit
@testable import BuddyCore

// MARK: - EditMenuAcceptanceTests
//
// 红队验收测试：Edit 菜单装配契约（修复 launcher 输入框无法 Cmd+V 粘贴）
//
// 背景：本 app（LSUIElement + .accessory + SPM 无 nib）NSApp.mainMenu 始终为 nil，
//        导致 Cmd+V/Cmd+C/Cmd+X/Cmd+A 无法路由到 SwiftUI TextField 的 AppKit field editor。
//        修复方案：AppDelegate 提供纯函数 makeEditMenu() -> NSMenu 构造菜单树，
//        由 setupEditMenu() 赋给 NSApp.mainMenu（只在 app 启动时调用一次）。
//
// 调用方式：@testable import BuddyCore + AppDelegate() 实例化后调用实例方法
//
// 覆盖契约：
//   C1: makeEditMenu() 返回顶层菜单，含有 submenu 的 item，该 submenu 含 action == paste: 的菜单项
//   C2: Edit submenu 中的粘贴项满足 keyEquivalent=="v", modifierMask==[.command], target==nil
//   C3: submenu 同时含 cut:/copy:/paste:/selectAll: 四个动作，keyEquivalent 分别为 x/c/v/a，target 均为 nil
//   C4: 调用 makeEditMenu() 本身不修改 NSApp.mainMenu（赋值只在 setupEditMenu() 发生）
//
// 测试 WILL NOT compile 直到蓝队合并实现 — 这是预期的 TDD 红灯。

@MainActor
final class EditMenuAcceptanceTests: XCTestCase {

    // MARK: - 测试生命周期

    private var delegate: AppDelegate!

    override func setUp() async throws {
        try await super.setUp()
        delegate = AppDelegate()
    }

    override func tearDown() async throws {
        delegate = nil
        try await super.tearDown()
    }

    // MARK: - 辅助：从顶层菜单取出 Edit submenu

    /// 从 makeEditMenu() 的返回值中找到第一个有 submenu 的 item，返回该 submenu。
    private func editSubmenu(from topMenu: NSMenu) -> NSMenu? {
        for menuItem in topMenu.items {
            if let sub = menuItem.submenu, sub.numberOfItems > 0 {
                return sub
            }
        }
        return nil
    }

    /// 在给定菜单中找到第一个 action 匹配的 NSMenuItem。
    private func item(withAction action: Selector, in menu: NSMenu) -> NSMenuItem? {
        menu.items.first { $0.action == action }
    }

    // MARK: - C1: makeEditMenu() 返回含 submenu 的菜单树，且 submenu 含 paste: 项

    /// C1-A: 顶层菜单 items 不为空，至少有一个 item 含 submenu
    func test_C1A_topMenuHasItemWithSubmenu() {
        let topMenu = delegate.makeEditMenu()
        let hasSubmenu = topMenu.items.contains { $0.submenu != nil }
        XCTAssertTrue(
            hasSubmenu,
            """
            C1 违反：makeEditMenu() 返回的顶层菜单没有任何含 submenu 的 item。
            设计意图：topMenu[0] 应是 "Edit" item，其 submenu 包含四条标准编辑动作。
            """
        )
    }

    /// C1-B: Edit submenu 中存在 action == paste: 的菜单项
    func test_C1B_editSubmenuContainsPasteAction() {
        let topMenu = delegate.makeEditMenu()
        guard let sub = editSubmenu(from: topMenu) else {
            XCTFail("C1 违反：makeEditMenu() 顶层菜单中未找到含 submenu 的 item，无法验证 paste: 项")
            return
        }
        let pasteItem = item(withAction: #selector(NSText.paste(_:)), in: sub)
        XCTAssertNotNil(
            pasteItem,
            """
            C1 违反：Edit submenu 中未找到 action == paste: 的菜单项。
            设计意图：submenu 必须含 NSMenuItem，其 action 为 #selector(NSText.paste(_:))，
            使 Cmd+V 能路由到 SwiftUI TextField 的 AppKit field editor。
            """
        )
    }

    // MARK: - C2: 粘贴项的完整契约（keyEquivalent / modifierMask / target）

    /// C2-A: 粘贴项 keyEquivalent 必须 == "v"
    func test_C2A_pasteItem_keyEquivalent_isV() {
        let topMenu = delegate.makeEditMenu()
        guard let sub = editSubmenu(from: topMenu),
              let pasteItem = item(withAction: #selector(NSText.paste(_:)), in: sub) else {
            XCTFail("C2 前置条件失败：未找到 Edit submenu 或 paste: 项（见 C1 失败原因）")
            return
        }
        XCTAssertEqual(
            pasteItem.keyEquivalent,
            "v",
            """
            C2 违反：paste: 菜单项 keyEquivalent 应 == "v"，实际 == "\(pasteItem.keyEquivalent)"。
            设计意图：Cmd+V 触发粘贴，keyEquivalent 必须为小写 "v"。
            """
        )
    }

    /// C2-B: 粘贴项 keyEquivalentModifierMask 必须包含且仅包含 .command
    func test_C2B_pasteItem_modifierMask_isCommandOnly() {
        let topMenu = delegate.makeEditMenu()
        guard let sub = editSubmenu(from: topMenu),
              let pasteItem = item(withAction: #selector(NSText.paste(_:)), in: sub) else {
            XCTFail("C2 前置条件失败：未找到 Edit submenu 或 paste: 项")
            return
        }
        XCTAssertEqual(
            pasteItem.keyEquivalentModifierMask,
            NSEvent.ModifierFlags.command,
            """
            C2 违反：paste: 项 modifierMask 应 == [.command]，实际 == \(pasteItem.keyEquivalentModifierMask)。
            设计意图：仅 Cmd+V，不加 shift/option/control。
            """
        )
    }

    /// C2-C: 粘贴项 target 必须 == nil（响应链路由，不硬绑到特定对象）
    func test_C2C_pasteItem_target_isNil() {
        let topMenu = delegate.makeEditMenu()
        guard let sub = editSubmenu(from: topMenu),
              let pasteItem = item(withAction: #selector(NSText.paste(_:)), in: sub) else {
            XCTFail("C2 前置条件失败：未找到 Edit submenu 或 paste: 项")
            return
        }
        XCTAssertNil(
            pasteItem.target,
            """
            C2 违反：paste: 项 target 应 == nil（走响应链），实际 == \(String(describing: pasteItem.target))。
            设计意图：target=nil 使 AppKit 沿第一响应者链路由，SwiftUI TextField 的 field editor 会响应。
            """
        )
    }

    // MARK: - C3: 四个标准动作齐全（cut / copy / paste / selectAll）

    private static let standardActions: [(action: Selector, keyEquivalent: String, description: String)] = [
        (#selector(NSText.cut(_:)),       "x", "cut:"),
        (#selector(NSText.copy(_:)),      "c", "copy:"),
        (#selector(NSText.paste(_:)),     "v", "paste:"),
        (#selector(NSText.selectAll(_:)), "a", "selectAll:"),
    ]

    /// C3-A: submenu 中 cut:/copy:/paste:/selectAll: 四个动作全部存在
    func test_C3A_allFourStandardActionsPresent() {
        let topMenu = delegate.makeEditMenu()
        guard let sub = editSubmenu(from: topMenu) else {
            XCTFail("C3 前置条件失败：未找到 Edit submenu")
            return
        }
        for entry in Self.standardActions {
            let found = item(withAction: entry.action, in: sub)
            XCTAssertNotNil(
                found,
                """
                C3 违反：Edit submenu 缺少 \(entry.description) 动作。
                设计意图：四个标准编辑动作（cut/copy/paste/selectAll）必须全部存在，
                确保 Cmd+X/C/V/A 都能路由到 SwiftUI TextField field editor。
                """
            )
        }
    }

    /// C3-B: 四个动作的 keyEquivalent 分别为 x/c/v/a
    func test_C3B_allFourActions_correctKeyEquivalents() {
        let topMenu = delegate.makeEditMenu()
        guard let sub = editSubmenu(from: topMenu) else {
            XCTFail("C3 前置条件失败：未找到 Edit submenu")
            return
        }
        for entry in Self.standardActions {
            guard let menuItem = item(withAction: entry.action, in: sub) else {
                XCTFail("C3 前置条件失败：未找到 \(entry.description) 项，无法校验 keyEquivalent")
                continue
            }
            XCTAssertEqual(
                menuItem.keyEquivalent,
                entry.keyEquivalent,
                """
                C3 违反：\(entry.description) 的 keyEquivalent 应 == "\(entry.keyEquivalent)"，
                实际 == "\(menuItem.keyEquivalent)"。
                """
            )
        }
    }

    /// C3-C: 四个动作的 target 均为 nil
    func test_C3C_allFourActions_targetIsNil() {
        let topMenu = delegate.makeEditMenu()
        guard let sub = editSubmenu(from: topMenu) else {
            XCTFail("C3 前置条件失败：未找到 Edit submenu")
            return
        }
        for entry in Self.standardActions {
            guard let menuItem = item(withAction: entry.action, in: sub) else {
                // 由 C3-A 捕获缺失，这里跳过避免重复失败
                continue
            }
            XCTAssertNil(
                menuItem.target,
                """
                C3 违反：\(entry.description) 的 target 应 == nil（走响应链），
                实际 == \(String(describing: menuItem.target))。
                """
            )
        }
    }

    // MARK: - C4: makeEditMenu() 是纯函数，不修改 NSApp.mainMenu

    /// C4: 调用 makeEditMenu() 前后 NSApp.mainMenu 指针不变（赋值只在 setupEditMenu() 发生）
    func test_C4_makeEditMenu_doesNotSideEffectNSAppMainMenu() {
        // 记录调用前的 NSApp.mainMenu 指针（可能是 nil 或已有值）
        let mainMenuBefore = NSApp.mainMenu

        // 多次调用 makeEditMenu()，确认副作用不累积
        _ = delegate.makeEditMenu()
        _ = delegate.makeEditMenu()
        _ = delegate.makeEditMenu()

        let mainMenuAfter = NSApp.mainMenu

        // 使用 === 比较对象身份：调用 makeEditMenu() 不应改变 NSApp.mainMenu
        XCTAssertTrue(
            mainMenuBefore === mainMenuAfter,
            """
            C4 违反：调用 makeEditMenu() 后 NSApp.mainMenu 被修改。
            调用前：\(String(describing: mainMenuBefore))
            调用后：\(String(describing: mainMenuAfter))
            设计意图：makeEditMenu() 是纯函数，只构造并返回 NSMenu 对象，不触碰 NSApp.mainMenu。
            赋值操作应只在 setupEditMenu() 中发生（在 app 启动时调用一次）。
            """
        )
    }

    // MARK: - C4 补充：多次调用 makeEditMenu() 返回结构等价的独立实例

    /// C4 补充：每次调用 makeEditMenu() 应返回新的 NSMenu 实例（无共享可变状态）
    func test_C4_makeEditMenu_returnsIndependentInstances() {
        let menu1 = delegate.makeEditMenu()
        let menu2 = delegate.makeEditMenu()

        // 两次调用应返回不同对象（无单例缓存引发共享状态问题）
        XCTAssertFalse(
            menu1 === menu2,
            """
            C4 补充：makeEditMenu() 应每次返回全新的 NSMenu 实例。
            实际两次调用返回了同一个对象（menu1 === menu2），
            这可能导致共享可变状态问题（被修改后影响全局）。
            """
        )

        // 但结构上应等价：submenu 中都含四个标准动作
        for entry in Self.standardActions {
            let sub1 = editSubmenu(from: menu1)
            let sub2 = editSubmenu(from: menu2)
            let hasAction1 = sub1.flatMap { item(withAction: entry.action, in: $0) } != nil
            let hasAction2 = sub2.flatMap { item(withAction: entry.action, in: $0) } != nil
            XCTAssertEqual(
                hasAction1, hasAction2,
                "C4 补充：两次调用 makeEditMenu() 返回的 submenu 结构应一致（\(entry.description)）"
            )
        }
    }
}
