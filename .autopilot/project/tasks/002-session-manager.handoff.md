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
