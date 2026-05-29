---
id: "005-trust-mode-aware"
depends_on: ["002-manifest-discriminated-union"]
complexity: S
acceptance_scenarios: [SC-8, SC-9]
---

# Task 005: Trust 模型 mode-aware — trustKey 重设 + NSAlert 显示 prompt 摘要

## 目标

把 TOFU trust 模型从"单一 exe-bytes hash"升级为 mode-aware：stdin 保留现有 exe-bytes 算法（加 `stdin:` 前缀），prompt 用 manifest hash（`prompt:` + systemPrompt + maxIterations + model）。任一字段变化 → trustKey 变化 → NSAlert 重弹。NSAlert 文案对 prompt mode 显示 systemPrompt 摘要让用户审计。

## 架构上下文

来自 [`../design.md`](../design.md)：

- 现状：`TrustStore` + `trustKey = SHA256(cmd + args + sha256(executable_bytes))`（patterns.md `[2026-05-27]` TOFU 条目）
- 升级动机：prompt mode 无 executable，hash 必须基于 manifest 内容；mode 前缀防伪造
- 重要：已安装 stdin plugin 因加 mode 前缀会一次性重弹 alert（迁移成本，可接受）

## 契约规约

### 上游依赖（已完成）

- **task 002**：`PluginManifest.modeConfig` enum + `PromptConfig.systemPrompt` 已可用

### 修改的 contract

#### 1. trustKey 算法

```swift
func computeTrustKey(manifest: PluginManifest, pluginDir: URL) throws -> String {
    switch manifest.modeConfig {
    case .stdin(let cfg):
        let exeURL = pluginDir.appendingPathComponent(cfg.cmd)
        let exeBytes = try Data(contentsOf: exeURL)
        let exeHash = SHA256.hash(data: exeBytes).hexString
        let argsJoined = cfg.args.joined(separator: "|")
        let core = "\(cfg.cmd)|\(argsJoined)|\(exeHash)"
        return "stdin:" + SHA256.hash(data: Data(core.utf8)).hexString
        
    case .prompt(let cfg):
        let modelStr = cfg.model ?? "default"
        let core = "\(cfg.systemPrompt)|\(cfg.maxIterations)|\(modelStr)"
        return "prompt:" + SHA256.hash(data: Data(core.utf8)).hexString
    }
}
```

**关键不变量**：
- mode 前缀强制隔离（`prompt:X` ≠ `stdin:X`，无论 X 内容如何）
- prompt: systemPrompt 任一字符变化 → trustKey 变化 → NSAlert 重弹
- stdin: cmd/args/executable_bytes 任一变化 → trustKey 变化（现有行为保留）

#### 2. NSAlert 文案 mode-aware

```swift
func showTrustAlert(manifest: PluginManifest) async -> Bool {
    let alert = NSAlert()
    alert.messageText = "信任新插件：\(manifest.name)"
    
    switch manifest.modeConfig {
    case .stdin(let cfg):
        alert.informativeText = """
        模式: stdin（subprocess）
        命令: \(cfg.cmd) \(cfg.args.joined(separator: " "))
        描述: \(manifest.description)
        """
    case .prompt(let cfg):
        let summary = String(cfg.systemPrompt.prefix(200))
        let truncated = cfg.systemPrompt.count > 200 ? "...（共 \(cfg.systemPrompt.count) 字符）" : ""
        alert.informativeText = """
        模式: prompt（LLM 直接调用）
        模型: \(cfg.model ?? "用 launcher 当前激活 provider 的模型")
        描述: \(manifest.description)
        
        System Prompt 摘要:
        \(summary)\(truncated)
        """
    }
    
    alert.addButton(withTitle: "信任并继续")
    alert.addButton(withTitle: "拒绝")
    return alert.runModal() == .alertFirstButtonReturn
}
```

#### 3. TrustStore 文件 schema 不变

`~/.buddy/launcher-trust.json` 格式不变（仍是 `{plugin_name: trustKey}` 映射）。本 task 只改 trustKey 的**生成算法**，不改存储格式。

### 不变 contract

