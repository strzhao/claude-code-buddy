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
brief_file: "/Users/stringzhao/workspace_sync/personal_projects/claude-code-buddy/.autopilot/project/tasks/004-hook-script.md"
next_task: ""
auto_approve: false
task_dir: "/Users/stringzhao/workspace_sync/personal_projects/claude-code-buddy/.autopilot/requirements/20260412-004-hook-script"
session_id: bee6fe5e-dc29-4fb4-8e95-9aedc420dd11
started_at: "2026-04-11T17:12:20Z"
---

## 目标
---
id: "004-hook-script"
depends_on: ["001-data-models"]
---

## 目标

增强 hook 脚本以提取 cwd 并在首次消息中发送，同时注入 Ghostty 标签页标题。

## 架构上下文

当前 buddy-hook.sh 从 Claude Code stdin JSON 提取 hook_event_name, session_id, tool_name。需要新增 cwd 提取和 Ghostty 标签页标题注入。

需要同步修改两份文件（内容完全相同）：
- `hooks/buddy-hook.sh`
- `plugin/scripts/buddy-hook.sh`

## 关键实现细节

### cwd 提取

Claude Code 的 stdin JSON 中包含项目路径信息。在 Python 解析部分新增：
```python
cwd = d.get('cwd', '') or d.get('project_path', '')
print(f'CWD="{cwd}"')
```

### 首次消息 cwd 携带

JSON 消息新增 cwd 字段（仅在 SessionStart 时或首次消息时携带）：
```bash
if [ "$EVENT" = "session_start" ] && [ -n "$CWD" ]; then
    CWD_JSON=",\"cwd\":\"${CWD}\""
else
    CWD_JSON=""
fi
JSON="{\"session_id\":\"${SESSION_ID}\",\"event\":\"${EVENT}\",\"tool\":${TOOL_JSON},\"timestamp\":${TIMESTAMP}${CWD_JSON}}"
```

### Ghostty 标签页标题注入

在 SessionStart 事件时异步设置 Ghostty 标签页标题：
```bash
if [ "$EVENT" = "session_start" ] && [ -n "$CWD" ]; then
    LABEL="$(basename "$CWD")"
    osascript -e "
      tell application \"Ghostty\"
        repeat with t in terminals of every tab of every window
          if working directory of t is \"$CWD\" and name of t does not contain \"●\" then
            perform action \"set_tab_title:●${LABEL}\" on t
            return
          end if
        end repeat
      end tell
    " &>/dev/null &
fi
```

`&` 确保异步执行，不阻塞 hook 返回。

## 输入/输出契约

**输入来自 001：** HookMessage JSON 格式（cwd 字段定义）

**输出给 007：** Ghostty 标签页标题格式约定 `●{label}`

**输出给 009/010：** hook 脚本结构（新事件、新字段的添加模式）

## 验收标准

- [ ] hooks/buddy-hook.sh 和 plugin/scripts/buddy-hook.sh 内容一致
- [ ] SessionStart 消息包含 cwd 字段
- [ ] 非 SessionStart 消息不包含 cwd 字段
- [ ] 无 cwd 可用时优雅降级（不崩溃，不包含空 cwd）
- [ ] Ghostty 标签页标题异步设置，不阻塞 hook 返回
- [ ] 现有测试 test-hook-script.sh 仍通过

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

修改 buddy-hook.sh：cwd 提取 + SessionStart 时 cwd JSON 字段 + Ghostty 标签页标题异步注入。两份文件同步。

## 实现计划

- [ ] 1. 修改 hooks/buddy-hook.sh（cwd 提取 + cwd JSON + Ghostty 注入）
- [ ] 2. 同步 plugin/scripts/buddy-hook.sh
- [ ] 3. 验证现有测试通过

## 红队验收测试
(待 implement 阶段填充)

## QA 报告
(待 qa 阶段填充)

## 变更日志
- [2026-04-11T17:12:20Z] autopilot 初始化（brief 模式），任务: 004-hook-script.md
