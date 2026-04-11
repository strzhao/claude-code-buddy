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
