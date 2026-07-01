# command mode 双执行路径 — UI 前缀路由 vs AI 流 contains

**日期**: 2026-07-01
**tags**: launcher, command-mode, dual-path, ai-flow, select-with-tools, narrow-candidates-scored, command-prefix-matched, false-positive, contains-vs-prefix, test-blind-spot, cli-debug-architecture, locked-command, autopilot

## 教训（Lesson）
command mode 有**两条独立执行路径**，改命中机制只堵一条 = 治标不治本：

1. **UI 层**：`updateQuery` → `commandPrefixMatched`（前缀严格匹配）→ `lockedCommand` → `LauncherInputView.submit` → `submitCommandDirect`。用户 typing 候选 + 选中锁定 + Enter 执行。
2. **AI 流**：`LauncherManager.submit` → `narrowCandidatesScored`（contains 反向匹配）→ `selectWithTools`（command 插件作 LLM tool）→ `LauncherManager.swift:742 case .command` → `dispatcher.execute`。用户回车未命中 UI command 候选时落此路径。

本次（2026-07-01）只改路径 1（`commandPrefixMatched` 消除 UI 层 qr 单字「码」误触），路径 2 仍用 `narrowCandidatesScored` contains。实测 `buddy launcher debug route "密码"` → `withPlugin:qr`（score:3），用户输「密码」回车落 AI 流仍执行 qr 生成二维码。**原始 bug 在 AI 流路径依然存在。**

## 选择（Choice）
- 真正消除误触必须同时处理两条路径：UI 层前缀化 + AI 流的 command 候选也前缀化 / 或 command 完全不走 AI 流（selectWithTools 只含 stdin/prompt）。本次用户选「UI 层先合入，AI 流留后续」。
- **CLI debug 命令架构限制**：`debug route`（AI 流）/ `debug candidates`（内置 instant，BuiltinPluginRegistry）/ `run`（绕过路由 + TOFU）**都不经 UI 层** updateQuery/lockedCommand。验收 UI 命中/状态机谓词只能用红队 XCTest 直接调 `updateQuery`/`submit`/`handleEscapeForTesting`（真实代码路径），CLI debug 只能验 AI 流/内置/绕过路径。

## 如何应用（How to apply）
- 改 launcher 命中/路由机制前，先 grep 全所有执行路径：`submit`、`selectWithTools`、`narrowCandidatesScored`、`commandPrefixMatched`、`submitCommandDirect`，确认改动覆盖每条（`LauncherManager.submit` 与 `LauncherInputView.submit` 是两个不同入口）。
- 验收 UI 层（typing/候选/选中/锁定/esc）谓词时，不要只靠 CLI debug（不经 UI 路径），用 XCTest 直调或键盘自动化。
- 红队验收测试要覆盖**所有执行路径**，不只主路径——本次红队只测 UI 层（commandPrefixMatched + lockedCommand），AI 流 selectWithTools 对「密码」的行为是盲区，直到 CLI `debug route` 端到端验收才暴露。
- autopilot 的 QA Tier 0 红队 + Tier 1 单测全绿 ≠ 真的消除 bug——必须 Tier 1.5 端到端真实产物验收（启动 app + CLI/键盘驱动真实路径）才能发现跨路径遗漏。
