---
id: "002-manifest-discriminated-union"
depends_on: []
complexity: M
acceptance_scenarios: [SC-4]
---

# Task 002: PluginManifest Codable 重构为 mode discriminated union

## 目标

把 `PluginManifest` 从"单一 stdin schema"重构为"mode discriminated union"（stdin + prompt 两 case），decode 时按顶层 `mode` 字段分发；缺 mode 字段默认 stdin（向后兼容）。同时让 `validate()` 函数 mode-aware（prompt mode 跳过 cmd 非空校验）。

## 架构上下文

来自 [`../design.md`](../design.md)：

- 现状：`PluginManifest` 是单 struct，所有字段（name/version/cmd/args/env/timeout 等）扁平 Codable
- 升级动机：prompt mode 插件无 cmd 字段，只有 systemPrompt + maxIterations + model；schema 必须区分 mode
- 选择 Swift enum 实现 discriminated union 是标准范式（参考 patterns.md AI 路由器条目同思路）

## 契约规约

### 新引入 contract

#### 1. PluginManifest 重构

```swift
struct PluginManifest: Codable {
    let name: String
    let version: String
    let description: String
    let keywords: [String]
    let timeout: Int?              // 共享字段，默认 30s
    let modeConfig: PluginModeConfig
    
    // Codable: decode 时按顶层 mode 字段分发
    // 缺 mode 字段 → 默认 stdin，从 root level 读 cmd/args/env/requiredPath
}

enum PluginModeConfig: Equatable {
    case stdin(StdinConfig)
    case prompt(PromptConfig)
}

struct StdinConfig: Codable, Equatable {
    let cmd: String              // 相对路径，禁绝对路径 / "/.."
    let args: [String]
    let env: [String: String]?
    let requiredPath: [String]?  // ≤10 项
}

struct PromptConfig: Codable, Equatable {
    let systemPrompt: String     // 必填，非空
    let maxIterations: Int       // 默认 1
    let model: String?           // nil = 用 launcher 激活 provider 的 model
}
```

#### 2. Codable decoder 行为

```swift
extension PluginManifest {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        version = try c.decode(String.self, forKey: .version)
        description = try c.decode(String.self, forKey: .description)
        keywords = try c.decode([String].self, forKey: .keywords)
        timeout = try c.decodeIfPresent(Int.self, forKey: .timeout)
        
        let mode = try c.decodeIfPresent(String.self, forKey: .mode) ?? "stdin"
        switch mode {
        case "stdin":
            let stdinCfg = try StdinConfig(from: decoder)  // 同一 decoder 读 root level
            modeConfig = .stdin(stdinCfg)
        case "prompt":
            let promptCfg = try PromptConfig(from: decoder)
            modeConfig = .prompt(promptCfg)
        default:
            throw LauncherError.pluginManifestInvalid("unknown mode: \(mode)")
        }
    }
}
```

#### 3. validate() mode-aware

```swift
extension PluginManifest {
    func validate(againstDirName dirName: String) throws {
        // 共享校验
        try validateName(againstDirName: dirName)
        try validateTimeout()
        
        // mode 分支
        switch modeConfig {
        case .stdin(let cfg):
            try cfg.validateCmd()           // cmd 非空 + 相对路径 + 无 "/.."
            try cfg.validateRequiredPath()
        case .prompt(let cfg):
            try cfg.validateSystemPrompt()  // 非空 + 长度 ≤ 8KB
            try cfg.validateMaxIterations() // ≥ 1, ≤ 10（防爆 token）
        }
    }
}
```

**关键**：prompt mode **不能**走 stdin 的 cmd 校验路径，否则 prompt 插件无法 load（此为 plan-reviewer D5 风险，必须作为本 task 第一个红队测试用例）。

### 修改但兼容的 contract

#### 4. plugin.json 文件格式

**新格式**（stdin，显式声明）：
```json
{
  "name": "builtin-hello",
  "version": "0.1.0",
  "description": "...",
  "keywords": [...],
  "timeout": 5,
  "mode": "stdin",
  "cmd": "./hello.sh",
  "args": [],
  "env": null,
  "requiredPath": null
}
```

