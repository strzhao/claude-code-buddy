import AppKit

// MARK: - Edit Menu

extension AppDelegate {

    /// 构造标准 Edit 菜单，供 LSUIElement 无 MainMenu.nib 的 App 使用。
    /// 纯函数语义：不读写 NSApp 任何全局状态，多次调用返回独立实例。
    func makeEditMenu() -> NSMenu {
        let mainMenu = NSMenu(title: "")

        let editItem = NSMenuItem(title: "编辑", action: nil, keyEquivalent: "")
        let editSubmenu = NSMenu(title: "编辑")

        let undoItem = NSMenuItem(title: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        undoItem.keyEquivalentModifierMask = .command
        undoItem.target = nil

        let redoItem = NSMenuItem(title: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        redoItem.target = nil

        let cutItem = NSMenuItem(title: "剪切", action: Selector(("cut:")), keyEquivalent: "x")
        cutItem.keyEquivalentModifierMask = .command
        cutItem.target = nil

        let copyItem = NSMenuItem(title: "拷贝", action: Selector(("copy:")), keyEquivalent: "c")
        copyItem.keyEquivalentModifierMask = .command
        copyItem.target = nil

        let pasteItem = NSMenuItem(title: "粘贴", action: Selector(("paste:")), keyEquivalent: "v")
        pasteItem.keyEquivalentModifierMask = .command
        pasteItem.target = nil

        let selectAllItem = NSMenuItem(title: "全选", action: Selector(("selectAll:")), keyEquivalent: "a")
        selectAllItem.keyEquivalentModifierMask = .command
        selectAllItem.target = nil

        editSubmenu.addItem(undoItem)
        editSubmenu.addItem(redoItem)
        editSubmenu.addItem(NSMenuItem.separator())
        editSubmenu.addItem(cutItem)
        editSubmenu.addItem(copyItem)
        editSubmenu.addItem(pasteItem)
        editSubmenu.addItem(selectAllItem)

        editItem.submenu = editSubmenu
        mainMenu.addItem(editItem)

        return mainMenu
    }
}
