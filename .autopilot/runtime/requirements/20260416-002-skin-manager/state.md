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
brief_file: "/Users/stringzhao/workspace_sync/personal_projects/claude-code-buddy/.claude/worktrees/snuggly-juggling-parrot/.autopilot/project/tasks/002-skin-manager.md"
next_task: "003-refactor-animation"
auto_approve: false
knowledge_extracted: "skipped"
task_dir: "/Users/stringzhao/workspace_sync/personal_projects/claude-code-buddy/.claude/worktrees/snuggly-juggling-parrot/.autopilot/requirements/20260416-002-skin-manager"
session_id: 05a94fad-7a57-4363-8e7e-3bca0ae6505a
started_at: "2026-04-16T15:16:28Z"
---

## 目标
---
id: "002-skin-manager"
depends_on: ["001-skin-types"]
---

# 002: DefaultSkinManifest + SkinPackManager

## 目标
创建中央管理器：加载内置皮肤、扫描本地皮肤、持久化选择、通知变更。

## 架构上下文
- SkinPackManager 是 singleton (`shared`)，所有消费方通过它获取当前皮肤
- 首次引入 UserDefaults 到项目（之前零使用）

## 要创建的文件
- `Sources/ClaudeCodeBuddy/Skin/DefaultSkinManifest.swift` — 静态属性返回当前硬编码值的 manifest
- `Sources/ClaudeCodeBuddy/Skin/SkinPackManager.swift` — singleton + Combine
- `Tests/BuddyCoreTests/SkinPackManagerTests.swift`

## 输入/输出契约

### DefaultSkinManifest
需要精确复制当前所有硬编码值：
- `spritePrefix: "cat"`
- `animationNames: ["idle-a","idle-b","clean","sleep","scared","paw","walk-a","walk-b","jump"]`
- `canvasSize: [48, 48]`
- `bedNames: ["bed-blue","bed-gray","bed-pink","bed-green"]`
- `boundarySprite: "boundary-bush"`
- `foodNames: [102 个食物名]` — 从 FoodSprite.allFoodNames 精确复制
- `menuBar: walkPrefix "menubar-walk", count 6, runPrefix "menubar-run", count 5, idle "menubar-idle-1", dir "Sprites/Menubar"`

### SkinPackManager
- `static let shared`
- `private(set) var activeSkin: SkinPack`
- `private(set) var availableSkins: [SkinPack]`
- `let skinChanged = PassthroughSubject<SkinPack, Never>()` (import Combine)
- `func loadBuiltInSkin()` — 用 DefaultSkinManifest + ResourceBundle.bundle
- `func loadLocalSkins()` — 扫描 `~/Library/Application Support/ClaudeCodeBuddy/Skins/`
- `func selectSkin(_ skinId: String)` — 更新 activeSkin + UserDefaults + send()
- UserDefaults key: `"selectedSkinId"`
- 初始化时: loadBuiltInSkin() + loadLocalSkins() + 从 UserDefaults 恢复选择（找不到则 fallback default）

## 验收标准
- [ ] `swift build` 编译通过
- [ ] `swift test --filter SkinPackManagerTests` 通过
- [ ] 内置皮肤加载后 activeSkin 可解析所有默认资源
- [ ] selectSkin round-trip: 选择 → UserDefaults → 重新加载 → activeSkin 一致
- [ ] skinChanged subject 在选择变化时触发
- [ ] 缺失 skinId fallback 到 "default"

--- handoff: 001-skin-types ---
# Handoff: 001-skin-types → 002-skin-manager

## 完成的接口

### SkinPackManifest (Sources/ClaudeCodeBuddy/Skin/SkinPackManifest.swift)
- `struct SkinPackManifest: Codable, Equatable` — 14 字段，显式 CodingKeys snake_case 映射
- 注意: `MenuBarConfig` 是**顶层类型**（非嵌套），因 SwiftLint nesting 规则提升

### SkinPack (Sources/ClaudeCodeBuddy/Skin/SkinPack.swift)
- `struct SkinPack: Equatable` — manifest + SkinSource(builtIn/local)
- `url(forResource:withExtension:subdirectory:)` — builtIn 补 "Assets/" 前缀，local 走 FileManager
- Equatable 基于 `manifest.id`

