# Buddy Launcher — Alfred 式 AI 启动器子系统

> 在 claude-code-buddy macOS 应用内新增独立的启动器子系统（⌘⇧Space 浮窗 + AI 路由 + CLI 插件），与现有像素猫互不干扰。完整设计参考 `~/Downloads/prd.txt` 的 Genie 11 项决策（适配 Swift 技术栈）。

## Context

**用户目标**：复用 buddy menu bar app 的 LSUIElement / SocketServer / 打包链路，避免另起一个独立应用，把"召之即来的 AI 助手"和"像素猫陪伴"集成在同一个 app 里。

**核心约束**：MVP 严格匹配 PRD 7 项闭环（仅快捷键+浮窗、CLI 插件原子、plugin.json+README 发现、BYOK provider、永远 loop 早停、Git URL 去中心分发、TOFU 权限）；不做权限矩阵 / 持久会话 / 上下文压缩 / topic search / 跨平台。

## 整体架构设计

### 系统概览

```
┌──────────────────────────────────────────────────────────────────┐
│  claude-code-buddy App                                           │
│  ┌────────────────────┐    ┌──────────────────────────────────┐  │
│  │ 像素猫子系统（不动） │    │  Launcher 子系统（新增）          │  │
│  │ BuddyWindow/Scene  │    │  ┌────────────────────────────┐  │  │
│  │ CatSprite          │    │  │ LauncherWindow (NSPanel)   │  │  │
│  │ SessionManager     │    │  └────────────┬───────────────┘  │  │
│  │ SocketServer       │    │  ┌────────────▼───────────────┐  │  │
│  │ MenuBar Popover    │    │  │ LauncherInputView          │  │  │
│  └────────────────────┘    │  │  (SwiftUI + NSHosting)     │  │  │
│                            │  └────────────┬───────────────┘  │  │
│  ┌────────────────────┐    │  ┌────────────▼───────────────┐  │  │
│  │ AppDelegate        │────┼─→│ LauncherManager            │  │  │
│  │ +setupLauncher()  │    │  │  Router → Agent → Provider  │  │  │
│  └────────────────────┘    │  │  + PluginManager+TrustStore │  │  │
│                            │  └─────────────────────────────┘  │  │
└──────────────────────────────────────────────────────────────────┘
                                          │
                                          ▼
       ┌─────────────────────────────────────────────────────────┐
       │  ~/.buddy/launcher.json / launcher-trust.json           │
       │  ~/.buddy/launcher-plugins/<user>-<repo>/               │
       │   ├─ plugin.json   └─ README.md  └─ <executable>        │
       │  Keychain 或 EncryptedFile (CryptoKit) 存 API key        │
       └─────────────────────────────────────────────────────────┘
                                          │
                                          ▼
       CLI 子进程（任意语言）
        stdin = JSON {query, sessionId, cwd}
        stdout = markdown / stderr = log / exit code / 30s timeout
```

### 关键技术决策

| 决策 | 选定 | 理由 |
|---|---|---|
| 窗口类型 | 新建独立 NSPanel + canBecomeKey override | BuddyWindow `ignoresMouseEvents=true` + borderless 用于点击穿透，不能用于输入；NSPanel 是浮窗输入框标准选择 |
| UI 框架 | SwiftUI + NSHostingController | 启动器表单+列表+markdown 用 SwiftUI 大幅减少代码量 |
| 全局快捷键 | sindresorhus/KeyboardShortcuts SPM | 自带录制 UI + 持久化 + 冲突检测；零冲突风险 |
| 默认快捷键 | ⌘⇧Space | Spotlight 占用 ⌘Space；Raycast/Hammerspoon 业界惯例；Xcode 默认 "Show Documentation" 占用同 combo，task 001 需做探针引导改键 |
| Agent 引擎 | Swift 翻译 learn-everything v1 76 行 | 简单到能 review 全文；URLSession async/await + Codable 足够 |
| Provider 抽象 | Anthropic-native + OpenAI 兼容 | OpenAI 协议覆盖 80% 本地推理引擎（Ollama/Qwen/DeepSeek） |
| API key 存储 | 可插拔 SecretStore：Keychain → EncryptedFile 降级 | `bundle.sh:56` 用 ad-hoc 签名+无 entitlements，macOS 13+ 下 `SecItemAdd` 报 `errSecMissingEntitlement(-34018)`；必须探针 + 自动降级 |
| 配置/插件目录 | `~/.buddy/` | 用户可手编辑、可 dotfile 同步 |
| 插件协议 | stdin=JSON / stdout=markdown / timeout≤30s / exit code | JSON 可扩展不破协议；markdown 是 LLM 母语 |
| 插件 PATH 注入 | `/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$PATH` | LSUIElement app 默认 PATH 仅 `/usr/bin:/bin`，plugin 调 git/python/node 会失败；PluginManifest 含 `requiredPath` 字段预检查 |
| 插件安装 | `buddy launcher add <user/repo>` → git clone | 零依赖；扩展 BuddyCLI 用 nested switch（**不**引入 swift-argument-parser，main.swift 已 841 行 raw CommandLine） |
| TOFU 信任键 | SHA256(plugin.json.cmd + args.joined() + executableHash) | 防止作者改 cmd/args 绕过；executable hash 防二进制替换 |
| 会话 | 每次唤起新 messages 数组 | PRD 决策 11 |
| Markdown 渲染 | `AttributedString(markdown:)` macOS 12+ | 0 依赖 |