- TrustStore 协议接口不变（`isTrusted(name:trustKey:) -> Bool`, `trust(name:trustKey:)`）
- `~/.buddy/launcher-trust.json` 文件路径与权限不变（0644）

## 实现要点

1. **现有 stdin plugin 一次性迁移**：
   - 用户已安装的 stdin plugin（如 builtin-hello）首次跑会因 mode 前缀变化重新弹 alert
   - 这是**必要成本**，不能为兼容性绕开（否则恶意 plugin 改 mode 字段就能冒充 trust）
   - 在 brief / handoff / patterns.md 明确记录此点

2. **systemPrompt 摘要文案**：
   - 前 200 字 + "...（共 N 字符）" 提示
   - 让用户对 prompt 内容有基本审计能力（防恶意 prompt injection）

3. **mode 前缀字符串严格化**：
   - 使用 `"stdin:"` 和 `"prompt:"`（小写，无空格，含冒号）
   - 单元测试断言前缀格式（防误写为 `stdin_` 或 `Stdin:` 等变种）

4. **不动**：现有 TrustStore 协议接口 / 文件 schema / NSAlert 调用时机

## 输入

- task 002 输出的 PluginManifest + PluginModeConfig
- 现有 `Sources/.../Launcher/Plugin/TrustStore.swift`（或 trust 相关代码所在文件）
- 现有 `Sources/.../Launcher/Plugin/PluginManager.swift`（NSAlert 触发处）

## 输出

- 修改 trustKey 计算函数（mode-aware switch）
- 修改 NSAlert 文案 mode-aware（含 systemPrompt 摘要）
- 红队验收测试
- handoff `005-trust-mode-aware.handoff.md` 含：
  - trustKey 算法表（stdin vs prompt）
  - 一次性迁移说明（已装 stdin plugin 会重弹 alert 一次）
  - 下游须知：006 builtin-translate 首装时弹 prompt mode alert 的体验

## 验收标准（红队测试候选）

### Tier 1 单元测试

1. **stdin trustKey 含 `stdin:` 前缀**：computeTrustKey(stdin manifest) → 字符串以 "stdin:" 开头
2. **prompt trustKey 含 `prompt:` 前缀**：computeTrustKey(prompt manifest) → 字符串以 "prompt:" 开头
3. **mode 切换破坏 trust**：相同 manifest 内容但 mode 不同 → trustKey 完全不同（无字节重叠）
4. **stdin executable 变化**：相同 cmd/args，executable_bytes 不同 → trustKey 不同（保留现有行为）
5. **prompt systemPrompt 改一字符**（SC-9）：systemPrompt = "..." vs "...x" → trustKey 不同
6. **prompt model nil vs 显式**：model=nil vs model="default" → trustKey 不同（防误用）
7. **TrustStore 存储不变**：trust(name, trustKey) → isTrusted(name, trustKey) == true
8. **NSAlert prompt mode 文案**：mock NSAlert，验证 informativeText 含 "prompt" + systemPrompt 前 200 字 + "...（共 N 字符）"

### Tier 1.5 真实场景

9. **首装弹 alert**（SC-8）：删除 `~/.buddy/launcher-trust.json` 中 builtin-translate 记录 → 启动 app → 触发翻译插件 → NSAlert 弹出含 prompt mode 摘要
10. **systemPrompt 改动重弹**（SC-9）：修改 plugin.json 的 systemPrompt 一字符 → 重启 app → 触发翻译插件 → NSAlert 重弹（与上次内容不同）

## 已识别风险

- **现有 stdin plugin trust 失效**：用户的 builtin-hello 首跑会重新弹 alert。**必须**在 handoff 明确告知用户（CLAUDE.md / 发布 note 补充）
- **systemPrompt 包含敏感字符**（如反斜杠 / Unicode 控制符）→ NSAlert 文案可能显示异常。截取前 200 字时按 character 切（不是 byte），且替换控制字符为空格

## 时间预估

1-2 小时（算法 + alert 文案改动量小）

## QA scope（避免 SpriteKit 卡顿）

```bash
swift test --filter Trust --filter PluginManager
# 或反向：swift test --skip Snapshot --skip CatSprite
```

NSAlert 行为需 UI 跑（make run），其余单元 + 集成测试用 filter。
