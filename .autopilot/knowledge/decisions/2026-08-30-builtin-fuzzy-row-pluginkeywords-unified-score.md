# 内置插件接入统一混排：pluginKeywords + builtin: 聚合行 + 展开=填触发词

<!-- tags: launcher, builtin-plugin, unified-score, fuzzy-row, pluginkeywords, expand-builtin, tab-nolock, c-builtin-expand, cli-source-quad, enter-exec, prefix-guard, dedup -->

**Scenario**: 统一混排（[[2026-08-29-unified-candidate-mix-single-list-unified-score]]）只接了社区插件（scorer 吃 PluginManifest），内置插件仍走触发词 hasPrefix 严格匹配——输入 `pas` 时列表完全无 paste 内容，用户要求内置插件同等「一等公民」待遇。

**Choice**:
- **协议最小扩展**：`BuiltinPlugin` 加 `pluginKeywords: [String]`，extension 默认 `[]`（与 summary/description 同款默认值模式，既有测试桩零破坏）；本版只配 PastePlugin（=其 triggers），calculator/app-launcher 无触发词语义不配（YAGNI）。
- **scorer 一处定义多处消费**：新增 `score(query:name:keywords:)` 内核，manifest 版逐字委托（C-SCORER-DELEGATION，既有 24 测试零修改全绿即等价证据）。
- **聚合行防重**：`unifiedCandidates` 中**仅当该插件无具体候选**时才产行 `id="builtin:<id>"`（有候选=完整触发词直显条目，行与条目互斥零重复）；subtitle=summary（教育触发词）。
- **展开=填触发词，非替换列表**：Enter/点击 → `.expandBuiltin(bestTriggerWord)` → View 填触发词（`pas`→`paste`、`剪`→`剪贴板`，同分取最短）→ 既有 debounce 管线自然刷出具体候选。否决「直接替换 instantActions」：输入框与列表状态不一致 + 清 query 的 onChange 会清列表。
- **前缀守卫优先**：分流与 Tab 锁定均先判 `builtin:` 前缀再 `resolvePluginCandidate`（防社区插件重名 `paste` 误分流/误锁）。
- **CLI source 扩四值闭集** `{app,builtin,builtin-plugin,plugin}`：聚合行可区分（debug CLI 与 UI 同源管线，零额外数据层改动）。
- **QA 驱动通道**（真机 UserDefaults 开关翻转）：`defaults write com.claudebuddy.ClaudeCodeBuddy buddy.launcher.builtin.<id>.disabled -bool YES`——必须带 bundle domain（`defaults write <key> -bool YES` 会把 key 当独立 domain 静默写错位置，plan-reviewer 实测抓出）。

**Alternatives rejected**:
- 放宽 PastePlugin 触发词为模糊匹配直接展历史：`pas` 想搜 Passwords 时 8 条历史霸屏干扰。
- 所有内置插件配 keywords：calculator/app-launcher 无触发词语义，强行配置无意义。

**Trade-offs**: 聚合行「Enter 才见内容」比直接展历史多一步（对齐 Raycast/Alfred 命令行→进入正统形态，换低干扰）；View 消费分支无直接测试通道（enum 穷尽性编译守卫 + manager 层 seam 直调 + 真机 CLI 三层锚定）。核心收益：内置/社区/app 三源候选真正同权同管线。

**关联**: [[2026-08-29-unified-candidate-mix-single-list-unified-score]]（上游统一混排体系）、[[2026-07-01-command-dual-path-ui-vs-ai-flow]]（UI 层直调验收原则）、[[2026-08-31-swiftui-onchange-same-value-no-fire]]（展开方案的最大实现陷阱）。
