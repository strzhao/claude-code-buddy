# Buddy Launcher — 插件协议多 Mode 升级 + 首个 Prompt Mode 插件（翻译）

> 把 launcher 插件协议从"单一 subprocess"升级为"mode discriminated union"，借鉴 `~/workspace/claude-code/` 的 hook 模式（command/prompt/http/agent 4 种）。本轮落地 **stdin**（现有 cli 重命名）+ **prompt**（NEW，零代码声明式 LLM 插件），并实现首个 prompt mode 实例 `builtin-translate`。

## Context

**用户目标**：按照 launcher 社区化插件体系，做第一个翻译插件，强调"产品和交互式设计非常重要"。

**经过 brainstorm 澄清的真实需求**：

1. **不只是做一个翻译插件**，而是借此机会**升级 launcher 插件协议**为多 mode 架构（与 claude-code hook 模式对齐）
2. **翻译插件作为新协议的首个 prompt mode 实例**：零代码、纯声明（systemPrompt only），复用 launcher 当前激活的 provider（用户本地 Qwen at `127.0.0.1:8001`）
3. **agent 命名让出**：保留给未来"对齐 claude-code 的多轮 LLM loop + tools 完整 agent"实现；本轮做的单轮 LLM 调用称为 **prompt mode**

**核心约束**：
- 不破坏现有 stdin 模式（builtin-hello / 任何已发布的 community plugin）
- LauncherProvider 协议扩展不能破坏现有 send() 调用方（system 可选参数 + 默认 nil）
- Trust 体系必须覆盖 prompt mode 的 manifest hash 变化
- 翻译插件复用 launcher 激活的 provider，不引入新依赖

## 整体架构

```
                    ┌──────────────┐
                    │ Launcher UI  │
                    │ (NSPanel +   │
                    │  Markdown)   │
                    └──────┬───────┘
                           │ query string
                           ▼
                    ┌──────────────┐
                    │ LauncherRouter│  ← 现有，不动核心
                    │ keyword→AI    │     （仅 001 修迁移 user-prefix hack）
                    └──────┬───────┘
                           │ RouteDecision(.withPlugin(manifest))
                           ▼
                    ┌──────────────┐
                    │PluginDispatcher│ ← NEW (替代 PluginExecutor，003)
                    │  switch mode │
                    └──┬─────────┬─┘
                       │         │
        ┌──────────────┘         └──────────────┐
        ▼                                       ▼
┌─────────────────┐                    ┌─────────────────┐
│ StdinExecutor   │ ← 003 (保留现有)   │ PromptExecutor  │ ← NEW (004)
│ subprocess +    │                    │ provider.send + │
│ stdin/stdout    │                    │ system field    │
└─────────────────┘                    └────────┬────────┘
                                                │
                                                ▼
                                     ┌──────────────────┐
                                     │ LauncherProvider │ ← 协议扩展 (001)
                                     │  send(...,       │   加 system 字段
                                     │   system: ?)     │
                                     └──────────────────┘
                                                │
                                       ┌────────┴─────────┐
                                       ▼                  ▼
                                AnthropicProvider   OpenAICompatible
                                                          Provider
```

## 关键设计决策

### 决策 1：Manifest discriminated union schema（task 002）

```json
{
  "name": "builtin-translate",
  "version": "0.1.0",
  "description": "中英互译助手",
  "keywords": ["翻译", "translate", "tr"],
  "timeout": 30,
  "mode": "prompt",                    // 新增 discriminator
  
  // stdin mode 专属（mode=stdin 时存在）
  // "cmd": "...", "args": [], "env": {}, "requiredPath": []
  
  // prompt mode 专属（mode=prompt 时存在）
  "systemPrompt": "你是中英互译助手...",
  "maxIterations": 1,
  "model": null                        // null = 用 launcher 激活 provider 的 model
}
```

**Swift Codable 形状**：

```swift
struct PluginManifest: Codable {
    let name, version, description: String
    let keywords: [String]
    let timeout: Int?
    let modeConfig: PluginModeConfig
}

enum PluginModeConfig: Codable {
    case stdin(StdinConfig)
    case prompt(PromptConfig)
    // decode 时按顶层 "mode" 字段分发
}
```

**向后兼容**：缺失 mode 字段 → 默认 `mode: "stdin"`，从 root level 读 cmd/args/env。

### 决策 2：LauncherProvider 协议扩展 system 字段（task 001）

