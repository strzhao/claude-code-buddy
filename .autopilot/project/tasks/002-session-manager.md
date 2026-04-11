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
