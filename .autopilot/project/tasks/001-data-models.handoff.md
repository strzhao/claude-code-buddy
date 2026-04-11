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
