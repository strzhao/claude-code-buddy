---
id: "002-provider-abstraction"
depends_on: ["001-launcher-skeleton"]
complexity: M
milestone: M2
acceptance_scenarios: [SC-02, SC-07, SC-12]
contract_required: true
---

# 002 — Provider 抽象 + BYOK 配置 + SecretStore 探针降级

## 目标

实现 LauncherProvider 协议 + 两个具体实现（Anthropic-native / OpenAI 兼容），SecretStore 探针降级机制（Keychain → EncryptedFile），配置文件 `~/.buddy/launcher.json` 读写，CLI 配置子命令。本任务**不**做 agent loop（留给 003），但跑通"发一条 message 拿到一条 response"。

## 架构上下文

- 文件：`Launcher/Provider/` + `Launcher/Config/`
- `bundle.sh:56` 用 ad-hoc 签名（`-s -`），无 `.entitlements`，macOS 13+ 下 `SecItemAdd` 报 `errSecMissingEntitlement(-34018)`，**必须**探针 + 自动降级
- BuddyCLI/main.swift（841 行 raw CommandLine）追加 `case "launcher":` nested switch 内分发 `config` 子命令

## 输入

- Task 001 handoff（LauncherManager.shared 接口）
- Anthropic Messages API 文档：`POST /v1/messages`，header `x-api-key`、`anthropic-version: 2023-06-01`
- OpenAI Chat Completions API 文档（Ollama 兼容）：`POST /v1/chat/completions`，base URL 用户配置

## 输出契约

### 接口签名（invariant）

```swift
// SecretStore 协议（可插拔）
protocol SecretStore {
    func save(key: String, value: String) throws
    func load(key: String) throws -> String?
    func delete(key: String) throws
}

final class KeychainSecretStore: SecretStore   // service="claude-code-buddy.launcher"
final class EncryptedFileSecretStore: SecretStore  // CryptoKit ChaChaPoly + IOPlatformUUID 派生密钥
                                                    // 文件 ~/.buddy/launcher-secrets.enc

// SecretStore 工厂（探针 + 降级）
enum SecretStoreFactory {
    static func create() throws -> SecretStore  // 先试 Keychain.save("__probe__","test")，
                                                  // 失败 fallback EncryptedFile，
                                                  // 都失败抛 secretStoreUnavailable
}

// LauncherConfig
struct LauncherConfig: Codable {
    var activeProvider: String         // "anthropic" / "ollama" / ...
    var providers: [String: ProviderConfig]
    var hotkey: HotkeyConfig?
}

struct ProviderConfig: Codable {
    let kind: String                   // "anthropic" / "openai-compatible"
    let baseURL: String?               // openai-compatible 必填
    let model: String
    let keyRef: String                 // 在 SecretStore 中的 key（不含真值）
}

extension LauncherConfig {
    static func load() throws -> LauncherConfig  // 读 ~/.buddy/launcher.json
    func save() throws                            // 写 ~/.buddy/launcher.json 权限 0600
}

// 共享数据结构（与 task 003 同源）
struct AgentMessage: Codable {
    let role: String   // "user" / "assistant"
    let content: [AgentContent]
}
enum AgentContent: Codable {
    case text(String)
    case toolUse(id: String, name: String, input: [String: AnyCodable])
    case toolResult(toolUseId: String, content: String, isError: Bool)
}
struct AgentTool: Codable { let name, description: String; let inputSchema: [String: AnyCodable] }
struct AgentResponse: Codable {
    let content: [AgentContent]
    let stopReason: String
    let usage: AgentUsage?
}

// LauncherProvider 协议
protocol LauncherProvider {
    func send(messages: [AgentMessage], tools: [AgentTool], model: String) async throws -> AgentResponse
}

final class AnthropicProvider: LauncherProvider { ... }
final class OpenAICompatibleProvider: LauncherProvider { ... }

enum ProviderFactory {
    static func create(_ config: ProviderConfig, store: SecretStore) throws -> LauncherProvider
}

// CLI 子命令（main.swift nested switch）
// buddy launcher config set --provider <id> --kind <anthropic|openai-compatible>
//                            [--base-url <url>] --model <name> --api-key <key>
// buddy launcher config get [--provider <id>]
// buddy launcher config use <provider>
```

### 接口签名（example, Pact 风格）