```swift
protocol LauncherProvider {
    func send(
        messages: [AgentMessage],
        tools: [AgentTool],
        model: String,
        system: String? = nil           // NEW
    ) async throws -> AgentResponse
}
```

- AnthropicProvider：`request.system = system`（Anthropic 原生字段）
- OpenAICompatibleProvider：`messages.prepend({role: "system", content: ...})`
- LauncherRouter.swift:75-91 的 user-message 前缀 hack 同时迁移到 system 参数

### 决策 3：Trust mode-aware（task 005）

```
stdin:  trustKey = SHA256("stdin:" + cmd + args + sha256(executable_bytes))
prompt: trustKey = SHA256("prompt:" + systemPrompt + maxIterations + (model ?? "default"))
```

- mode 前缀防止 mode 切换冒充（`prompt:X` ≠ `stdin:X`）
- prompt 任一字段变化 → trustKey 变化 → 重新弹 NSAlert

### 决策 4：PluginDispatcher 替代 PluginExecutor（task 003）

```swift
final class PluginDispatcher {
    let stdinExecutor: StdinExecutor       // 等价现有 PluginExecutor 内部逻辑
    let promptExecutor: PromptExecutor     // NEW
    
    func execute(manifest:query:sessionId:cwd:) async throws -> PluginResult {
        switch manifest.modeConfig {
        case .stdin: stdinExecutor.execute(...)
        case .prompt: promptExecutor.execute(...)
        }
    }
}
```

### 决策 5：PromptExecutor 单轮调用（task 004）

```swift
final class PromptExecutor {
    func execute(manifest: PluginManifest, query: String) async throws -> PluginResult {
        // 空 query 短路（验收 Scenario 5）
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return PluginResult(stdout: "请输入需要翻译的文字", ...)
        }
        
        let response = try await provider.send(
            messages: [user(query)],
            tools: [],
            model: config.model ?? activeProviderModel,
            system: config.systemPrompt
        )
        return PluginResult(stdout: response.text, ...)
    }
}
```

- 超时：用 `Task { ... }` + `task.cancel()` 模式（URLSession cancel 真正传播）
- 错误：provider 抛 → PluginResult exitCode=1 + stderr 描述 → UI "翻译失败: <错误>"

### 决策 6：builtin-translate 作为 SPM Bundle plugin（task 006）

部署在 `Sources/ClaudeCodeBuddy/Plugins/TranslatePlugin/plugin.json`（无可执行文件），与 builtin-hello 同等首次启动安装路径。`installBundledPlugins()` 扩展时对 prompt mode 跳过 chmod（无 sh 文件可改）。

systemPrompt：

```
你是一个专业的中英互译助手。

规则：
1. 检测输入语言：含中文字符 → 译为英文；纯英文/拉丁字符 → 译为中文
2. 输出仅包含译文本身，不要任何解释、引号、Markdown 格式
3. 保留原文的换行结构与标点风格
4. 对于专有名词、代码片段、URL，保持原样不译
5. 译文风格：日常流畅，避免机械直译；商务/技术文本保持正式
```

## 任务 DAG

详见 [`dag.yaml`](dag.yaml)。

**关键路径**：001 → 002 → 003 → 004 → 006（顺序 5 task）  
**可并行**：001 ∥ 002（互不依赖）；005 ∥ 003/004（仅依赖 002）

## 跨任务设计约束

### 共享 contract

1. **PluginManifest Codable 形状**（002 引入）：003/004/005/006 依赖此 schema。不允许绕过直接构造 mode-specific config
2. **PluginResult 不变**：所有 executor 输出统一为 PluginResult，便于上层渲染
3. **LauncherProvider.send 签名**（001 修改）：system 可选参数 + 默认 nil 保证现有调用方零改动
4. **trustKey 算法**（005 定义）：mode 前缀强制 + 子字段顺序固定

### 命名约定

- mode 字段值 `"stdin"` | `"prompt"`（小写，预留 `"agent"` / `"http"`）
- Executor 类名 `StdinExecutor` / `PromptExecutor`
- Manifest 字段 `systemPrompt`（驼峰）
- builtin plugin 前缀 `builtin-`

### 向后兼容矩阵