## 002 需要做的
- 创建 `DefaultSkinManifest` 静态属性，用精确的当前硬编码值构造 SkinPackManifest
- 创建 `SkinPackManager` singleton，用 `SkinPack(manifest: DefaultSkinManifest.manifest, source: .builtIn(ResourceBundle.bundle))` 作为内置皮肤
- `foodNames` 需要从 `FoodSprite.allFoodNames` 精确复制 102 个值

## 版本
v0.7.0 (feat 升级)


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
- **目标**: DefaultSkinManifest（精确复制当前硬编码值）+ SkinPackManager（singleton, Combine, UserDefaults）
- **DefaultSkinManifest**: 静态 manifest 属性，102 食物名、9 动画名、4 床名、menuBar 配置
- **SkinPackManager**: shared singleton, activeSkin/availableSkins, skinChanged (PassthroughSubject), selectSkin(), loadLocalSkins()
- **持久化**: UserDefaults key "selectedSkinId", fallback "default"
- **本地皮肤**: ~/Library/Application Support/ClaudeCodeBuddy/Skins/ 目录扫描

## 实现计划
- [x] 实现 DefaultSkinManifest.swift — 静态 manifest 含全部 102 食物名
- [x] 实现 SkinPackManager.swift — singleton + Combine + UserDefaults + 本地扫描
- [x] 实现 SkinPackManagerTests.swift — 单元测试
- [x] make build 编译通过
- [x] make test 全部通过
- [x] make lint 通过

## 红队验收测试
- `Tests/BuddyCoreTests/SkinPackManagerAcceptanceTests.swift` — 31 个验收测试
  - DefaultSkinManifest 字段精确匹配（19）: id/spritePrefix/canvasSize/boundarySprite/directories + animationNames(9)/bedNames(4)/foodNames(102) + menuBar 6 字段
  - SkinPackManager singleton（4）: shared 存在/singleton 唯一/availableSkins 非空/含 default
  - selectSkin 行为（4）: 幂等/写 UserDefaults/覆盖 UserDefaults/触发 skinChanged
  - 无效 skinId fallback（2）: 无效 ID/空字符串
  - skinChanged 契约（2）: 恰好触发一次/PassthroughSubject 类型

## QA 报告

### Wave 1
| Tier | 状态 | 证据 |
|------|------|------|
| Tier 0 | ✅ | 31 acceptance tests, 0 failures |
| Tier 1 Build | ✅ | Build complete (0.47s) |
| Tier 1 Test | ✅ | 319 tests, 0 failures |
| Tier 1 Lint | ✅ | 0 violations |

### Wave 1.5 (E=3, N=3 ✅)

**场景 1: DefaultSkinManifest 完整性**
- 执行: `swift test --filter "testDefaultManifest"`
- 输出: 43 tests passed — 所有字段值精确匹配（102 food/9 anim/4 bed/menuBar 6 字段）

**场景 2: selectSkin 持久化**
- 执行: `swift test --filter "testSelectSkin"`
- 输出: 8 tests passed — selectSkin 写 UserDefaults + 触发 skinChanged

**场景 3: 无效 skinId fallback**
- 执行: `swift test --filter "testSelectInvalidSkinIDFallsBackToDefault|testSelectEmptySkinIDKeepsDefault"`
- 输出: 2 tests passed — 无效 ID 和空字符串都 fallback 到 default

### 总结: ✅ 全部通过

## 变更日志
- [2026-04-16T15:35:25Z] 用户批准验收，进入合并阶段
- [2026-04-16T15:16:28Z] autopilot 初始化（brief 模式），任务: 002-skin-manager.md
- [2026-04-16T15:25:00Z] 设计方案通过审批
- [2026-04-16T15:30:00Z] 蓝队完成: DefaultSkinManifest + SkinPackManager + 34 蓝队测试
- [2026-04-16T15:30:00Z] 红队完成: SkinPackManagerAcceptanceTests (31 验收测试)
- [2026-04-16T15:30:00Z] make build ✅ / make test 319 tests ✅ / make lint 0 violations ✅
- [2026-04-16T15:35:00Z] QA 全部通过: Tier 0 ✅ / Tier 1 ✅ / Tier 1.5 ✅ (3/3)
- [2026-04-16T15:40:00Z] commit fe41b44: feat(skin): 实现内置皮肤 manifest 与 SkinPackManager + v0.8.0
- [2026-04-16T15:40:00Z] handoff → 003-refactor-animation, auto-chain: next_task set
- [2026-04-16T15:40:00Z] phase: done — 任务 002 完成