### 文件落点

```
apps/desktop/Sources/ClaudeCodeBuddy/Launcher/  (新建)
├── LauncherManager.swift
├── LauncherWindow.swift
├── LauncherInputView.swift
├── LauncherHostingController.swift
├── LauncherHotkey.swift
├── LauncherRouter.swift
├── Agent/{LauncherAgent,AgentMessage,AgentEvent}.swift
├── Provider/{LauncherProvider,AnthropicProvider,OpenAICompatibleProvider}.swift
├── Plugin/{PluginManifest,PluginManager,PluginExecutor,TrustStore}.swift
├── Config/{LauncherConfig,SecretStore,KeychainSecretStore,EncryptedFileSecretStore}.swift
└── LauncherConstants.swift

apps/desktop/Package.swift  (新增依赖)
+ .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", from: "2.0.0")

apps/desktop/Sources/BuddyCLI/main.swift  (单文件 nested switch 扩展)
+ case "launcher": handleLauncher(args)  // add/list/remove/config/inspect

apps/desktop/Sources/ClaudeCodeBuddy/App/AppDelegate.swift
+ setupLauncher()  // 接入点，单行追加
```

## 任务 DAG

详见 `dag.yaml`，简要：

```
001-launcher-skeleton  (M)  ── no deps
   ↓
002-provider-abstraction (M)
   ↓
003-agent-loop (M)              004-plugin-runtime (M, deps:001)
       \                         /
        005-routing (M)
                |
                +─→ 007-e2e-and-docs (S, deps:005,006)
                |
006-install-and-tofu (M, deps:004)
```

## 跨任务设计约束

- 命名：`Launcher` 前缀；目录 `apps/desktop/Sources/ClaudeCodeBuddy/Launcher/`
- 测试：`<Module>Tests.swift` 单元；`<Module>.acceptance.test.swift` 红队验收；`<Module>SnapshotTests.swift` 窗口快照
- 错误：所有 async throws 用 `LauncherError` enum，UI 层 SwiftUI Alert，**不要 fatalError**
- 子进程超时：30s SIGTERM → +5s SIGKILL
- 不动现有像素猫代码：BuddyWindow/Scene/CatSprite/SessionManager/SocketServer 等
- AppDelegate 仅追加 `setupLauncher()` 一行
- 配置目录 `~/.buddy/` 启动时若不存在则创建；权限 0600（key）/ 0644（manifest/trust）

## 契约规约（项目级）

> 跨任务共享接口形状的权威。每个子任务 brief 继承本契约 + 内部细化。

### LauncherProvider（task 002 定义，003/005 消费）

```swift
protocol LauncherProvider {
    func send(
        messages: [AgentMessage],
        tools: [AgentTool],
        model: String
    ) async throws -> AgentResponse
}

struct AgentResponse: Codable {
    let content: [AgentContent]   // 含 text 和 tool_use 混合
    let stopReason: String         // "tool_use" / "end_turn" / "max_tokens"
    let usage: AgentUsage?
}

enum AgentContent: Codable {
    case text(String)
    case toolUse(id: String, name: String, input: [String: AnyCodable])
}
```

