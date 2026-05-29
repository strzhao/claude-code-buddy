---
id: "006-remote-sync-and-in-app-hud"
depends_on: ["003", "004"]
---

# Task 006 — Market 后台同步 + 自建 in-app HUD

## 目标（一句话）

MarketHUD 自建 NSPanel.nonactivatingPanel 浮窗 5s 自隐（替代 deprecated NSUserNotificationCenter）；syncFromRemote 后调用 MarketHUD.show("translate 已更新到 v0.2.0", actions: [...])；每次同步追加结构化 JSON 行到 ~/.buddy/launcher-sync.log；连续 3 次失败 HUD 提示"无法连接 Market"。

## 架构上下文

- 依赖 003（syncFromRemote 已存在但用 print 占位）+ 004（disable 状态读取）
- 与 task 005/007 并行
- NSUserNotificationCenter 已 deprecated（macOS 11+），自建零权限 HUD 替代

## 输入

- task 003 的 `MarketplaceManager.syncFromRemote()` 已实现 diff 算法
- 现有 LauncherWindow 是 NSPanel.nonactivatingPanel 参考模式

## 输出契约

### 新建 `Sources/ClaudeCodeBuddy/Launcher/Marketplace/MarketHUD.swift`

```swift
@MainActor
final class MarketHUD {
    static let shared = MarketHUD()
    
    struct HUDAction {
        let label: String
        let handler: () -> Void
    }
    
    /// 显示一行文本 + 可选按钮，5s 自隐
    /// 非抢焦点（nonactivatingPanel）
    /// 多次调用：替换内容 + 重置 5s 倒计时
    func show(text: String, actions: [HUDAction] = [])
    
    /// 立即关闭
    func dismiss()
}
```

### 实现要点

- `NSPanel(contentRect:, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)`
- `panel.level = .floating`，`panel.isFloatingPanel = true`
- panel.collectionBehavior = `[.canJoinAllSpaces, .stationary]`
- 位置：屏幕右上角，距 menubar 16pt
- 内容：SwiftUI HUDView（HStack: 图标 + text + 按钮组）+ NSHostingController 嵌入
- 5s 自隐用 `Task { try? await Task.sleep(...); dismiss() }`，重复 show 时取消旧 task

### 修改 `MarketplaceManager.syncFromRemote()`（task 003 占位）

```diff
- print("[sync] translate 已更新到 v0.2.0")  // task 006 替换为 MarketHUD
+ await MainActor.run {
+     MarketHUD.shared.show(
+         text: "translate 已更新到 v0.2.0",
+         actions: [
+             .init(label: "查看 diff") { /* TODO phase 2 */ },
+             .init(label: "关闭") { MarketHUD.shared.dismiss() }
+         ]
+     )
+ }
```

### 修改 `MarketplaceManager` 加结构化日志

每次 syncFromRemote 执行后追加一行 JSON 到 `~/.buddy/launcher-sync.log`：

```json
{"ts": "2026-05-29T14:00:00Z", "status": "updated", "oldHash": "abc...", "newHash": "def...", "addedPlugins": [], "updatedPlugins": ["translate"], "removedPlugins": []}
{"ts": "2026-05-29T15:00:00Z", "status": "noop", "reason": "debounce"}
{"ts": "2026-05-29T16:00:00Z", "status": "failed", "error": "network timeout", "consecutiveFailures": 1}
```

### 连续 3 次失败提示

```swift
if marketplaceMeta.consecutiveSyncFailures >= 3 {
    await MainActor.run {
        MarketHUD.shared.show(
            text: "无法连接 Market（连续 \(failures) 次失败）",
            actions: [.init(label: "查看日志") { /* open ~/.buddy/launcher-sync.log */ }]
        )
    }
}
```

## 验收标准

### 自动化测试（红队）

1. **MarketHUD.show 显示**：调 show → panel.isVisible == true
2. **MarketHUD 5s 自隐**：调 show → 模拟时间过 5s → panel.isVisible == false
3. **MarketHUD 重复 show 重置倒计时**：show → 3s 后再 show → 再过 4s → 仍可见（共 7s）
4. **dismiss 立即关闭**：show → dismiss → 立即不可见
5. **结构化日志写入**：syncFromRemote 成功后 → 读 launcher-sync.log → 最后一行 JSON 解析 OK + status=="updated" 或 "noop"
6. **连续 3 次失败触发 HUD**：mock syncFromRemote 连续 3 次失败 → 第 3 次后 MarketHUD.show 被调用
7. **HUD 按钮 handler 触发**：构造 HUDAction(handler: { capturedFlag = true }) → 模拟点击 → flag == true

### 验证命令

```bash
cd apps/desktop && swift build && swift test --filter "MarketHUD|SyncLog"
```

### Tier 1.5 真实场景

1. **mock server + diff**: 本地起 HTTP server 返回 v0.2 marketplace.json，env `BUDDY_MARKETPLACE_URL` 启动 app → 等 syncFromRemote → 屏幕右上角 HUD 弹"translate 已更新到 v0.2.0" → 5s 自隐
2. **log 写入**: `cat ~/.buddy/launcher-sync.log` 应有最新一行 JSON
3. **debounce 验证**: 立即重启 app → log 新增 status: "noop" reason: "debounce"

## 下游须知（handoff 要点）

- `MarketHUD.shared` 是 `@MainActor` 单例，所有调用必须切回主线程
- `BUDDY_MARKETPLACE_URL` 环境变量覆盖默认 GitHub Raw URL，供 dev/CI 用
- 日志文件不自动 rotate，phase 2 加 size cap
