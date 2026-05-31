---
id: "004-disable-enable-mechanism"
depends_on: ["003"]
---

# Task 004 — 插件禁用/启用机制

## 目标（一句话）

PluginManager.list() 跳过含 `.disabled` 文件的目录；加 disable(name) / enable(name) 方法；红队覆盖：禁用后 router narrowCandidates 命中 0 候选，启用后恢复。

## 架构上下文

- 依赖 003（MarketplaceManager 已建立 ~/.buddy/launcher-plugins/ 结构）
- 本 task 仅改 PluginManager.list 和加新方法，零 UI 改动（task 005/007 暴露）

## 输入

- 现有 `PluginManager.list()` 实现
- 003 完成后的 `~/.buddy/launcher-plugins/<name>/` 结构

## 输出契约

### 修改 `Sources/ClaudeCodeBuddy/Launcher/Plugin/PluginManager.swift`

```swift
extension PluginManager {
    /// list() 内部加 .disabled 过滤
    /// 行为变化：扫描目录时若发现 .disabled 文件 → 跳过该目录
    /// 接口签名不变
    
    /// 标记插件禁用：在 ~/.buddy/launcher-plugins/<name>/.disabled 写空文件
    /// 已禁用：no-op（幂等）
    /// 插件不存在：throw LauncherError.pluginNotFound
    func disable(name: String) throws
    
    /// 启用插件：删除 .disabled 文件
    /// 已启用：no-op
    /// 插件不存在：throw
    func enable(name: String) throws
    
    /// 列出所有禁用插件（供 inspect / CLI 用）
    /// 注意：disabled 插件不会出现在 list()，所以单独扫描
    func disabledNames() throws -> [String]
}
```

### 修改 `MarketplaceManager.inspect()` (task 003 占位的 enabled 字段)

```swift
// 改为真实实现：
let disabledSet = Set((try? PluginManager.shared.disabledNames()) ?? [])
let enabled = !disabledSet.contains(pluginName)
```

## 验收标准

### 自动化测试（红队）

1. **disable 后 list 不返回**：建 fixture plugin，调 disable → list() 不含该 plugin
2. **disable + enable 恢复**：再 enable → list() 含该 plugin
3. **disable 不存在的 plugin**：throw pluginNotFound
4. **disable 幂等**：连续调 2 次 disable 不报错
5. **enable 未禁用的 plugin**：no-op
6. **disabledNames 返回准确**：disable A + B → disabledNames() = [A, B]（顺序不保证）
7. **router 集成**：禁用 translate → LauncherRouter.narrowCandidates("翻译 hello") → 返回空数组（因为 translate 不在 list 中）
8. **router 恢复**：启用 translate → narrowCandidates 重新命中

### 验证命令

```bash
cd apps/desktop && swift build && swift test --filter "PluginManager|Disable"
```

### Tier 1.5 真实场景

需 task 007 暴露 CLI 命令才能完整端到端验证；本 task Tier 1.5 用 Swift 直接调 API：

```swift
// 临时测试脚本（红队测试中模拟）
try PluginManager.shared.disable(name: "translate")
let list = try PluginManager.shared.list()
assert(!list.contains { $0.name == "translate" })
try PluginManager.shared.enable(name: "translate")
let list2 = try PluginManager.shared.list()
assert(list2.contains { $0.name == "translate" })
```

## 下游须知（handoff 要点）

- `.disabled` 是 0 字节空文件，存在即禁用
- 不要持久化到 marketplace.json（marketplace.json 是远程镜像，禁用状态是本地用户态）
- task 005/007 调 `disable/enable` 接口暴露 UI/CLI
