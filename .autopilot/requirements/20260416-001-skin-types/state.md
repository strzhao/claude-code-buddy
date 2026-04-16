---
active: true
phase: "merge"
gate: ""
iteration: 2
max_iterations: 30
max_retries: 3
retry_count: 0
mode: "single"
plan_mode: ""
brief_file: "/Users/stringzhao/workspace_sync/personal_projects/claude-code-buddy/.claude/worktrees/snuggly-juggling-parrot/.autopilot/project/tasks/001-skin-types.md"
next_task: ""
auto_approve: false
knowledge_extracted: ""
task_dir: "/Users/stringzhao/workspace_sync/personal_projects/claude-code-buddy/.claude/worktrees/snuggly-juggling-parrot/.autopilot/requirements/20260416-001-skin-types"
session_id: 05a94fad-7a57-4363-8e7e-3bca0ae6505a
started_at: "2026-04-16T14:48:09Z"
---

## 目标
---
id: "001-skin-types"
depends_on: []
---

# 001: SkinPackManifest + SkinPack 核心类型

## 目标
定义皮肤包系统的基础数据模型，所有后续任务依赖此接口。

## 架构上下文
- 新目录: `Sources/ClaudeCodeBuddy/Skin/`
- 参考设计文档中的 `SkinPackManifest` 和 `SkinPack` 结构

## 要创建的文件
- `Sources/ClaudeCodeBuddy/Skin/SkinPackManifest.swift` — Codable + Equatable，含嵌套 MenuBarConfig
- `Sources/ClaudeCodeBuddy/Skin/SkinPack.swift` — SkinSource enum (builtIn/local) + url() 资源解析方法
- `Tests/BuddyCoreTests/SkinPackTests.swift` — 单元测试

## 输入/输出契约

### 输出
- `SkinPackManifest`: 所有字段 let，Codable 可从 JSON 反序列化
- `SkinPack.url(forResource:withExtension:subdirectory:) -> URL?`: builtIn 走 Bundle.url() 带 "Assets/" 前缀，local 走 FileManager 拼接

### 关键细节
- `canvasSize` 用 `[CGFloat]` 而非 CGSize（JSON 友好）
- `SkinPack` 的 `Equatable` 基于 `manifest.id`
- builtIn source 的 subdirectory 自动加 "Assets/" 前缀

## 验收标准
- [ ] `swift build` 编译通过
- [ ] `swift test --filter SkinPackTests` 全部通过
- [ ] Manifest JSON 序列化/反序列化 round-trip 测试
- [ ] builtIn 和 local 两种 SkinSource 的 url() 解析测试
- [ ] 缺失资源返回 nil 测试


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
- **目标**: 创建 SkinPackManifest（Codable 元数据）和 SkinPack（manifest + 资源解析）两个核心类型
- **技术方案**: 遵循项目 Codable 模式（显式 CodingKeys、snake_case JSON 映射）
- **文件**: SkinPackManifest.swift + SkinPack.swift (新建 Skin/ 目录) + SkinPackTests.swift
- **接口**: SkinPack.url(forResource:withExtension:subdirectory:) — builtIn 补 "Assets/" 前缀，local 走 FileManager

## 实现计划
- [x] 创建 Sources/ClaudeCodeBuddy/Skin/ 目录
- [x] 实现 SkinPackManifest.swift — Codable + Equatable + CodingKeys + MenuBarConfig
- [x] 实现 SkinPack.swift — SkinSource enum + url() + Equatable(基于 manifest.id)
- [x] 实现 Tests/BuddyCoreTests/SkinPackTests.swift — JSON round-trip + URL 解析测试
- [x] make build 编译通过
- [x] make test 全部通过

## 红队验收测试
- `Tests/BuddyCoreTests/SkinPackAcceptanceTests.swift` — 23 个验收测试
  - Manifest 解码（4）: 全字段/Required/Optional nil/Optional non-nil
  - MenuBarConfig（4）: 解码/大数值/snake_case 强制/camelCase 拒绝
  - snake_case 键名强制（1）: camelCase 键解码失败
  - Round-trip（2）: 含 previewImage / nil previewImage
  - Manifest Equatable（3）: 相同/不同 id/相同 id 不同字段
  - SkinPack Equatable（2）: 基于 manifest.id
  - Local URL 解析（3）: 文件存在/不存在/子目录不存在
  - BuiltIn URL（2）: nil 返回/Assets 前缀合约
  - SkinSource 完整性（2）: builtIn/local 匹配

## QA 报告

### Wave 1 — 命令执行
| Tier | 检查项 | 状态 | 证据 |
|------|--------|------|------|
| Tier 0 | 红队验收测试 (23) | ✅ | `swift test --filter SkinPackAcceptanceTests`: 23 passed, 0 failures |
| Tier 1 | Build | ✅ | `make build`: Build complete! (0.44s) |
| Tier 1 | Test (254) | ✅ | `make test`: 254 tests, 0 failures |
| Tier 1 | Lint | ✅ | `make lint`: 0 violations (MenuBarConfig 提升为顶层类型修复 nesting) |

### Wave 1.5 — 真实场景验证 (E=3, N=3 ✅)

**场景 1: JSON Round-Trip**
- 执行: `swift test --filter "testManifestRoundTrip|testManifestEncodeDecodeRoundTrip|testManifestRoundTripPreservesNilPreviewImage"`
- 输出: 3 tests passed, 0 failures — Manifest encode→decode round-trip 含 Optional nil/non-nil

**场景 2: BuiltIn URL 解析**
- 执行: `swift test --filter "testSkinPackBuiltIn"`
- 输出: 2 tests passed, 0 failures — CapturingBundle 验证 subdirectory 补 "Assets/" 前缀

**场景 3: Local URL 解析**
- 执行: `swift test --filter "testSkinPackLocal"`
- 输出: 3 tests passed, 0 failures — 文件存在→URL / 文件不存在→nil / 子目录不存在→nil

### Wave 2 — AI 审查

**Tier 2a 设计符合性**: ✅ PASS — 8/8 验证项全部通过
**Tier 2b 代码质量**: ✅ CONDITIONAL_PASS — 4 个 Minor 建议:
- M1: canvasSize [CGFloat] 缺语义约束（后续迭代可改进）
- M2: fileExists 可升级为 isReadableFile（皮肤安装场景）
- M3: 验收测试 decoder/encoder 计算属性风格不一致
- M4: 蓝队/红队测试有覆盖重叠（设计意图：独立验证）

### 总结: ✅ 全部通过

## 变更日志
- [2026-04-16T15:11:01Z] 用户批准验收，进入合并阶段
- [2026-04-16T14:48:09Z] autopilot 初始化（brief 模式），任务: 001-skin-types.md
- [2026-04-16T15:05:00Z] 设计方案通过审批，进入实现阶段
- [2026-04-16T15:10:00Z] 蓝队实现完成: SkinPackManifest.swift + SkinPack.swift + SkinPackTests.swift (11 tests)
- [2026-04-16T15:10:00Z] 红队验收测试完成: SkinPackAcceptanceTests.swift (23 tests)
- [2026-04-16T15:10:00Z] make build 通过, make test 254 tests 全绿 (含 34 SkinPack 测试)
- [2026-04-16T15:15:00Z] QA 全部通过: Tier 0 ✅ / Tier 1 ✅ / Tier 1.5 ✅ (3/3) / Tier 2a ✅ PASS / Tier 2b ✅ CONDITIONAL_PASS (4 Minor)
