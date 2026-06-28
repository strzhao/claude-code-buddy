### [2026-06-28] 连接测试与 LLM 推理请求分层：URLSession 直连而非 LauncherProvider.send()

<!-- tags: connection-test, url-session, provider, launcher, http-timeout, auth-header, kind-differentiation, anthropic, openai-compatible, token-cost, design-review, url-construction, appending-path-component, double-path -->

**Background**: AI 配置 UI 的「连接测试」按钮设计时，初版方案用 `ProviderFactory.create() → provider.send()` 发完整 chat completion 请求验证连通性。plan-reviewer 捕获此方案消耗真实 token（产生费用）+ 超时不匹配（`LauncherConstants.httpTimeoutSec = 120s` vs 测试期望 15s）。修正为 `URLSession` 直接 `GET {baseURL}/v1/models`，只检查 HTTP 状态码。

**Lesson**: 连接测试是简单的 HTTP 端点连通性检查，不是 LLM 推理请求。两个关键决策：

1. **使用 URLSession 直连而非 ProviderFactory.send()** — 避免消耗 token、超时解耦（`URLRequest.timeoutInterval = 15` vs `LauncherConstants.httpTimeoutSec = 120`）
2. **按 kind 区分 auth header** — anthropic 用 `x-api-key` + `anthropic-version: 2023-06-01`，openai-compatible 用 `Authorization: Bearer`。一律用 `Bearer` 会导致 Anthropic API 认证失败（qa-reviewer 捕获为 P0）
3. **状态码范围用 200...299 而非 case 200** — 兼容返回 201/202 的服务（Ollama/LocalAI）

**How to apply**: 任何涉及 API 端点连通性验证的功能，应使用裸 HTTP 请求（URLSession/curl）而非业务层的 provider.send()。auth header 必须按 provider kind 显式区分。

**URL 构造教训 (2026-06-29)**: 用 `URL.appendingPathComponent("models")` 而非字符串拼接 `"\(baseURL)/v1/models"`。当 baseURL 已含 `/v1` 时，字符串拼接产生 `/v1/v1/models`（401）。用 `base.lastPathComponent == "v1"` 检测已有 path 后缀（`lastPathComponent` 正确处理 trailing slash，`pathComponents.last` 会返回空字符串）。
