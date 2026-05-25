---
active: true
phase: "done"
gate: ""
iteration: 1
max_iterations: 30
max_retries: 3
retry_count: 0
mode: "single"
plan_mode: ""
brief_file: "/Users/stringzhao/workspace_sync/personal_projects/claude-code-buddy/.claude/worktrees/snuggly-juggling-parrot/.autopilot/project/tasks/004-refactor-scene.md"
next_task: "005-refactor-food"
auto_approve: false
knowledge_extracted: "skipped"
task_dir: "/Users/stringzhao/workspace_sync/personal_projects/claude-code-buddy/.claude/worktrees/snuggly-juggling-parrot/.autopilot/requirements/20260416-004-refactor-scene"
session_id: 05a94fad-7a57-4363-8e7e-3bca0ae6505a
started_at: "2026-04-16T15:44:57Z"
---

## 目标
---
id: "004-refactor-scene"
depends_on: ["002-skin-manager"]
---

# 004: 重构 BuddyScene（边界+床）

## 目标
BuddyScene 的边界装饰和床精灵加载改为通过 SkinPack 驱动。

## 要修改的文件
- `Sources/ClaudeCodeBuddy/Scene/BuddyScene.swift`
- `Sources/ClaudeCodeBuddy/Entity/Cat/States/CatTaskCompleteState.swift`
- `Sources/ClaudeCodeBuddy/Entity/Cat/CatConstants.swift`

## 变更详情

### BuddyScene.swift
- `loadBoundaryTexture()`: 硬编码 `"boundary-bush"` → `SkinPackManager.shared.activeSkin.manifest.boundarySprite`
- 资源解析: `ResourceBundle.bundle.url(...)` → `SkinPackManager.shared.activeSkin.url(...)`
- `bedColorName(for:)` 或类似方法: `CatConstants.TaskComplete.bedNames` → `SkinPackManager.shared.activeSkin.manifest.bedNames`

### CatTaskCompleteState.swift
- `loadBedTexture(named:)`: `ResourceBundle.bundle.url(...)` → `SkinPackManager.shared.activeSkin.url(..., subdirectory: manifest.spriteDirectory)`
- 新增 `reloadBedTexture(from skin: SkinPack)` 方法（供热替换使用）

### CatConstants.swift
- 移除 `TaskComplete.bedNames`（迁移到 manifest）
- 保留 `TaskComplete.maxSlots`、`bedRenderSize`（布局常量，非皮肤配置）

## 验收标准
- [ ] `make build` 编译通过
- [ ] `make test` 全部通过
- [ ] 边界装饰和床正常渲染
- [ ] BuddyScene 和 CatTaskCompleteState 不再有 `ResourceBundle.bundle` 直接引用
- [ ] CatConstants 不再有 bedNames

--- handoff: 002-skin-manager ---
# Handoff: 002-skin-manager → 003/004/005/006

## 完成的接口

### DefaultSkinManifest (Sources/ClaudeCodeBuddy/Skin/DefaultSkinManifest.swift)
- `enum DefaultSkinManifest` — caseless enum (namespace)
- `static let manifest: SkinPackManifest` — 内置皮肤完整配置
- 包含精确的 102 食物名、9 动画名、4 床名、menuBar 配置

### SkinPackManager (Sources/ClaudeCodeBuddy/Skin/SkinPackManager.swift)
- `static let shared` — singleton
- `activeSkin: SkinPack` — 当前皮肤（默认 .builtIn(ResourceBundle.bundle)）
- `availableSkins: [SkinPack]` — 所有可用皮肤
- `skinChanged: PassthroughSubject<SkinPack, Never>` — Combine 通知
- `selectSkin(_ skinId: String)` — 切换 + UserDefaults 持久化 + send
- `loadLocalSkins()` — 扫描 ~/Library/Application Support/ClaudeCodeBuddy/Skins/

## 003-006 如何消费
各重构任务需要将硬编码的资源引用替换为:
- `SkinPackManager.shared.activeSkin` 获取当前皮肤
- `SkinPackManager.shared.activeSkin.manifest.xxx` 获取配置值（如 animationNames, bedNames 等）
- `SkinPackManager.shared.activeSkin.url(forResource:withExtension:subdirectory:)` 加载纹理

## 版本
v0.8.0


--- 架构设计摘要 ---
# 皮肤包系统 — 项目设计文档

## 目标

为 Claude Code Buddy 引入皮肤包系统，使猫咪精灵、动画、装饰物（床、边界）、食物、菜单栏图标可按皮肤包切换。提供设置中心 UI 和远程皮肤商店。

## 系统架构

