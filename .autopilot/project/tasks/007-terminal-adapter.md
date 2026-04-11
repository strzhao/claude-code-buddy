---
id: "007-terminal-adapter"
depends_on: ["002-session-manager", "005-mouse-tracker"]
---

## 目标

创建 TerminalAdapter 协议和 GhosttyAdapter 实现，支持点击猫精灵跳转到对应终端窗口。

## 架构上下文

点击事件由 MouseTracker.onClick 触发，通过 BuddyScene/AppDelegate 路由到 TerminalAdapter。Ghostty 标签页标题已被 004-hook-script 设置为 `●{label}` 格式。

## 关键实现细节

### TerminalAdapter 协议 (`Sources/ClaudeCodeBuddy/Terminal/TerminalAdapter.swift`)

```swift
protocol TerminalAdapter {
    func canHandle(bundleIdentifier: String) -> Bool
    func activateTab(for session: SessionInfo) -> Bool
}
```

### GhosttyAdapter (`Sources/ClaudeCodeBuddy/Terminal/GhosttyAdapter.swift`)

**匹配策略（3 级降级）：**

| 优先级 | 方法 | 可靠性 |
|--------|------|--------|
| 1 | 标签页标题标记 `●{label}` | 最高 |
| 2 | working directory 匹配 | 高 |
| 3 | PID-based 激活 | 中 |

**AppleScript 激活：**
```swift
func activateTab(for session: SessionInfo) -> Bool {
    let script = """
    tell application "Ghostty"
      repeat with w in windows
        repeat with t in tabs of w
          set term to focused terminal of t
          if name of term contains "●\(session.label)" then
            focus term
            return true
          end if
        end repeat
      end repeat
    end tell
    return false
    """
    // 执行 AppleScript
    // 如果失败，降级到 PID-based 激活
}
```

**PID 降级：**
```swift
private func activateByPID(_ pid: Int) -> Bool {
    guard let app = NSRunningApplication(processIdentifier: pid_t(pid)) else { return false }
    return app.activate()
}
```

### 集成

AppDelegate 持有 `[TerminalAdapter]` 数组（当前只有 GhosttyAdapter）。
MouseTracker.onClick → BuddyScene/AppDelegate → 遍历 adapters 尝试激活。

## 输入/输出契约

**输入来自 002：** SessionInfo（label, cwd, pid）

**输入来自 005：** onClick 回调提供 sessionId

**输入来自 004：** Ghostty 标签页标题格式 `●{label}`

## 验收标准

- [ ] `swift build` 编译通过
- [ ] TerminalAdapter 协议定义正确
- [ ] GhosttyAdapter 能通过 `●{label}` 匹配 Ghostty 标签页
- [ ] AppleScript 失败时降级到 PID-based 激活
- [ ] Ghostty 未运行时不崩溃，返回 false
- [ ] activateTab 返回 Bool 表示是否成功
