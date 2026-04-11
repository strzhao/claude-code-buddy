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
brief_file: "/Users/stringzhao/workspace_sync/personal_projects/claude-code-buddy/.autopilot/project/tasks/003-visual-layer.md"
next_task: "004-hook-script"
auto_approve: false
task_dir: "/Users/stringzhao/workspace_sync/personal_projects/claude-code-buddy/.autopilot/requirements/20260412-003-visual-layer"
session_id: bee6fe5e-dc29-4fb4-8e95-9aedc420dd11
started_at: "2026-04-11T17:00:31Z"
---

## 目标
---
id: "003-visual-layer"
depends_on: ["002-session-manager"]
---

## 目标

为 CatSprite 添加文字标签和颜色着色，使每只猫在视觉上可区分。

## 架构上下文

CatSprite 当前只有 SKSpriteNode 和动画逻辑，没有标签或颜色区分。BuddyScene.addCat 已被 002 改为接受 SessionInfo。

## 关键实现细节

### CatSprite 变更

**新属性：**
```swift
static let hitboxSize = CGSize(width: 48, height: 64) // 包含标签区域
private var labelNode: SKLabelNode?
private(set) var sessionColor: SessionColor?
private var sessionTintFactor: CGFloat = 0.3
```

**标签 SKLabelNode：**
- 作为 `node` 的子节点
- 位置：node 上方约 28px（`CGPoint(x: 0, y: 28)`）
- 字体：systemFont, 11px, bold
- 颜色：sessionColor.nsColor
- 阴影：`SKLabelNode` 不直接支持 shadow，用第二个 `SKLabelNode` 作为阴影层（offset 1px, alpha 0.4, blur 通过 `addGlowEffect` 实现）

**颜色着色：**
- 所有动画分支中的 `node.colorBlendFactor = 0` 替换为 `node.colorBlendFactor = sessionTintFactor`
- `node.color` 设置为 `sessionColor?.nsColor ?? .white`
- 影响的方法：`switchState(to:)`, `playIdleAnimation`, `runIdleSubState` 的所有分支, `enterScene`, `exitScene`

**新公开方法：**
```swift
func configure(color: SessionColor, label: String) // 初始化时调用
func updateLabel(_ label: String) // set_label 时调用
```

### BuddyScene 变更

**addCat(info:) 实现更新：**
```swift
func addCat(info: SessionInfo) {
    guard cats[info.sessionId] == nil else { return }
    if cats.count >= maxCats { evictIdleCat() }
    let cat = CatSprite(sessionId: info.sessionId)
    cat.configure(color: info.color, label: info.label)
    // ... 其余逻辑同现有
}
```

**新方法：**
```swift
func updateCatLabel(sessionId: String, label: String)
func updateCatColor(sessionId: String, color: SessionColor)
```

## 输入/输出契约

**输入来自 002：** SessionInfo（包含 color 和 label）通过 addCat(info:) 传入

**输出给 005：** CatSprite.hitboxSize 常量供 MouseTracker 使用，cat.node.position 供碰撞检测

## 验收标准

- [ ] `swift build` 编译通过
- [ ] 每只猫上方显示正确的标签文字
- [ ] 标签颜色与猫的 SessionColor 一致
- [ ] 猫精灵在所有动画状态下保持颜色着色（idle→thinking→coding→idle）
- [ ] updateLabel 能实时更新标签文字
- [ ] 无纹理模式下（placeholder）颜色直接设置为 sessionColor

--- handoff: 002-session-manager ---
# 002-session-manager Handoff

## 完成内容
- SessionManager 维护 `sessions: [String: SessionInfo]`
- 颜色池：8 色轮转分配/回收，`usedColors: Set<SessionColor>`
- cwd 富化：从 HookMessage.cwd 读取，标签自动从末路径组件生成
- `/tmp/claude-buddy-colors.json` 原子写入（write temp + rename）
- `onSessionsChanged: (([SessionInfo]) -> Void)?` 回调
- set_label 事件处理
- 启动时清空颜色文件
- BuddyScene.addCat(info: SessionInfo) 签名变更
- BuddyScene.updateCatLabel/updateCatColor stub（待 003 实现）

## 给下游任务的关键信息

### 003-visual-layer
- `addCat(info: SessionInfo)` 已就绪，info 包含 color 和 label
- `updateCatLabel(sessionId:label:)` 和 `updateCatColor(sessionId:color:)` 是 stub，003 需实现真正逻辑
- CatSprite 需要新增 `configure(color:label:)` 方法

### 007-terminal-adapter / 008-menu-dashboard
- `onSessionsChanged` 回调可用，传递 `[SessionInfo]` 快照
- SessionInfo.label 在 set_label 后实时更新

### 009-buddy-label
- set_label 事件已在 SessionManager 中处理
- 发送 `{"session_id":"...","event":"set_label","label":"新名称","timestamp":N}` 即可

## 颜色文件格式
```json
{"sessionId": {"color": "coral", "hex": "#FF6B6B", "label": "project-name"}}
```

## 文件路径
- `Sources/ClaudeCodeBuddy/Session/SessionManager.swift`
- `Sources/ClaudeCodeBuddy/Scene/BuddyScene.swift`


