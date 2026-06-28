<!-- tags: launcher, logging, buddylogger, instrumentation, subsystem, launcher-agent, plugin, provider, agent-loop, stdin-executor, manager, submit, debug-route, cli, end-to-end, socket, query-handler -->

# Launcher 日志注入全覆盖 + debug route CLI

## Lesson: BuddyLogger 注入纯加法模式

**场景**：launcher 子系统原有 3 条 BuddyLogger 调用（全是 marketplace setup failed），submit 全链路 16+ 分支、StdinExecutor 进程生命周期、LauncherAgent loop、Provider 层全部黑盒。

**注入规范（5 条原则）**：
1. **纯加法**——不改现有逻辑，只在 `throw`/`return`/`guard`/`catch` 前插一行 log
2. **错误路径用 error** + meta 含 `error: "\(err)"` 或 `statusCode: N`
3. **关键决策用 info** + 结构化 meta（query、plugin 名、durationMs、candidateCount 等）
4. **快速路径不记日志**（高频、无异常的 hot path）
5. **subsystem 严格遵循登记表**：`launcher`（Manager/Router/ProviderFactory）、`launcher-agent`（Agent/Provider/PromptExecutor）、`plugin`（StdinExecutor/PluginDispatcher/TrustStore）

**覆盖结果**：7 文件 50+ 注入点，零逻辑修改，编译一次通过。

**How to apply**: 后续对 launcher 任意分支添加日志时，遵循上述 5 条原则；新增 subsystem 标签必须先在 CLAUDE.md 登记表中注册。

---

## Pattern: `buddy launcher debug route` CLI 端到端 AI 路由调试

**场景**：现有 `buddy launcher debug candidates/perform/registry/run` 只能测内置候选和外部插件，无法触发 directChat AI 路由的完整链路。

**实现**：
- CLI 侧（`BuddyCLI/main.swift`）：新增 `cmdLauncherDebugRoute` 函数，socket action `launcher_debug_route`，timeout 30s（vs 默认 2s）
- Handler 侧（`QueryHandler.swift`）：`handleLauncherDebugRoute` 自建 config→ProviderFactory→LauncherRouter→PromptExecutor 链路，**绕过 LauncherManager.submit 的 isSubmitting 卫兵**

**响应契约**：
```json
{"status":"ok","data":{"query":"...","decision":"directChat|withPlugin:name","candidates":[...],"outputText":"...","durationMs":N}}
```

**关键设计决策**：不在 handler 中调 `LauncherManager.shared.submit(query)`（isSubmitting 卫兵 + AsyncStream 异步约束在同步 socket handler 中难以可靠收集），而是在 handler 内直接构造 provider + router + PromptExecutor 并行收集结果。

**How to apply**: 其他需要端到端调试的子系统可效仿此模式——在 QueryHandler 中自建最小链路，绕过 UI 层卫兵和异步约束，通过 socket action 暴露给 CLI。
