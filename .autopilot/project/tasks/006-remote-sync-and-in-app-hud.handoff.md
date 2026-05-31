# Task 006 Handoff — MarketHUD + sync 4 NSLog 替换 + 并发锁

## 实现摘要

新建 MarketHUD（@MainActor 单例 NSPanel + SwiftUI HUDView + 可注入 `dismissDelay`），替代 deprecated NSUserNotificationCenter，零权限自建。MarketplaceManager.syncFromRemote 的 4 处 NSLog 占位替换为 `await hud?.show(...)`（直接 await @MainActor 协议方法，编译器自动 hop，不嵌套 MainActor.run）。顺手加 sync-vs-sync NSLock 互斥（同步 helper 包装避 Swift 6 async-context-lock 警告）。qa-reviewer 发现 AppDelegate 漏订阅 `BuddyStoreShouldOpen`（HUD "查看"按钮 dead-end），即时 +12 行修复。

**6 BLOCKER 修复要点全部落地**：
- B1: `makeDiffText` helper 安全 optional 解构（无 `!`）+ 多项时计数文本
- B2: `await hud?.show(...)` 直接调，**不嵌套** MainActor.run（@MainActor 协议跨 actor 调用编译器自动 hop）
- B3: configureHUD 同实例 no-op return + 不同实例 precondition trap
- B4: `resetHUDForTesting()` internal helper（重置 hud + syncInProgress）
- B5: `var dismissDelay: TimeInterval = 5.0` 可注入（测试用 0.1s 加速）
- B6: 诚实声明 `syncLock` 仅护 sync-vs-sync（install/reseed vs sync 留 phase 2）

## 文件变更（commit 609a2eb）

**新增**:
- `Sources/.../Launcher/Marketplace/MarketHUD.swift`（@MainActor 协议 + 类 + Action struct + SwiftUI HUDView）
- 3 测试文件：MarketHUDTests (8) + MarketplaceManagerHUDIntegrationTests (9) + MarketHUDAcceptanceTests (13)

**修改**:
- `MarketplaceManager.swift`：+ hud / syncLock / configureHUD / resetHUDForTesting / makeDiffText / openSyncLog / openBuddyStore / Notification.Name 扩展 + 4 处 NSLog → `await hud?.show(...)`（+123 -5）
- `LauncherManager.swift`：setup 加 1 行 `MarketplaceManager.shared.configureHUD(MarketHUD.shared)`
- `AppDelegate.swift`：订阅 `BuddyStoreShouldOpen` 通知 + `@objc handleBuddyStoreShouldOpen` → `showSettings()`（qa-reviewer 发现的 dead-end fix）

## 验证证据

- swift build: PASS
- swift test --filter "MarketHUD|MarketplaceManager": **62 tests / 0 failures**
- 跨 suite Marketplace: **66 tests / 0 failures**（task 003 baseline 不破坏）
- make lint: 0 violations / 108 files
- contract-checker: **PASS（0 mismatches）**
- Tier 1.5 6/6 PASS（E=N=6）
- qa-reviewer Section A 12/12 + Section B 4 评价

## 下游须知

### task 007 (CLI) 复用

- `buddy launcher install <name>` 调 `MarketplaceManager.shared.install(name:)`（task 003）；安装成功不需要触发 HUD（与 sync 后台路径不同）
- CLI 不依赖 MarketHUD（无 UI 上下文）
- `BuddyStoreShouldOpen` 通知由 AppDelegate 内订阅，与 CLI 无关

### Notification.Name 契约

```swift
extension Notification.Name {
    static let buddyStoreShouldOpen = Notification.Name("BuddyStoreShouldOpen")
}
```

`openBuddyStore()` 发 post，AppDelegate 订阅 → `showSettings()`。无 userInfo。

### MarketHUD 单例使用约束

- 调用方：仅 MarketplaceManager（已 wire）+ phase 2 可能的其他 NSUserNotificationCenter 替代场景
- 不要在测试用 MarketHUD.shared（会污染单例）；测试注入 mock `MarketHUDDisplaying`

## 偏差说明

无契约偏差。

**Follow-up（非阻塞，phase 2 处理）**：
- task 003 follow-up #1 完整版（install/reseed vs sync 互斥）需 actor 化整个 MarketplaceManager
- task 003 follow-up #2 `appendSyncLog` flock
- task 003 follow-up #3 temp path 判定改 hasPrefix

## 关键陷阱（写入 knowledge）

@MainActor 协议方法跨 actor 调用时，编译器自动 hop 到 MainActor 上下文执行，**调用方不嵌套 `MainActor.run`**。错误的双重嵌套会导致 hop 两次/语义歧义。这是 Swift Concurrency 的隐性行为。