**新格式**（prompt）：
```json
{
  "name": "builtin-translate",
  "version": "0.1.0",
  "description": "...",
  "keywords": [...],
  "timeout": 30,
  "mode": "prompt",
  "systemPrompt": "你是中英互译助手...",
  "maxIterations": 1,
  "model": null
}
```

**旧格式**（无 mode 字段，向后兼容）：
```json
{
  "name": "old-plugin",
  ...
  "cmd": "./run.sh",        // 默认走 stdin path
  ...
}
```

## 实现要点

1. **decode 容错**：缺 mode 字段时不报错，默认 stdin
2. **encode 输出**：encode 时永远写显式 mode 字段（不依赖默认）
3. **不动 PluginResult**：所有 executor 输出形态不变
4. **不动现有 cmd/args 字段语义**：StdinConfig 内的字段语义与原 PluginManifest 完全一致
5. **修改 builtin-hello/plugin.json**：加显式 `"mode": "stdin"` 字段（迁移示例，验证新 decoder 读新格式）

## 输入

- 现有 `Sources/.../Launcher/Plugin/PluginManifest.swift`
- 现有 `Sources/.../Plugins/HelloPlugin/plugin.json`

## 输出

- 重构后的 PluginManifest.swift（含 enum PluginModeConfig + StdinConfig + PromptConfig）
- 更新 HelloPlugin/plugin.json 加 `"mode": "stdin"` 字段
- 红队验收测试
- handoff `002-manifest-discriminated-union.handoff.md` 含：
  - Codable 结构图 + decoder 行为表
  - 向后兼容矩阵（旧格式 / 新 stdin / 新 prompt）
  - 下游须知：003 dispatcher / 005 trust / 006 translate plugin 使用方式

## 验收标准（红队测试候选）

### Tier 1 单元测试

1. **【第一优先】prompt mode 通过 validate()**：构造 prompt manifest（无 cmd 字段）→ validate() 不抛 cmd 校验异常
2. **stdin 显式 mode**：plugin.json 含 `"mode": "stdin"` → decode 为 .stdin case，cmd/args 正确
3. **旧格式向后兼容**：plugin.json 无 mode 字段 → decode 为 .stdin case（默认）
4. **prompt mode decode**：plugin.json `"mode": "prompt"` + systemPrompt → decode 为 .prompt case
5. **unknown mode 报错**：plugin.json `"mode": "agent"` → decode 抛 pluginManifestInvalid
6. **prompt mode 跨字段校验**：
   - systemPrompt 为空 → 抛 invalid
   - systemPrompt 超过 8KB → 抛 invalid
   - maxIterations < 1 或 > 10 → 抛 invalid
7. **stdin mode 校验保留**：现有 cmd 校验规则（相对路径、无 ".."、name=dirName）全部保留
8. **混合字段拒绝**：plugin.json 同时含 cmd 和 systemPrompt → decode 应只读 mode 对应字段，另一个忽略

### Tier 1.5 真实场景

9. **真实 builtin-hello 解析**：加 mode 字段后 `PluginManager.installBundledPlugins()` + `loadAll()` 仍能正确加载 hello plugin
10. **JSON encode round-trip**：encode 一个 prompt manifest → decode → 字段相等（Equatable）

## 已识别风险

- **现有 PluginManifest.validate() 强制 cmd 非空**（patterns.md `[2026-05-26]` 记录的恶意 manifest 校验）→ 必须 mode 分支跳过，第一个红队测试用例验证
- **JSON encoder 字段顺序**：Swift JSONEncoder 默认按 CodingKeys 顺序，不影响解析但影响 trustKey 一致性（005 task 应处理）

## 时间预估

1-2 小时

## QA scope（避免 SpriteKit 卡顿）

```bash
swift test --filter Manifest --filter PluginManager
# 或反向：swift test --skip Snapshot --skip CatSprite
```

完整 SpriteKit Snapshot 套件本 task 不涉及，跑全量会浪费 10 分钟。Tier 1.5 真实场景使用上述 filtered 命令。
