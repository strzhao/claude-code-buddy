<!-- tags: llm, prompt-engineering, systemprompt, few-shot, template, placeholder, markdown, translate, output-format, in-context-learning, hallucination -->
# [2026-05-31] systemPrompt 用 few-shot 真实示例驱动 markdown 输出，模板占位符会被字面照搬

## 反模式
translate plugin 早期 systemPrompt 写成"模板填空"风格：
```
输出格式：
**WORD** /音标/
n. 词性 词义
> 例句 — 翻译
```
qwen3.6-35b 真实输出：
```
**WORD** /音标/        ← 字面输出占位符
n. 词性 词义           ← 字面输出占位符
```
LLM **没有**把 `WORD` 替换成 `buddy`、把 `/音标/` 替换成 `/ˈbʌdi/`，而是当成必须保留的格式字面照搬。

## 修复
改用 5 个 few-shot 真实示例（每个示例都是完整输入→完整输出的真实样本），不留任何占位符：
```
## 示例 1 — 单词 `buddy`
**buddy** /ˈbʌdi/ <action:speak text="buddy">🔊</action>
n. 朋友；伙伴；密友 <action:copy text="朋友；伙伴；密友">📋</action>
v. 〈口〉做朋友 <action:copy text="做朋友">📋</action>
> He's my buddy since college. — 他从大学起就是我的好友。

## 示例 2 — 短语 `break the ice`
**break the ice** <action:speak text="break the ice">🔊</action> → 打破僵局 ...

## 示例 3 / 4 / 5 — ...
```
+ 硬约束：`**禁止**输出占位符字面（如 WORD、PHRASE、译文 这些标识词）`。

## Why
1. **In-context learning > 抽象指令**：LLM 在 token 预测时优先模仿"长得像示例"的输出。给 5 个真示例，它学会的是"看见单词输出这种结构"；给模板占位符，它学会的是"输出长这样的东西"（含占位符字面）。
2. **占位符无歧义信号**：`WORD` / `PHRASE` / `译文` 这种词在训练语料里既是说明文里的"指代变量"，也可能是字面文本。LLM 没法从上下文判断你要它替换还是保留 —— 默认倾向保留（保守输出）。
3. **结构性 token 同时被学到**：用真示例时，markdown 的 `**bold**`、emoji、换行节奏、action 标签 ([[2026-05-31-llm-embedded-action-tag-protocol]]) 都被一次性示范，不需要再写元规则。

## How to apply
- LLM 输出结构化内容（markdown / json / 表格）时，**首选**给 3-5 个真实输入→输出示例。
- 涵盖不同 case（单词/短语/句子、不同语言方向、边界情况），让 LLM 自行 generalize。
- 硬约束补在示例末尾（"禁止输出占位符字面"、"段落间只用 1 个换行"），但**不要**用硬约束替代示例。
- 适用于：翻译、摘要、格式转换、命令生成、router 选择（router 已有专门 prompt：[[2026-05-27-ai-router-system-prompt-prefix]]）。
- 反例（不需 few-shot）：纯自由问答、单条命令翻译（"翻译为英文：xxx"）。

## 性能注意
few-shot 会增加 prompt token，translate 的 5 个示例约 +400 tokens。对小模型（qwen3.6-35b 本地推理）值得，因为输出质量 ↑↑↑。对长上下文/高频调用要权衡。

## 代码锚点
- `apps/desktop/Sources/ClaudeCodeBuddy/Marketplace/plugins/translate/plugin.json` (systemPrompt — 5 示例完整版)
