---
id: "008-menu-dashboard"
depends_on: ["002-session-manager"]
---

## 目标

用 NSPopover 替代当前的 NSMenu 菜单栏，显示所有活跃会话的详细信息并支持点击跳转。

## 架构上下文

当前 AppDelegate.setupMenuBar() 创建一个简单的 NSMenu，只显示 "Active Sessions: N"。需要替换为 NSPopover，包含自定义会话行视图。

## 关键实现细节

### SessionPopoverController (`Sources/ClaudeCodeBuddy/MenuBar/SessionPopoverController.swift`)

NSViewController，管理 NSPopover 内容：

```swift
class SessionPopoverController: NSViewController {
    private var sessions: [SessionInfo] = []
    private let stackView = NSStackView()
    var onSessionClicked: ((SessionInfo) -> Void)?
    
    func updateSessions(_ sessions: [SessionInfo])
}
```

**布局：**
- Header: "Claude Code Buddy" + 会话数
- 会话列表：每行一个 SessionRowView
- 空闲会话 opacity 0.7
- Footer: "点击 session 跳转终端" + Quit 按钮

### SessionRowView (`Sources/ClaudeCodeBuddy/MenuBar/SessionRowView.swift`)

自定义 NSView，单行会话显示：
- 左侧：颜色圆点（SessionColor.nsColor）
- 标签名（粗体）
- 状态徽章
- cwd 路径（灰色，等宽）
- 最后活动时间
- 可点击 → 触发 TerminalAdapter.activateTab

### AppDelegate 变更

**替换 setupMenuBar()：**
```swift
func setupMenuBar() {
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    if let button = statusItem?.button {
        button.image = NSImage(systemSymbolName: "cat.fill", ...)
        button.action = #selector(togglePopover)
        button.target = self
    }
    // 不再设置 statusItem?.menu
}
```

**Popover 管理：**
```swift
private let popover = NSPopover()
private lazy var popoverController = SessionPopoverController()

@objc func togglePopover(_ sender: Any?) {
    if popover.isShown {
        popover.performClose(sender)
    } else {
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }
}
```

**数据绑定：**
SessionManager.onSessionsChanged → popoverController.updateSessions()

## 输入/输出契约

**输入来自 002：** `onSessionsChanged: (([SessionInfo]) -> Void)?` 回调

**集成 007：** 行点击时调用 TerminalAdapter.activateTab（如果 007 已完成），否则仅 dismiss popover

## 验收标准

- [ ] `swift build` 编译通过
- [ ] 点击菜单栏图标显示 NSPopover（非 NSMenu）
- [ ] Popover 显示所有活跃会话
- [ ] 每行显示颜色点、标签、状态、cwd
- [ ] 空闲会话 opacity 降低
- [ ] 点击行触发终端激活（如果 TerminalAdapter 可用）
- [ ] 再次点击菜单栏图标关闭 Popover
- [ ] 会话变化时 Popover 内容实时更新
