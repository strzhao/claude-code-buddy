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
brief_file: "/Users/stringzhao/workspace_sync/personal_projects/claude-code-buddy/.claude/worktrees/snuggly-juggling-parrot/.autopilot/project/tasks/008-settings-ui.md"
next_task: "009-skin-store"
auto_approve: false
knowledge_extracted: "skipped"
task_dir: "/Users/stringzhao/workspace_sync/personal_projects/claude-code-buddy/.claude/worktrees/snuggly-juggling-parrot/.autopilot/requirements/20260417-008-settings-ui"
session_id: 05a94fad-7a57-4363-8e7e-3bca0ae6505a
started_at: "2026-04-16T16:12:16Z"
---

## 目标
---
id: "008-settings-ui"
depends_on: ["007-hotswap"]
---

# 008: 设置窗口 + 皮肤画廊 + popover 按钮

## 目标
从菜单栏弹窗打开独立设置窗口，展示皮肤画廊，单击即时切换。

## 要创建的文件
- `Sources/ClaudeCodeBuddy/Settings/SettingsWindowController.swift` — NSWindowController + NSPanel
- `Sources/ClaudeCodeBuddy/Settings/SkinGalleryViewController.swift` — NSScrollView + NSStackView 画廊
- `Sources/ClaudeCodeBuddy/Settings/SkinGalleryItemView.swift` — 单个皮肤卡片 NSView

## 要修改的文件
- `Sources/ClaudeCodeBuddy/MenuBar/SessionPopoverController.swift` — 底栏加齿轮按钮
- `Sources/ClaudeCodeBuddy/App/AppDelegate.swift` — 管理设置窗口生命周期

## 变更详情

### SessionPopoverController
- 底栏新增齿轮按钮（NSButton with SF Symbol "gear"），放在 footerLabel 和 Quit 按钮之间
- 新增 `var onSettings: (() -> Void)?` 回调

### SettingsWindowController
- NSWindowController 创建 NSPanel (styleMask: [.titled, .closable, .resizable])
- 非模态，浮动，可与主窗口共存
- 标题 "Claude Code Buddy — Settings"
- 内容: SkinGalleryViewController

### SkinGalleryViewController（NSStackView 方案，非 NSCollectionView）
- 用 NSScrollView 包裹垂直 NSStackView
- 从 `SkinPackManager.shared.availableSkins` 获取皮肤列表
- 每个皮肤渲染为 SkinGalleryItemView
- 点击选中 → 调用 `SkinPackManager.shared.selectSkin(id:)` → 热替换自动生效
- 订阅 `SkinPackManager.shared.skinChanged` 更新选中态
- 底部预留 "Get More Skins" 占位区域（009 任务填充）

### SkinGalleryItemView（单个卡片）
- 预览图 (NSImageView, 80x60pt) — 从 manifest.previewImage 加载，无则显示首帧精灵
- 皮肤名 (NSTextField, bold 13pt)
- 作者 (NSTextField, secondary 11pt)
- 选中态: 蓝色边框 + checkmark overlay

### AppDelegate
- 持有 `private var settingsWindowController: SettingsWindowController?`
- popoverController.onSettings 回调中: 关闭 popover → 创建/显示设置窗口
- 设置窗口关闭不退出 app（NSPanel 默认行为）

## 验收标准
- [ ] `make build` 编译通过
- [ ] popover 底栏齿轮按钮可见
- [ ] 点击齿轮 → 设置窗口弹出
- [ ] 画廊显示所有可用皮肤（至少 default）
- [ ] 当前皮肤有选中态标识
- [ ] 点击其他皮肤 → 立即切换 + 猫咪更新
- [ ] 设置窗口与猫咪场景不互相阻塞


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
- **目标**: 纯 AppKit 设置 UI — 齿轮按钮 → NSPanel → NSStackView 皮肤画廊 → 单击切换
- 3 个新文件: SettingsWindowController + SkinGalleryViewController + SkinGalleryItemView
- 2 个修改: SessionPopoverController(齿轮按钮) + AppDelegate(设置窗口管理)

## 实现计划
- [x] 新建 Settings/ 目录 + 3 个文件
- [x] SessionPopoverController 齿轮按钮 + onSettings
- [x] AppDelegate settingsWindowController + showSettings()
- [x] make build + test + lint 全部通过

## 红队验收测试
N/A — UI 任务，需运行时视觉验证。319 现有测试覆盖编译回归。

## QA 报告
### Wave 1
| Tier | 状态 | 证据 |
|------|------|------|
| Tier 1 Build | ✅ | Build complete (2.18s) |
| Tier 1 Test | ✅ | 319 tests, 0 failures |
| Tier 1 Lint | ✅ | 0 violations in 56 files |

### Wave 1.5 (E=2, N=2 ✅)
**场景 1**: `make build && make test` → 319 tests passed
**场景 2**: `ls Settings/ + grep onSettings/gearshape/settingsWindowController` → 3 新文件 + popover 齿轮按钮 + AppDelegate 设置窗口管理

### 总结: ✅ 全部通过

## 变更日志
- [2026-04-16T16:22:19Z] 用户批准验收，进入合并阶段
- [2026-04-16T16:12:16Z] autopilot 初始化（brief 模式），任务: 008-settings-ui.md
