<!-- tags: qwen3, llm, thinking, reasoning, chat-template-kwargs, llama-cpp, openai-compat, perf, ttft, jinja, prompt-api -->
# [2026-05-31] Qwen3 thinking 关闭唯一有效通道是 `chat_template_kwargs.enable_thinking:false`

## 现象
Qwen3 / Qwen3-A3B 等推理模型默认开启 CoT thinking，简单查询（如 "buddy" 翻译）会在 `reasoning_content` 输出 1000+ tokens 的思考链（"Step 1. Analyze user input..."），导致 35B-A3B 本地推理一次耗时 24.5s（其中 ~95% 在思考无意义的简单任务）。

## 实测对比（5 case curl 直打 llama-server，user="buddy"）
| 配置 | total | comp_tok | reasoning_chars | content_chars |
|---|---:|---:|---:|---:|
| 默认 thinking on | 24.5s | 1599 | **4364** | 208 |
| body 顶层 `enable_thinking:false` | **41.9s** | 2390 | **6869** | 196 |
| body `chat_template_kwargs.enable_thinking:false` | **1.45s** | 101 | **0** | 208 |
| user msg 追加 `/no_think` | 19.2s | 1337 | 3710 | 208 |

## 结论
- **唯一有效**通道是 `chat_template_kwargs.enable_thinking:false`（17× 加速）
- top-level `enable_thinking` 被 llama-server **忽略**（反而更慢，可能因为额外字段触发某种处理）
- user message 加 `/no_think` flag 也被 systemPrompt 严格约束环境下忽略
- 通道生效原因：llama.cpp `chat_template_kwargs` 透传给 Jinja chat template，Qwen3 template 里 `{% if not enable_thinking %}...{% endif %}` 控制是否注入 `<think>` 引导

## How to apply
- 任何走 OpenAI-compat API 调 Qwen3 系列模型的 provider，请求体必须支持 `chat_template_kwargs` 顶层字段
- Swift Codable 实现：
  ```swift
  struct ChatTemplateKwargs: Codable {
      let enableThinking: Bool?
      enum CodingKeys: String, CodingKey { case enableThinking = "enable_thinking" }
  }
  struct OAIRequestBody: Encodable {
      ...
      let chatTemplateKwargs: ChatTemplateKwargs?
      enum CodingKeys: String, CodingKey { case chatTemplateKwargs = "chat_template_kwargs", ... }
      func encode(...) { try container.encodeIfPresent(chatTemplateKwargs, forKey: .chatTemplateKwargs) }  // nil 时不输出
  }
  ```
- 关键：用 `encodeIfPresent` 让 noThinking=false/未配置时**不输出**该字段，避免污染非 Qwen 后端（gpt-4o 等会拒绝未知字段）
- 配置选择：plugin/provider 配置加 `noThinking: Bool?` 开关，仅在已知后端是 Qwen3 时开启

## 反例避雷
- ❌ 不要 hardcode 在 base provider，会污染所有后端
- ❌ 不要写到 user message 末尾（被 systemPrompt 严格约束时模型当字面文本）
- ❌ 不要寄希望于 server 自动识别 model 名（llama.cpp 不做这层语义）

## 关联
- 与 P0/P1 配合：P0 关 thinking + P1 SSE 流式 → TTFT 24.5s → 0.038s（645×）
- [[2026-05-31-llm-prompt-style-positioning-vs-instructions]] — Qwen3 thinking off 后模型能力的"查字典助手"风格定位才能发挥
