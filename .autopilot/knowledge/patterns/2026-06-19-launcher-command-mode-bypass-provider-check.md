# command mode（零 LLM）必须 bypass submit 顶层 provider 检查，否则无 LLM 用户无法用确定性命令插件

<!-- tags: launcher, command-mode, provider-check, zero-llm, short-circuit, submit-flow, agent-loop-bypass, plugin-mode, qa-finding, real-device-verification, narrow-candidates -->

**Scenario**: 新增 command mode（零 LLM、bypass agent loop）后，用户真机验证 qr 插件报「⚠️ 请先运行 buddy launcher config set 配置 provider」。根因：`LauncherManager.submit` 顶层 provider 强检查（`providerNotConfigured`，原 `:314-319`）在 mode 分发前对**所有** mode 生效——即使 command mode 不发 LLM 请求，也被拦。用户 `~/.buddy/launcher.json` 不存在（无 LLM API key）时，qr 等确定性命令插件完全不可用，违背 command mode「确定性命令不依赖 LLM」的设计意图。

**Lesson**: 零 LLM 的 mode（command）必须独立于 provider 配置。修复模式：detached task 开头先用**静态** `LauncherRouter.narrowCandidatesScored`（纯函数，不需 provider）判断「command 插件唯一/strong 短路命中」→ 直接走 command 执行路径（trust + `PluginDispatcher.execute` + yield `.image`/`.done`，bypass provider/router/agent loop），`return` 跳出；其余路径（directChat/aiSelect/stdin/prompt）才 `guard let` 解包 providerConfig/store，未配置则 `providerNotConfigured`。

**关键改动点**：
- 顶层 provider 检查从「强制 guard」改为「可选 let」：`let providerConfig = activeProvider.isEmpty ? nil : providers[activeProvider]`
- command 短路判断用**静态** `narrowCandidatesScored`（不经 router 实例——router 构造需 provider 参数）
- provider 创建延迟到非 command 路径（detached 内 `guard let providerConfig, let store`）
- command 经 aiSelect 选中（多候选）仍需 provider（aiSelect 本身要 LLM）—— 只有唯一/strong 短路才不需

**Rationale**: command mode 核心价值是确定性命令不依赖 LLM。顶层 provider 强检查是为 directChat/stdin/prompt（都需 provider）设计，新零 LLM mode 落入同一检查是架构盲点。**红队/蓝队测试都注入了 mock provider，绕过了「无 provider」场景**——这类「顶层共享检查 + 新 mode 绕过」的 gap，单元测试难覆盖，QA 真机验证（用户实际无 provider 配置）才暴露。

**Evidence**: `LauncherManager.swift` submit 顶层 provider 可选化 + detached command 短路（`narrowCandidatesScored` + `isShortCircuit && topIsCommand` → 直接 execute）；QA 真机：用户无 `~/.buddy/launcher.json` → qr 报 provider 错 → 修复后无 provider 可用；LauncherManager 相关测试 53 GREEN 无回归（directChat/stdin/prompt 路径仍正常要求 provider）。