```
SkinPackManifest (Codable)          ← 皮肤包元数据 + 资产配置
        ↑
SkinPack (struct)                   ← manifest + 资源解析（Bundle 或 file URL）
        ↑
SkinPackManager (singleton)         ← 加载/选择/持久化/变更通知
   ↑           ↑            ↑
CatSprite  MenuBarAnimator  BuddyScene/FoodSprite
```

**数据流**: 用户选皮肤 → SkinPackManager.selectSkin() → UserDefaults 持久化 → Combine skinChanged → AppDelegate 接收 → 分发到 BuddyScene.reloadSkin() + MenuBarAnimator.reloadSprites()

## 关键技术决策

1. **SkinPack 统一资源解析**: `url(forResource:withExtension:subdirectory:)` 方法，内置皮肤走 `Bundle.url()` 带 "Assets/" 前缀，本地/下载皮肤走 `FileManager` 直接拼接
2. **Manifest 驱动**: `manifest.json` 声明所有资产名和配置
3. **UserDefaults 持久化**: `selectedSkinId` 单键
4. **NSPanel 设置窗口**: 独立于 popover 的浮动面板
5. **热替换**: removeAllActions() → loadTextures() → resume()。CatEatingState 跳过（吃完自然用新纹理）

## SkinPackManifest 结构

```swift
struct SkinPackManifest: Codable, Equatable {
    let id: String
    let name: String
    let author: String
    let version: String
    let previewImage: String?
    let spritePrefix: String
    let animationNames: [String]
    let canvasSize: [CGFloat]
    let bedNames: [String]
    let boundarySprite: String
    let foodNames: [String]
    let foodDirectory: String
    let spriteDirectory: String
    let menuBar: MenuBarConfig

    struct MenuBarConfig: Codable, Equatable {
        let walkPrefix: String
        let walkFrameCount: Int
        let runPrefix: String
        let runFrameCount: Int
        let idleFrame: String
        let directory: String
    }
}
```

## 跨任务约束

> 📚 项目知识库已存在: .autopilot/。design 阶段请先加载相关知识上下文。

## 设计文档
- **目标**: BuddyScene + CatTaskCompleteState 的边界/床精灵加载改为 SkinPack 驱动
- **BuddyScene**: loadBoundaryTexture() 读 manifest.boundarySprite + activeSkin.url(); bedColorName() 读 manifest.bedNames
- **CatTaskCompleteState**: loadBedTexture() 改用 activeSkin.url(); 新增 reloadBedTexture(from:) + currentBedName
- **CatConstants**: 移除 bedNames（迁移到 manifest）

## 实现计划
- [x] BuddyScene.loadBoundaryTexture() 改用 SkinPack
- [x] BuddyScene.bedColorName(for:) 改用 manifest.bedNames
- [x] CatTaskCompleteState.loadBedTexture(named:) 改用 SkinPack
- [x] CatTaskCompleteState 新增 reloadBedTexture(from:) + 存储 currentBedName
- [x] CatConstants 移除 bedNames
- [x] make build + make test + make lint

## 红队验收测试
N/A — 纯重构，319 现有测试覆盖回归验证。

## QA 报告

### Wave 1
| Tier | 状态 | 证据 |
|------|------|------|
| Tier 0 | N/A | 纯重构 |
| Tier 1 Build | ✅ | Build complete (3.79s) |
| Tier 1 Test | ✅ | 319 tests, 0 failures |
| Tier 1 Lint | ✅ | 0 violations |

### Wave 1.5 (E=2, N=2 ✅)

**场景 1: 编译 + 全量测试无回归**
- 执行: `make build && make test`
- 输出: Build complete, 319 tests passed, 0 failures

**场景 2: 无硬编码残留**
- 执行: `grep -n "ResourceBundle\|bedNames" BuddyScene.swift CatTaskCompleteState.swift CatConstants.swift`
- 输出: 仅 BuddyScene:420 的 manifest.bedNames（正确引用），无 ResourceBundle/CatConstants.bedNames

### 总结: ✅ 全部通过

## 变更日志
- [2026-04-16T15:51:46Z] 用户批准验收，进入合并阶段
- [2026-04-16T15:44:57Z] autopilot 初始化（brief 模式），任务: 004-refactor-scene.md
- [2026-04-16T15:48:00Z] 实现完成: BuddyScene + CatTaskCompleteState + CatConstants 3 文件修改
- [2026-04-16T15:48:00Z] QA 全部通过: build ✅ / 319 tests ✅ / lint ✅ / 无硬编码残留 ✅
- [2026-04-16T15:52:00Z] commit 17d8177: refactor(皮肤包) BuddyScene 边界/床 SkinPack 驱动
- [2026-04-16T15:52:00Z] phase: done — 任务 004 完成, next: 005-refactor-food
