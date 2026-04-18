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
brief_file: "/Users/stringzhao/workspace_sync/personal_projects/claude-code-buddy/.claude/worktrees/snuggly-juggling-parrot/.autopilot/project/tasks/006-refactor-menubar.md"
next_task: "007-hotswap"
auto_approve: false
knowledge_extracted: "skipped"
task_dir: "/Users/stringzhao/workspace_sync/personal_projects/claude-code-buddy/.claude/worktrees/snuggly-juggling-parrot/.autopilot/requirements/20260416-006-refactor-menubar"
session_id: 05a94fad-7a57-4363-8e7e-3bca0ae6505a
started_at: "2026-04-16T15:58:36Z"
---

## 目标
---
id: "006-refactor-menubar"
depends_on: ["002-skin-manager"]
---

# 006: 重构 MenuBarAnimator

## 目标
菜单栏精灵加载改为通过 SkinPack 驱动。

## 要修改的文件
- `Sources/ClaudeCodeBuddy/MenuBar/MenuBarAnimator.swift`

## 变更详情

### MenuBarAnimator.swift
- `loadSprites()`: 
  - walk 帧: `manifest.menuBar.walkPrefix` + `manifest.menuBar.walkFrameCount`
  - run 帧: `manifest.menuBar.runPrefix` + `manifest.menuBar.runFrameCount`
  - idle: `manifest.menuBar.idleFrame`
  - 目录: `manifest.menuBar.directory`
  - 全部通过 `SkinPackManager.shared.activeSkin.url(...)` 加载
- `loadFrameSequence(prefix:count:size:)`: 接收额外 `skin: SkinPack` 参数
- 新增 `func reloadSprites()`: 调用 `loadSprites()` + 重新应用当前状态（idle/walk/run）

## 验收标准
- [ ] `make build` 编译通过
- [ ] `make test` 全部通过
- [ ] 菜单栏图标正常显示和动画
- [ ] MenuBarAnimator 不再有 `ResourceBundle.bundle` 直接引用
- [ ] 新增 `reloadSprites()` 公开方法供热替换调用

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
- **目标**: MenuBarAnimator 精灵加载改为 SkinPack 驱动
- loadSprites(): 读 manifest.menuBar（walkPrefix/count, runPrefix/count, idleFrame, directory）
- loadFrameSequence(): 新增 skin 参数，使用 skin.url()
- 新增 reloadSprites() 公开方法供热替换调用

## 实现计划
- [x] loadSprites() 改用 SkinPack + manifest.menuBar
- [x] loadFrameSequence() 新增 skin 参数
- [x] 新增 reloadSprites() 公开方法
- [x] make build + test + lint 全部通过

## 红队验收测试
N/A — 纯重构，319 现有测试覆盖。

## QA 报告
### Wave 1
| Tier | 状态 | 证据 |
|------|------|------|
| Tier 1 Build | ✅ | Build complete (3.18s) |
| Tier 1 Test | ✅ | 319 tests, 0 failures |
| Tier 1 Lint | ✅ | 0 violations |

### Wave 1.5 (E=2, N=2 ✅)
**场景 1**: `make build && make test` → 319 tests passed
**场景 2**: `grep "ResourceBundle\|\"menubar-walk\"" MenuBarAnimator.swift` → 无匹配

### 总结: ✅ 全部通过

## 变更日志
- [2026-04-16T16:01:28Z] 用户批准验收，进入合并阶段
- [2026-04-16T15:58:36Z] autopilot 初始化（brief 模式），任务: 006-refactor-menubar.md