### LauncherAgent（task 003 定义，005 消费）

```swift
func run(prompt: String, tools: [AgentTool], systemPrompt: String?) -> AsyncStream<AgentEvent>

enum AgentEvent {
    case text(String)              // 增量 markdown 片段
    case toolCall(name: String, input: [String: AnyCodable])
    case toolResult(name: String, output: String)
    case done
    case error(LauncherError)
}
```

### PluginManifest / PluginManager（task 004 定义，005/006 消费）

```swift
struct PluginManifest: Codable {
    let name: String              // 必须匹配目录名最后一段
    let version: String
    let description: String
    let keywords: [String]
    let cmd: String               // plugin 目录内相对路径
    let args: [String]
    let env: [String: String]?
    let timeout: Int?             // 秒，缺省 30，上限 120
    let requiredPath: [String]?   // 预检查外部 binary
}

func PluginManager.list() throws -> [PluginManifest]

struct PluginInput: Codable { let query, sessionId, cwd: String }

struct PluginResult {
    let stdout, stderr: String
    let exitCode: Int32
    let durationMs: Int
}

func PluginManager.execute(_ plugin: PluginManifest, input: PluginInput) async throws -> PluginResult
```

### 边界值（DbC）

- Agent loop 最大迭代：≤ 10
- Provider HTTP 超时：≤ 120s
- Plugin 子进程超时：≤ 30s（manifest 可改但 ≤ 120s）
- Plugin stdout 最大读取：≤ 1 MiB（超过截断 + 警告）
- API key 长度：≥ 8 字符
- 路由候选数量：≤ 5
- 输入框最大输入：≤ 8000 字符

### 错误码（LauncherError）

| 错误码 | 触发 |
|---|---|
| `providerNotConfigured` | 无 provider 配置 |
| `invalidAPIKey` | Keychain/EncryptedFile 无 key |
| `networkFailure(Error)` | URLSession 错误 |
| `providerHTTPError(Int, String)` | 4xx/5xx |
| `pluginNotFound(String)` | 路由选中插件不存在 |
| `pluginNotTrusted(String)` | TOFU 未通过 |
| `pluginTimeout(Int)` | 子进程超时 |
| `pluginCrash(Int32, String)` | exit code 非 0 |
| `pluginMissingDependency(String)` | requiredPath binary 不存在 |
| `maxIterations` | Agent loop > 10 |
| `secretStoreUnavailable` | Keychain 失败且 EncryptedFile 不可写 |
| `hotkeyConflict(String)` | 快捷键注册失败 |

## Handoff 策略

每个 task merge 阶段写 `tasks/<id>.handoff.md`，含：实现的接口签名 + 关键文件路径 + 配置增量 + 已知限制 + 下游接入示例（最小 3 行代码）。

## 风险与缓解

| 风险 | 概率/影响 | 缓解 |
|---|---|---|
| KeyboardShortcuts SPM 冲突 | 低/中 | task 001 单独验证 SPM resolve |
| NSPanel canBecomeKey 在 LSUIElement 异常 | 中/高 | task 001 优先验证 |
| Ollama OpenAI 兼容协议字段差异 | 中/中 | task 002 用 qwen2.5 实测 + Quirks 文档 |
| 子进程 stdin/stdout buffering | 中/中 | task 004 用 Pipe + readDataToEndOfFile |
| NSAlert 在浮窗下卡 | 低/中 | task 006 测试 modal 共存，fallback SwiftUI Alert |
| 流式 markdown 代码块未闭合 | 中/低 | task 003 增量累积 buffer，done 才最终渲染 |
| **Keychain ad-hoc 签名失效** | 高/高 | task 002 SecretStore 探针自动降级 EncryptedFile |
| **⌘⇧Space 与 Xcode 冲突** | 高/中 | task 001 探针失败弹录制 UI |
| **子进程 PATH 无 Homebrew** | 高/高 | task 004 注入扩展 PATH + manifest.requiredPath 预检查 |

## 关联

完整 design / contract / 12 验收场景在状态文件：
`.autopilot/runtime/requirements/20260525-新增类似-alfred-这样的/state.md`