```
# Anthropic.send 正例
Given: messages=[{role:"user", content:[.text("hi")]}], tools=[], model="claude-sonnet-4-5"
When:  AnthropicProvider(key:"sk-ant-...").send(...)
Then:  AgentResponse(content:[.text("Hello!")], stopReason:"end_turn", ...)

# Anthropic.send tool_use 分支
Given: messages=[{user:"weather"}], tools=[weather_tool]
When:  send(...)
Then:  AgentResponse(content:[.toolUse(id:"t1", name:"weather", input:{"city":"sf"})], stopReason:"tool_use")

# OpenAI 兼容.send 正例（Ollama qwen2.5）
Given: messages=[{user:"hi"}], tools=[], model="qwen2.5:7b", baseURL="http://localhost:11434/v1"
When:  send(...)
Then:  AgentResponse(content:[.text("...")], stopReason:"end_turn")

# SecretStoreFactory.create() 降级
Given: ad-hoc 签名应用，Keychain.save probe 失败
When:  SecretStoreFactory.create()
Then:  返回 EncryptedFileSecretStore 实例，~/.buddy/launcher-secrets.enc 被创建
```

### 数据结构

- `~/.buddy/launcher.json` 权限 == 0600
- `~/.buddy/launcher-secrets.enc` 权限 == 0600（仅 EncryptedFile 路径才创建）
- Keychain service == `"claude-code-buddy.launcher"`，account == `"<providerId>.apiKey"`
- API key 长度：≥ 8 字符（校验）

### 边界值（DbC）

- HTTP 超时：≤ 120s
- API key 校验：`length >= 8`
- baseURL（OpenAI 兼容）：必须以 `http://` 或 `https://` 开头

### 错误契约

| 错误码 | 触发 |
|---|---|
| `providerNotConfigured` | LauncherConfig.activeProvider 为空 |
| `invalidAPIKey` | SecretStore.load 返回 nil 或长度 < 8 |
| `networkFailure(Error)` | URLSession 错误 |
| `providerHTTPError(Int, String)` | HTTP 4xx/5xx（含 body 前 200 字） |
| `secretStoreUnavailable` | Keychain 和 EncryptedFile 都失败 |

### 副作用清单

- 写 `~/.buddy/launcher.json`（0600）
- 写 `~/.buddy/launcher-secrets.enc`（仅降级路径，0600）
- 写 Keychain（生产路径）
- 网络出 `https://api.anthropic.com` 或用户配置的 baseURL

## 验收标准

- ✅ SC-02：`buddy launcher config set --provider anthropic --kind anthropic --model claude-sonnet-4-5 --api-key sk-ant-...` 写入；重启 app 后能加载；浮窗发问拿到响应
- ✅ SC-07：未配置任何 provider 时 LauncherManager.submit 抛 `providerNotConfigured`，UI 显示配置引导
- ✅ SC-12：配置 Ollama（`--kind openai-compatible --base-url http://localhost:11434/v1 --model qwen2.5:7b`）能拿到本地响应；`pkill ollama` 后再发请求显示 `networkFailure`

## 测试要求

- `SecretStoreFactoryTests.swift`：mock Keychain 失败强制降级路径
- `AnthropicProviderTests.swift`：URLProtocol mock 验证请求 header / body schema
- `OpenAICompatibleProviderTests.swift`：URLProtocol mock 验证 `messages` 字段转换正确
- `LauncherConfigTests.swift`：JSON 读写 + 0600 权限验证
- `Provider.acceptance.test.swift`（红队）：用真实 Ollama 本地 qwen2.5（CI 跳过）

## 风险与缓解

- **Anthropic vs OpenAI message 字段差异**：单元测试每个 provider 都有 fixture JSON，对照官方 schema 校验
- **tool_use schema 嵌套结构**：建议 AnyCodable 包装 input 字段；用 PluginManager 真实 tool 输入测试
- **Keychain entitlement 报错**：在 SecretStoreFactory 构造时 try Keychain.save("__probe__", "x") 后立即 delete，捕获 OSStatus 决定降级

## 接出

handoff 写：SecretStoreFactory.create() 调用点 + ProviderFactory.create() 签名 + LauncherConfig.load() 在 LauncherManager.setup() 中的位置；下游 task 003 怎么用 `provider.send(...)`。