--- 架构设计摘要 ---
# Session Identity & Cat-Terminal Mapping — Architecture Design

## Context

Claude Code Buddy 是一个 macOS 菜单栏 SpriteKit 应用，在 Dock 上方显示像素猫动画，每只猫对应一个 Claude Code 会话。当前问题：同时运行 6-7 个会话时，用户无法区分哪只猫对应哪个终端窗口——没有标签、没有颜色区分、没有交互能力。

本项目实现设计规格文档 `docs/superpowers/specs/2026-04-11-session-identity-design.md` 中定义的 5 项能力：永久标签、颜色编码、悬停提示、点击激活、菜单栏仪表板。

## 系统概览

```
Claude Code Session
  → buddy-hook.sh（新增 cwd 提取 + Ghostty 标签页标题注入）
  → /tmp/claude-buddy.sock（JSON 新增 cwd/label 字段）
  → SocketServer → SessionManager（新增 SessionInfo 跟踪 + 颜色池）
  → BuddyScene / CatSprite（新增标签 SKLabelNode + 颜色着色）
  → MouseTracker（全局鼠标监控 → 悬停提示 / 点击激活）
  → 菜单栏 NSPopover（替代 NSMenu，显示会话列表）
  → /tmp/claude-buddy-colors.json（终端状态栏集成）
```

## 数据流变更

1. **入站消息扩展**：HookMessage 新增 `cwd: String?`、`label: String?` 字段，新增 `.setLabel` 事件
2. **会话元数据**：SessionManager 维护 `sessions: [String: SessionInfo]` 替代原有 `lastActivity: [String: Date]`
3. **颜色池**：SessionColor 8 色轮转分配，按 sessionId 键控（非索引），session 结束回收
4. **视觉层**：CatSprite 新增 SKLabelNode 子节点 + colorBlendFactor 着色
5. **交互层**：MouseTracker 全局事件监控 → BuddyWindow 动态穿透 → TooltipNode / GhosttyAdapter
6. **外部文件**：`/tmp/claude-buddy-colors.json` 原子写入，供终端状态栏脚本读取

## 关键技术决策

| 决策 | 选择 | 理由 |
|------|------|------|
| 提示信息渲染 | SKNode 子树（非 NSPopover） | 避免窗口焦点问题，保持 SpriteKit 一致性 |
| 鼠标检测 | NSEvent 全局监控 | 不需要 Accessibility 权限，配合 ignoresMouseEvents 动态切换 |
| 颜色分配 | 按 sessionId 键控 | 避免重连后颜色变化 |
| 终端激活 | AppleScript + ●label 标记 | Ghostty 原生支持 set_tab_title action |
| 颜色文件写入 | 原子写入（write temp + rename） | 避免 hook 脚本读到部分文件 |
| 菜单栏 | NSPopover 替代 NSMenu | 支持自定义视图（颜色点、可点击行） |

## 跨任务设计约束

### 1. 线程安全不变量
所有 SessionInfo 访问都在主线程上。任何任务都不得从后台队列访问 `sessions` 字典。

### 2. 猫精灵碰撞箱常量
hitbox 固定为 48x64，定义在 CatSprite 上作为 `static let hitboxSize`。

### 3. ignoresMouseEvents 重置保证
BuddyWindow 在鼠标离开碰撞箱 200ms 后、60s 超时检查时、应用进入后台时强制 `ignoresMouseEvents = true`。

### 4. 颜色文件原子写入
`/tmp/claude-buddy-colors.json` 通过 write-to-temp + rename 模式写入，每次都是完整快照。

### 5. BuddyScene.addCat 签名变更
002 将 `addCat(sessionId:)` 直接改为 `addCat(info: SessionInfo)`，一次性切换，同步更新 SessionManager 调用点。

### 6. .setLabel 在 001 中定义
`.setLabel` 在数据模型任务中就加入 HookEvent enum。


## 设计文档

**目标**：CatSprite 添加 SKLabelNode 标签 + colorBlendFactor 着色

### 文件
- CatSprite.swift — hitboxSize、labelNode、sessionColor、configure()、updateLabel()、8 处 tintFactor 替换
- BuddyScene.swift — configure 调用 + updateCatLabel 实现

## 实现计划

- [x] 1-4. CatSprite 属性、configure、updateLabel、8 处 tintFactor
- [x] 5. BuddyScene configure 调用 + stub 实现
- [x] 6. swift build + 测试验证

## 红队验收测试

test-visual-layer.sh: 11/11 PASS
回归 run-all.sh: 6/6 套件 PASS

## QA 报告

红队 11/11 + 回归 6 套件全通过，0 失败

## 变更日志
- [2026-04-11T17:09:59Z] 用户批准验收，进入合并阶段
- [2026-04-11T17:00:31Z] autopilot 初始化（brief 模式），任务: 003-visual-layer.md
- [2026-04-12T01:15:00Z] design→implement→qa 完成，11/11 + 回归全通过，等待审批
- [2026-04-12T01:20:00Z] merge 完成：代码已提交 (886622b)，DAG 更新，next_task=004-hook-script
