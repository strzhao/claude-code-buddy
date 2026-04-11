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
brief_file: "/Users/stringzhao/workspace_sync/personal_projects/claude-code-buddy/.autopilot/project/tasks/001-data-models.md"
next_task: "002-session-manager"
auto_approve: false
task_dir: "/Users/stringzhao/workspace_sync/personal_projects/claude-code-buddy/.autopilot/requirements/20260412-001-data-models"
session_id: bee6fe5e-dc29-4fb4-8e95-9aedc420dd11
started_at: "2026-04-11T16:36:51Z"
---

## 目标
---
id: "001-data-models"
depends_on: []
---

## 目标

创建 Session Identity 功能的数据模型基础：SessionInfo 结构体、SessionColor 枚举，以及 HookMessage 的协议扩展。

## 架构上下文

当前 HookMessage 只有 sessionId/event/tool/timestamp 四个字段。SessionManager 仅用 `lastActivity: [String: Date]` 跟踪会话。本任务为后续所有任务提供数据模型基础。

## 关键实现细节

### SessionInfo (`Sources/ClaudeCodeBuddy/Session/SessionInfo.swift`)
```swift
struct SessionInfo {
    let sessionId: String
    var label: String          // 显示名称（默认 = cwd 最后路径组件）
    var color: SessionColor    // 分配的颜色
    var cwd: String?           // 工作目录
    var pid: Int?              // 进程 ID
    var state: CatState        // 当前状态
    var lastActivity: Date
}
```

### SessionColor (`Sources/ClaudeCodeBuddy/Session/SessionColor.swift`)
```swift
enum SessionColor: Int, CaseIterable {
    case coral, teal, gold, violet, mint, peach, sky, rose
    var hex: String { ... }       // e.g. "#FF6B6B"
    var nsColor: NSColor { ... }  // for SpriteKit tinting
    var ansi256: Int { ... }      // for terminal statusline
}
```

8 种颜色，匹配 max-8-cats 限制。

### HookMessage 扩展 (`Sources/ClaudeCodeBuddy/Network/HookMessage.swift`)
- 新增 `cwd: String?` 字段（CodingKeys 映射）
- 新增 `label: String?` 字段（CodingKeys 映射）
- HookEvent 新增 `case setLabel = "set_label"`
- `catState` 计算属性中 `.setLabel` 返回 `nil`（不改变猫状态，仅更新标签）

## 输入/输出契约

**输出给 002-session-manager：**
- SessionInfo 字段初始化契约：sessionId/color/lastActivity 由 SessionManager 赋值，cwd/label/pid 来自 hook 消息或文件扫描，state 由 HookEvent 驱动
- SessionColor.allCases 提供颜色池

**输出给 004-hook-script：**
- HookMessage 新增 cwd/label 字段的 JSON key 定义

## 验收标准

- [ ] `swift build` 编译通过
- [ ] SessionInfo 可用 sessionId + color + lastActivity 初始化
- [ ] SessionColor 有 8 个 case，每个都有 hex/nsColor/ansi256 属性
- [ ] HookMessage 能正确解码包含 cwd/label 的 JSON
- [ ] HookMessage 能正确解码不包含 cwd/label 的 JSON（向后兼容）
- [ ] HookEvent.setLabel 的 catState 返回 nil


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

**目标**：创建 SessionInfo、SessionColor 数据模型，扩展 HookMessage 协议支持 cwd/label/setLabel。

**技术方案**：
- SessionInfo 为普通 struct（非 Codable），由 SessionManager 内部构建
- SessionColor 为 Int-backed enum，携带 hex/nsColor/ansi256 计算属性
- HookMessage 扩展保持向后兼容：cwd 和 label 为 Optional

### 文件影响范围

| 文件 | 操作 | 说明 |
|------|------|------|
| `Sources/ClaudeCodeBuddy/Session/SessionInfo.swift` | 新建 | SessionInfo 结构体 |
| `Sources/ClaudeCodeBuddy/Session/SessionColor.swift` | 新建 | SessionColor 枚举 + 颜色定义 |
| `Sources/ClaudeCodeBuddy/Network/HookMessage.swift` | 修改 | 新增 cwd/label 字段 + setLabel 事件 |

## 实现计划

- [x] 1. 创建 `SessionColor.swift`（8 色枚举 + hex/nsColor/ansi256）
- [x] 2. 创建 `SessionInfo.swift`（struct: sessionId/label/color/cwd/pid/state/lastActivity）
- [x] 3. 修改 `HookMessage.swift`（cwd/label 字段 + setLabel 事件）
- [x] 4. 验证 `swift build` 编译通过

## 红队验收测试

文件：`tests/acceptance/test-data-models.sh`（11 项断言）
结果：11/11 PASS

回归测试：
- test-build.sh: 6/6 PASS
- test-hook-script.sh: 11/11 PASS

## QA 报告

### Wave 1: 编译 + 回归测试
| 项目 | 结果 | 证据 |
|------|------|------|
| swift build (debug) | ✅ | Build complete! (0.34s) |
| swift build (release) | ✅ | Build complete! (0.35s) |
| test-build.sh | ✅ 6/6 | 全部 PASS |
| test-hook-script.sh | ✅ 11/11 | 全部 PASS |
| test-session-start.sh | ✅ 7/7 | 全部 PASS |
| test-socket-protocol.sh | ✅ 12/12 | 全部 PASS |
| test-multi-session.sh | ✅ 10/10 | 全部 PASS |
| test-app-bundle.sh | ✅ 13/13 | 全部 PASS |

### Wave 1.5: 红队验收测试
| 项目 | 结果 | 证据 |
|------|------|------|
| test-data-models.sh | ✅ 11/11 | 全部 PASS |

### 总计：6 个测试套件，70 项断言，0 失败

## 变更日志
- [2026-04-11T16:47:16Z] 用户批准验收，进入合并阶段
- [2026-04-11T16:36:51Z] autopilot 初始化（brief 模式），任务: 001-data-models.md
- [2026-04-12T00:40:00Z] design 阶段完成，方案已通过审批，进入 implement 阶段
- [2026-04-12T00:45:00Z] implement 完成：蓝队创建 3 文件，红队测试 11/11 PASS，回归测试全通过，进入 qa
- [2026-04-12T00:48:00Z] QA 全部通过：6 套件 70 断言 0 失败，等待审批
- [2026-04-12T00:50:00Z] merge 完成：代码已提交 (4d6a331)，handoff 已写入，DAG 已更新，next_task=002-session-manager
