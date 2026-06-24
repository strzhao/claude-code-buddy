# plugin.json summary 双字段 + displaySummary 降级 + CLI·BuddyCore mirror 双绑（C1/C5）

<!-- tags: plugin, manifest, summary, displaySummary, fallback, mirror, cli, buddycore, c1, c5, codable, decodeifpresent, backward-compat, contract, launcher, keywords -->

**Scenario**: plugin.json 需要一句话人话摘要（summary，首屏展示）+ 详细 description，且旧插件（无 summary）不能被加载拒绝（向后兼容）。BuddyCore（`PluginManifest`）与 BuddyCLI（`CLIPluginManifestCheck`，Foundation-only 不依赖 BuddyCore）两侧都需解析。

**Lesson**:
- summary 设为 `String?`（可选）+ `displaySummary` 计算属性降级（优先级：summary 非空 → summary；否则 description 首句按 `。`/`./`换行切第一段 trim；都空 → name）。展示层永远拿到非空。
- **向后兼容铁律**：所有「旧格式可能缺失」的字段（summary/keywords/args/env/requiredPath）必须 `decodeIfPresent ?? 默认`，**不能 required**。required 字段在旧 plugin.json 缺失时 Codable **整体 decode 失败**（不是降级，是 inspect/list/find 全挂）。本次 `keywords: [String]` required 是 bug 根因——app 侧 `PluginManager.find` 整体加载失败、CLI `inspect` not found。修复 = 两侧 keywords 改 `decodeIfPresent ?? []`（与 args 容旧模式对齐）。
- **CLI·BuddyCore mirror 双绑**：CLI 不能依赖 BuddyCore（AppKit/SpriteKit 拖慢启动）。降级逻辑（`displaySummary`/`firstSentence`）两端各实现一份，**逐字一致**（分隔符 `["。","\n",". "]` + 句末单独 `.`），SOURCE OF TRUTH 标 BuddyCore，CLI mirror 注释「逐字一致」。否则设置页（app）与 CLI inspect 显示不同 summary。

**How to apply**:
- 新增 plugin.json 可选展示字段：BuddyCore 加 optional + displayXxx 降级；CLI mirror 同步加 optional + mirror 降级（逐字一致）；契约声明 source of truth。
- 任何 Codable 字段若旧数据可能缺失，**一律 decodeIfPresent ?? 默认**，永不 required（除 name/version/description 等 manifest 基础字段）。
- QA：Tier 1.5 真实造「缺失字段」的边缘输入验证降级，不能只靠单测（单测 helper 易默认填字段掩盖问题，见 [[2026-06-24-red-team-helper-masked-backward-compat-tier1-5]]）。

**关联**: [[2026-05-26-plugin-manifest-validation-path-traversal]]（manifest 校验）、[[2026-06-24-logging-system-jsonl-cli-foundation-mirror]]（CLI·BuddyCore mirror 同模式）、[[2026-06-24-red-team-helper-masked-backward-compat-tier1-5]]（本次 keywords bug 的捕获路径）。
