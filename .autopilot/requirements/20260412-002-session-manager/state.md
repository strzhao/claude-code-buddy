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
brief_file: "/Users/stringzhao/workspace_sync/personal_projects/claude-code-buddy/.autopilot/project/tasks/002-session-manager.md"
next_task: "003-visual-layer"
auto_approve: false
task_dir: "/Users/stringzhao/workspace_sync/personal_projects/claude-code-buddy/.autopilot/requirements/20260412-002-session-manager"
session_id: bee6fe5e-dc29-4fb4-8e95-9aedc420dd11
started_at: "2026-04-11T16:49:19Z"
---

## 目标
---
id: "002-session-manager"
depends_on: ["001-data-models"]
---

## 目标

将 SessionManager 从简单的 lastActivity 跟踪升级为完整的 SessionInfo 管理器，包括颜色池分配、cwd 富化、颜色文件写入和新的回调接口。

## 架构上下文

当前 SessionManager 只维护 `lastActivity: [String: Date]`。升级后维护 `sessions: [String: SessionInfo]`，管理颜色池，写入共享颜色文件。

## 关键实现细节

### sessions 字典
替换 `lastActivity: [String: Date]` 为 `private var sessions: [String: SessionInfo] = [:]`

### 颜色池
```swift
private var usedColors: Set<SessionColor> = []

private func assignColor() -> SessionColor {
    for color in SessionColor.allCases {
        if !usedColors.contains(color) {
            usedColors.insert(color)
            return color
        }
    }
    return SessionColor.allCases[0] // fallback
}

private func releaseColor(_ color: SessionColor) {
    usedColors.remove(color)
}
```

### cwd 富化
1. 主路径：从 HookMessage.cwd 字段读取（hook 脚本在第一条消息中携带）
2. 降级路径：扫描 `~/.claude/sessions/*.json` 匹配 sessionId，提取 cwd 和 pid
3. 每个 session 最多扫描一次

### 标签自动生成
```swift
private func generateLabel(from cwd: String?) -> String {
    guard let cwd = cwd else { return "claude" }
    let base = (cwd as NSString).lastPathComponent
    // 消歧：如果已有同名标签，追加序号
    let existing = sessions.values.filter { $0.label == base }.count
    return existing > 0 ? "\(base)②" : base  // 可用更多 circled digits
}
```

### 颜色文件写入
路径：`/tmp/claude-buddy-colors.json`
原子写入：write to temp + rename
格式：`{"session_id": {"color": "coral", "hex": "#FF6B6B", "label": "buddy"}}`
触发时机：每次 session 创建/移除/标签更新后

### 回调变更
保留 `onSessionCountChanged: ((Int) -> Void)?`
新增 `onSessionsChanged: (([SessionInfo]) -> Void)?`

### BuddyScene 接口变更
`addCat(sessionId:)` → `addCat(info: SessionInfo)`（一次性切换）
同步更新 handle(message:) 中的调用

### set_label 处理
```swift
case .setLabel:
    if let label = message.label, let session = sessions[sessionId] {
        sessions[sessionId]?.label = label
        scene.updateCatLabel(sessionId: sessionId, label: label)
        writeColorFile()
        onSessionsChanged?(Array(sessions.values))
    }
```

### 启动时清理
`start()` 方法中首先清空 `/tmp/claude-buddy-colors.json`（写入空 `{}`）

## 输入/输出契约

**输入来自 001：** SessionInfo, SessionColor, HookMessage 扩展

**输出给 003：** `addCat(info: SessionInfo)` 接口 + `updateCatLabel(sessionId:label:)` + `updateCatColor(sessionId:color:)`

**输出给 007/008：** SessionInfo 实时数据通过 `onSessionsChanged` 回调

## 验收标准

- [ ] `swift build` 编译通过
- [ ] 新会话创建时分配唯一颜色
- [ ] 会话结束时回收颜色
- [ ] 颜色文件在每次变更后原子更新
- [ ] 应用启动时清空颜色文件
- [ ] 无 cwd 的消息降级处理（标签显示 "claude"）
- [ ] set_label 事件正确更新 label 并触发回调
- [ ] 超时逻辑使用 SessionInfo.lastActivity 而非独立 dict

--- handoff: 001-data-models ---
# 001-data-models Handoff

## 完成内容
- `SessionColor` 枚举：8 色 (coral/teal/gold/violet/mint/peach/sky/rose)，含 hex/nsColor/ansi256
- `SessionInfo` 结构体：sessionId/label/color/cwd/pid/state/lastActivity
- `HookMessage` 扩展：cwd/label Optional 字段 + setLabel 事件

## 给下游任务的关键信息

### 002-session-manager
- SessionInfo 字段初始化契约：sessionId/color/lastActivity 由 SessionManager 赋值，cwd/label/pid 来自 hook 消息
- SessionColor.allCases 提供 8 色颜色池
- HookEvent.setLabel 的 catState 返回 nil，SessionManager 需单独处理标签更新逻辑

### 004-hook-script
- HookMessage 新增 cwd (String?) 和 label (String?) 字段
- JSON 格式：`{"session_id":"...","event":"set_label","label":"...","timestamp":N}`
- cwd 字段：`{"session_id":"...","event":"session_start","cwd":"/path/to/dir","timestamp":N}`

## 文件路径
- `Sources/ClaudeCodeBuddy/Session/SessionColor.swift`
- `Sources/ClaudeCodeBuddy/Session/SessionInfo.swift`
- `Sources/ClaudeCodeBuddy/Network/HookMessage.swift`


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

**目标**：SessionManager 维护 `[String: SessionInfo]` 替代 `[String: Date]`，管理颜色池、cwd 富化、颜色文件、新回调接口。

### 文件影响范围
| 文件 | 操作 |
|------|------|
| `SessionManager.swift` | 重写 |
| `BuddyScene.swift` | 签名变更 + stub |

## 实现计划

- [x] 1. SessionManager sessions dict + 颜色池
- [x] 2. handle(message:) + cwd 富化 + 标签 + setLabel
- [x] 3. 超时逻辑 + 颜色回收
- [x] 4. 颜色文件 + onSessionsChanged
- [x] 5. BuddyScene addCat(info:) + stubs
- [x] 6. swift build + 测试验证

## 红队验收测试

文件：`tests/acceptance/test-session-manager.sh`（12 项断言）
结果：12/12 PASS

回归测试（run-all.sh）：6 套件全部 PASS

## QA 报告

### Wave 1: 编译 + 回归
| 项目 | 结果 |
|------|------|
| swift build (debug) | ✅ |
| swift build (release) | ✅ |
| run-all.sh (6 套件) | ✅ 全部 PASS |

### Wave 1.5: 红队验收
| 项目 | 结果 |
|------|------|
| test-session-manager.sh | ✅ 12/12 |

### 总计：7 个套件，82+ 断言，0 失败

## 变更日志
- [2026-04-11T16:56:23Z] 用户批准验收，进入合并阶段
- [2026-04-11T16:49:19Z] autopilot 初始化（brief 模式），任务: 002-session-manager.md
- [2026-04-12T00:55:00Z] design 完成，进入 implement
- [2026-04-12T01:00:00Z] implement 完成：蓝队重写 SessionManager+BuddyScene，红队 12/12 PASS，回归全通过，等待审批
- [2026-04-12T01:05:00Z] merge 完成：代码已提交 (dcabe13)，handoff 已写入，DAG 已更新，next_task=003-visual-layer
