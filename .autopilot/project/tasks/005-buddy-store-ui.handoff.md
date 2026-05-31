# Task 005 Handoff — Buddy Store UI 重构

## 实现摘要

SettingsWindowController 重构为 Buddy Store：title "Buddy Store" + 顶部 NSSegmentedControl 切 [皮肤/插件]（嵌入 NSTitlebarAccessoryViewController + 必须含 `.fullSizeContentView` styleMask）+ 上次选中 tab 持久化 UserDefaults `BuddyStoreSelectedTab`。新建 PluginGalleryViewController 四态状态机 (loading/normal/empty/error) + 协议化 DI（MarketplaceInspecting + PluginToggling）+ NSButton.target/action 直绑 + sanitize 白名单。**SkinGalleryViewController 0 行改动**（钉死 M3）。

**7 BLOCKER/MUST-FIX 全修落地**：
- B1: PluginEntry 用 `isSideloaded: Bool` 替代 description（inspect 无 description 字段）
- B2: `inspect() throws`（非 async）+ `reseed() async throws`
- B3: `init(marketplace:plugins:)` DI + MarketplaceInspecting/PluginToggling 协议
- M1: PluginCardItem NSButton target/action 直绑 toggleButtonClicked，handleClickAt no-op
- M2: `internal private(set) var state`
- M3: SkinGallery 0 改动 + 独立文件 SkinGalleryViewController+SettingsTabClickReceiver.swift
- M4: AT13 改 sideloaded 渲染断言

## 文件变更（commit 256e2d4）

**新增**:
- `Sources/.../Settings/SettingsTabClickReceiver.swift`
- `Sources/.../Settings/PluginGalleryViewController.swift`（~260 行）
- `Sources/.../Settings/PluginCardItem.swift`
- `Sources/.../Settings/SkinGalleryViewController+SettingsTabClickReceiver.swift`（独立文件，6 行）
- `tests/.../Settings/PluginGalleryViewControllerTests.swift`（蓝队 9 单测）
- `tests/.../Settings/PluginGalleryViewControllerAcceptanceTests.swift`（红队 13 AT）
- `tests/.../Settings/SettingsWindowControllerTabPersistenceTests.swift`（2 单测）

**修改**:
- `Sources/.../Settings/SettingsWindowController.swift`：title + 600x540 + styleMask 含 **`.fullSizeContentView`** + NSTitlebarAccessoryViewController + Tab enum + UserDefaults 持久化 + switchTo + SettingsPanel.activeTab

**不改**: SkinGalleryViewController.swift（git diff 0 行，M3 钉死兑现）

## 验证证据

- swift build: PASS
- swift test --filter "PluginGalleryViewController|SettingsWindowControllerTabPersistence": **24 tests / 0 failures**
- make lint: 0 violations / 107 files
- contract-checker: PASS（1 个 low enum case 顺序）
- Tier 1.5 5/5 PASS（E=N=5）
- qa-reviewer Section A 12/12 + Section B 5 正向评价

## 红蓝对抗高质量协作（最佳案例）

红队首轮 AT01-AT04 抛 `NSLayoutAttributeTop requires NSWindowStyleMaskFullSizeContentView` → 蓝队据此修复 SettingsWindowController.swift:25 styleMask 增加 `.fullSizeContentView` → 重跑全过。**红队独立测试发现蓝队真 bug，这是红蓝对抗设计的核心价值**。

## 下游须知

### task 006 (Market HUD) 复用

- `MarketplaceManager.syncFromRemote()` 内当前用 `NSLog` 占位；task 006 实现 MarketHUD 后替换为 `MarketHUD.shared.show(...)`
- Buddy Store UI 不直接消费 sync 事件（task 005 只读 inspect 结果），task 006 独立工作

### task 007 (CLI) 复用

- `SettingsWindowController.Tab` enum + `selectedTabDefaultsKey` 是 UI 内部约定，CLI 不需要
- CLI 调 `PluginManager.shared.disable/enable` 路径已在 task 004 就位

### sanitize 白名单已采纳 task 004 follow-up

- PluginGalleryViewController 内 `sanitize(_:)` 用 `^[a-z0-9-]+$` 拒绝非法 name
- task 007 CLI 入口建议同步加白名单（深度防御）

## 偏差说明

无契约偏差。

**Follow-up（不阻塞）**:
- SkinGallery snapshot 2 个 pre-existing failures（与本 task 无关，stash 验证）建议后续单独 task 刷新基线
- SettingsWindowController 同时持 skinGallery + pluginGallery（非 weak）避免重复 init 抖动，可接受

## 关键陷阱（写入 knowledge）

`.fullSizeContentView` styleMask 是 macOS 14+ 使用 `NSTitlebarAccessoryViewController` 嵌入 titlebar 的**强制要求**——缺失会抛 `NSLayoutAttributeTop requires NSWindowStyleMaskFullSizeContentView` 异常。这是 AppKit 文档不显眼的隐藏要求。