| 改动点 | 现有行为 | 新行为 | 兼容策略 |
|--------|----------|--------|----------|
| send() 调用方 | 3 参数 | 4 参数（system 可选） | 默认 nil，编译零改动 |
| plugin.json 解析 | root cmd/args | mode discriminated | 缺 mode 字段 = stdin |
| stdin plugin trustKey | exe-bytes hash | `stdin:` 前缀 + exe-bytes hash | mode 前缀变化重新弹 alert（一次性迁移） |

注：stdin plugin trustKey 加 `stdin:` 前缀会导致**已安装 stdin plugin** 重新弹 NSAlert 一次（一次性迁移成本，可接受）。005 brief 中明确此点。

### Handoff 策略

每个 task merge 阶段写 `tasks/00N-name.handoff.md`，含：
1. 实现摘要 1-2 段
2. 新引入的契约/接口（精确签名 + 文件路径 + 行号）
3. 下游须知（依赖此 task 的下游 task 实现时需注意什么）
4. 偏差说明（与 brief 不一致处 + 原因）

**关键 handoff 链**：

- 001 → 003/004/006：新 send 签名 + 默认 nil 兼容策略 + Router hack 迁移完成确认
- 002 → 003/004/005/006：PluginManifest 新 Codable 结构 + 向后兼容 decoder + mode-aware validate()
- 003 → 004/006：PluginDispatcher 接口 + StdinExecutor 与现有逻辑一致性
- 004 → 006：PromptExecutor 构造方法 + 错误码语义 + 空 query 行为
- 005 → 006：trustKey 计算函数签名 + NSAlert 显示 prompt mode 摘要的方式

## 验收场景覆盖

完整 SC 列表见 `state.md ## 验收场景`（10 个场景）。任务覆盖矩阵：

| SC | 主负责 task | 备注 |
|----|-------------|------|
| 1 中→英翻译 | 006 | 端到端，需 provider 启动 |
| 2 英→中翻译 | 006 | — |
| 3 混合符号 | 006 | systemPrompt 规则保障 |
| 4 路由分流 | 003 | dispatcher mode 分流 |
| 5 空输入兜底 | 004 | PromptExecutor 短路逻辑 |
| 6 超长输入 | 004 | provider 超时或截断 |
| 7 LLM 不可达 | 004 | exitCode=1 + stderr |
| 8 首次 NSAlert | 005 | TOFU mode-aware |
| 9 systemPrompt 改动重弹 | 005 | trustKey 变化 |
| 10 复制提示 | 006 | UI 反馈 |

## 已知风险与已识别陷阱

### 必须规避的陷阱

1. **OpenAICompatibleProvider system message 兼容性**：本地 Qwen 对首条 `role=system` 消息 schema 要求未验证 → task 001 必须实测（curl + Qwen 真实返回 200）
2. **withTimeout URLSession cancel 传播**：Swift 默认 `Task.sleep`-based timeout 不会取消 URLSession 任务 → task 004 用 `Task { provider.send() }` + `task.cancel()` 显式传播
3. **PluginManifest.validate() mode-aware**：现有 validate() 强制 cmd 非空 → task 002 必须加 mode 分支跳过 prompt mode 的 cmd 校验（红队首个测试用例）
4. **installBundledPlugins chmod**：现有逻辑对每个 bundled plugin 的 cmd 文件 chmod 0755 → task 006 对 prompt mode 跳过 chmod（无 sh 文件）

### 已在设计中处理的风险

- ✅ Trust 模型 mode 前缀防伪造
- ✅ Manifest 向后兼容（缺 mode = stdin）
- ✅ Provider 系统字段向后兼容（默认 nil）

## 时间预估

每个 task 1-2h autopilot 自动跑（含 design + implement + qa + auto-fix）。

总预估：6-12h 自动驾驶时间，跨多次 /autopilot next 调用完成。

## 知识沉淀候选（merge 阶段）

- **决策**：launcher plugin 协议从单一 stdin 升级为 mode discriminated union（与 claude-code hook 模式对齐）
- **模式**：Swift Codable enum 实现 discriminated union（decode 按 type 字段分发）的范式
- **模式**：prompt mode plugin trust 模型（manifest hash 而非 exe bytes）
- **决策**：LauncherProvider 协议 system 字段从可选扩展引入的兼容性策略
- **陷阱**：OpenAI 兼容服务对首条 role=system 消息的 schema 差异（task 001 验证后记录）
- **陷阱**：Swift withTimeout 对 URLSession 任务的 cancel 传播
