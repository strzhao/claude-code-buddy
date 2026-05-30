import XCTest
import AppKit
@testable import BuddyCore

@MainActor
final class EditMenuTests: XCTestCase {

    // MARK: - 顶层菜单结构

    func test_makeEditMenu_returnsMenuWithEditSubmenu() {
        let menu = AppDelegate().makeEditMenu()
        XCTAssertEqual(menu.items.count, 1, "顶层菜单应只有一个 Edit item")
        let editItem = menu.items[0]
        XCTAssertEqual(editItem.title, "编辑")
        XCTAssertNotNil(editItem.submenu, "Edit item 必须有 submenu")
    }

    // MARK: - submenu 内容

    func test_editSubmenu_containsExpectedItemCount() {
        let menu = AppDelegate().makeEditMenu()
        let submenu = menu.items[0].submenu!
        // 撤销、重做、分隔符、剪切、拷贝、粘贴、全选 = 7 项
        XCTAssertEqual(submenu.items.count, 7)
    }

    // MARK: - 动作与 keyEquivalent

    func test_undoItem() {
        let item = editSubmenuItem(at: 0)
        XCTAssertEqual(item.title, "撤销")
        XCTAssertEqual(item.action, Selector(("undo:")))
        XCTAssertEqual(item.keyEquivalent, "z")
        XCTAssertEqual(item.keyEquivalentModifierMask, .command)
        XCTAssertNil(item.target, "target 必须为 nil，走 responder chain")
    }

    func test_redoItem() {
        let item = editSubmenuItem(at: 1)
        XCTAssertEqual(item.title, "重做")
        XCTAssertEqual(item.action, Selector(("redo:")))
        XCTAssertEqual(item.keyEquivalent, "Z")
        XCTAssertTrue(item.keyEquivalentModifierMask.contains(.command))
        XCTAssertTrue(item.keyEquivalentModifierMask.contains(.shift))
        XCTAssertNil(item.target)
    }

    func test_separatorAtIndex2() {
        let item = editSubmenuItem(at: 2)
        XCTAssertTrue(item.isSeparatorItem, "索引 2 应为分隔符")
    }

    func test_cutItem() {
        let item = editSubmenuItem(at: 3)
        XCTAssertEqual(item.title, "剪切")
        XCTAssertEqual(item.action, Selector(("cut:")))
        XCTAssertEqual(item.keyEquivalent, "x")
        XCTAssertEqual(item.keyEquivalentModifierMask, .command)
        XCTAssertNil(item.target)
    }

    func test_copyItem() {
        let item = editSubmenuItem(at: 4)
        XCTAssertEqual(item.title, "拷贝")
        XCTAssertEqual(item.action, Selector(("copy:")))
        XCTAssertEqual(item.keyEquivalent, "c")
        XCTAssertEqual(item.keyEquivalentModifierMask, .command)
        XCTAssertNil(item.target)
    }

    func test_pasteItem() {
        let item = editSubmenuItem(at: 5)
        XCTAssertEqual(item.title, "粘贴")
        XCTAssertEqual(item.action, Selector(("paste:")))
        XCTAssertEqual(item.keyEquivalent, "v")
        XCTAssertEqual(item.keyEquivalentModifierMask, .command)
        XCTAssertNil(item.target)
    }

    func test_selectAllItem() {
        let item = editSubmenuItem(at: 6)
        XCTAssertEqual(item.title, "全选")
        XCTAssertEqual(item.action, Selector(("selectAll:")))
        XCTAssertEqual(item.keyEquivalent, "a")
        XCTAssertEqual(item.keyEquivalentModifierMask, .command)
        XCTAssertNil(item.target)
    }

    // MARK: - 幂等性：多次调用返回独立实例

    func test_makeEditMenu_isIdempotent() {
        let delegate = AppDelegate()
        let menu1 = delegate.makeEditMenu()
        let menu2 = delegate.makeEditMenu()
        XCTAssertFalse(menu1 === menu2, "每次调用应返回新实例")
    }

    // MARK: - Helper

    private func editSubmenuItem(at index: Int) -> NSMenuItem {
        let menu = AppDelegate().makeEditMenu()
        let submenu = menu.items[0].submenu!
        return submenu.items[index]
    }
}
