# 红队测试 helper 默认填字段掩盖向后兼容场景，Tier 1.5 真实边缘输入才捕获

<!-- tags: autopilot, red-team, testing, helper, backward-compat, tier-1-5, blind-spot, contract-checker, decodeifpresent, keywords, acceptance-test, qa, real-scenario, edge-input -->

**Scenario**: 红队写验收测试时，为减样板常在 helper（如 `pluginJSON()`）里默认填部分字段（如 `"keywords":[]`）。contract-checker + 红队均基于这些 helper 构造的输入验证，**构造不出「字段缺失」的边缘用例**，导致「字段 required 而非 optional」的向后兼容 bug 漏过。

本次实例：plugin `keywords: [String]` required。红队 helper 默认填 `keywords:[]`，红队验收 + contract-checker **全 PASS**，但 QA Tier 1.5 真实造无 summary 无 keywords 的 `legacy/plugin.json` 才暴露 `inspect legacy` → "Plugin not found"（decode 失败被跳过）。

**Lesson**:
- **红队 helper 是双刃剑**：减样板但掩盖边缘场景。涉及「向后兼容/字段缺失/降级」的契约，红队 helper **必须**提供「缺字段」变体（如 `pluginJSON(without: .keywords)`）或显式构造缺字段 JSON，不能默认填。
- **contract-checker 盲区**：它读实现代码比对契约字段名/类型，但**不跑真实 decode**；required vs optional 的「向后兼容」维度需真实 decode 边缘输入验证（它看不出 keywords 该 optional 却 required）。
- **Tier 1.5 是最后防线**：Tier 1.5（真实场景谓词求值）必须包含「边缘/缺失/降级」输入（旧格式插件无 summary/keywords），用真实 CLI/app 驱动，捕获单测 + 红队 + contract-checker 都漏的问题。

**How to apply**:
- 红队写向后兼容相关测试：helper 提供缺字段变体；验收谓词 observe 显式构造边缘 JSON（如 `printf '{"name":"legacy",...}'` 无 summary/keywords）。
- QA Tier 1.5：对每个「可选/降级」契约，至少 1 条谓词用真实边缘输入驱动（不只正常输入）。
- 编排器：contract-checker PASS ≠ 向后兼容无误；对向后兼容敏感字段，额外用真实 decode 边缘输入验证（Tier 1.5 承担）。

**关联**: [[2026-06-23-autopilot-red-team-false-report-verify-ls]]（红队验证）、[[2026-06-24-plugin-summary-displaysummary-mirror-cli-buddycore]]（本次触发的具体 bug）。
