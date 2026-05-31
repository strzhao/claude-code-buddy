# Task 004 Handoff — PluginManager 禁用/启用机制

## 实现摘要

最小化改动：仅 PluginManager.swift +49 行（3 公开方法 + 1 私有 helper + list() 1 处 `.disabled` 过滤）。**真零侵入**：MarketplaceManager / LauncherRouter / LauncherManager 等 0 改动（设计承诺兑现）。

**核心设计**：`.disabled` 0 字节空文件标记法：
- 文件系统天然原子（无 lock）
- 删插件目录时自动消失（无垃圾）
- task 003 seedFromBundle / installPlugin 已实现保留 `.disabled` 拷贝过程

## 文件变更（commit fc5afaf）

**新增**:
- `apps/desktop/tests/BuddyCoreTests/Launcher/PluginManagerDisableEnableTests.swift`（蓝队 10 单测）
- `apps/desktop/tests/BuddyCoreTests/PluginManagerDisableEnableAcceptanceTests.swift`（红队 12 AT，315 行）

**修改**:
- `apps/desktop/Sources/ClaudeCodeBuddy/Launcher/Plugin/PluginManager.swift`（+49 行）：
  - 私有 `pluginDirURL(forName:)` helper
  - `func disable(name:) throws` — 创建 `.disabled` 空文件
  - `func enable(name:) throws` — 删 `.disabled`
  - `func disabledNames() throws -> [String]` — 扫 rootDir
  - `list()` 在 isDir 检查后插入 `.disabled` 跳过逻辑

## 验证证据

- swift build: PASS
- swift test --filter PluginManagerDisableEnable: **22 tests / 0 failures / 0.015s**
- 跨 suite Marketplace: **57 tests / 0 failures**（task 003 不破坏）
- SwiftLint --strict: 0 violations / 103 files
- contract-checker: **PASS（0 mismatches）**
- Tier 1.5 5/5 PASS（E=N=5）
- qa-reviewer Section A 12/12 + Section B 2 个 ≥80 follow-up

## 下游须知

### task 005 (Buddy Store UI) 直接复用

- `PluginManager.shared.disable(name:) / enable(name:)` API 已就位
- UI [禁用] 按钮点击 → 调 `disable("translate")` → 列表自动刷新（list() 已过滤）
- `disabledNames()` 可用于显示 [禁用] 状态条
- 重要：UI 接收 name 输入若来自用户（编辑插件 sideloaded name），需做 `[a-z0-9-]+` 白名单校验（深度防御）

### task 007 (CLI) 直接复用

- `buddy launcher disable <name>` → 调 `PluginManager.shared.disable(name:)`
- `buddy launcher enable <name>` → 调 `enable`
- `buddy launcher list` 显示 `[禁用]` → 用 `disabledNames()` 判定
- CLI 入口建议加 `[a-z0-9-]+` 白名单（防恶意调用）

### task 006 (sync HUD) 无需关注

- 本 task 不影响 sync 行为
- MarketplaceManager.installPlugin 在 task 003 已实现保留 `.disabled`

## 偏差说明

无契约偏差。

**2 个 follow-up（≥80 置信度，不阻塞）**：
1. **[88]** 路径注入深度防御缺口：disable/enable 直接拼 name，无 `[a-z0-9-]+` 校验。建议 task 005/007 接入入口加白名单，或 PluginManager 加 private assert
2. **[82]** 并发 race 非真实问题（APFS syscall 原子），无需处理
