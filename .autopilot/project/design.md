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

### 7. colorBlendFactor 与动画兼容性
现有所有动画分支硬编码 `colorBlendFactor = 0`，003 必须将所有调用替换为读取 `sessionTintFactor` 属性。

### 8. AI 感知时序限制（已知限制）
首次 SessionStart 时颜色文件中尚无当前会话条目，AI 在第二条消息后才能获取准确信息。

## Handoff 策略

| 上游 → 下游 | 传递内容 |
|-------------|---------|
| 001 → 002 | SessionInfo 字段初始化契约：sessionId/color/lastActivity 由 SessionManager 赋值，cwd/label/pid 来自 hook 消息或文件扫描 |
| 002 → 003 | `addCat(info: SessionInfo)` 接口 + `updateCatLabel/Color` 方法 + `onSessionsChanged` 回调 |
| 002 → 007 | SessionInfo.label 在点击时实时读取 |
| 002 → 008 | `onSessionsChanged: (([SessionInfo]) -> Void)?` 回调传递完整会话快照 |
| 004 → 007 | Ghostty 标签页标题格式：`●{label}` |
| 005 → 006 | `onHover(sessionId: String?)`，BuddyScene 中转 |
| 005 → 007 | `onClick(sessionId: String)`，降级到 pid-based 激活 |
