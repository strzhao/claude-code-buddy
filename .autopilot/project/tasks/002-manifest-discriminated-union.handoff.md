# Task 002 Handoff — PluginManifest discriminated union

## 实现摘要

`PluginManifest` 从扁平 struct 重构为带 `modeConfig: PluginModeConfig` 的 discriminated union。`enum PluginModeConfig` **故意不声明 Codable**（由 `PluginManifest` 自定义 init/encode 负责），含 `.stdin(StdinConfig)` 和 `.prompt(PromptConfig)` 两 case。decoder 按顶层 `mode` 字段分发，缺 mode 默认 stdin（向后兼容）。`validate()` mode-aware：stdin 保留 cmd/.. 校验，prompt 加 systemPrompt 非空 + ≤8KB + maxIterations [1, 10] 边界。

为避免 002 范围爆炸，保留 **back-compat accessors**（`cmd`/`args`/`env`/`requiredPath`），stdin 时返回正确值，prompt 时返回空值兜底——⚠️ 仅作为 task 003 修复 BuddyCLI inspect/trust 路径前的临时状态。

红队 12 测试全 PASS（127 tests total，0 failures，0.023s）。

## 文件变更（commit cffc008）

- M `apps/desktop/Sources/.../Launcher/LauncherConstants.swift`（+2：`promptMaxSystemPromptBytes=8192`, `promptMaxIterations=10`）
- M `apps/desktop/Sources/.../Launcher/Plugin/PluginManifest.swift`（重构，+~160 行）
- M `apps/desktop/Sources/ClaudeCodeBuddy/Plugins/HelloPlugin/plugin.json`（+1：`"mode": "stdin"`）
- A `apps/desktop/tests/BuddyCoreTests/Launcher/PluginManifestModeDiscriminatedUnionAcceptanceTests.swift`（12 红队验收测试，460 行）
- M `.autopilot/project/tasks/003-plugin-dispatcher.md`（plan-reviewer 移交：加 BuddyCLI:1167-1168 修复条目）

## 下游须知

### 给 task 003 (PluginDispatcher) — **必读 BLOCKER 移交**

由 plan-reviewer 在 002 design 阶段识别的 **BuddyCLI inspect 路径污染问题** 已写入 003 brief：

`Sources/BuddyCLI/main.swift:1167-1168` 的 `cliComputeTrustKey(cmd: manifest.cmd, args: manifest.args, ...)` 当遇到 prompt mode plugin 时，因 back-compat accessor 返回 `manifest.cmd==""`，会算出错误 trust key 写入 trust.json。task 003 必须在此调用前 `guard case .stdin(let cfg) = manifest.modeConfig else { ... }` 路由到 prompt 分支（与 task 005 协调 prompt trust 计算）。

### 给 task 003/004/005/006 — 新 schema 使用

```swift
// 推荐：明确按 mode 分支
switch manifest.modeConfig {
case .stdin(let cfg): // 用 cfg.cmd / cfg.args / cfg.env / cfg.requiredPath
case .prompt(let cfg): // 用 cfg.systemPrompt / cfg.maxIterations / cfg.model
}

// 或：用 Optional accessor
if let stdinCfg = manifest.stdinConfig { ... }
if let promptCfg = manifest.promptConfig { ... }

// ❌ 避免：back-compat accessor（除非显式知道是 stdin context）
// manifest.cmd  ← prompt mode 返回 ""，可能引发静默 bug
```

### 给所有 mode

- `manifest.name / version / description / keywords / timeout / effectiveTimeout` — 共享字段不变
- `validate(againstDirName:)` — 调用方无需感知 mode（内部分支）

## 偏差说明

无技术偏差，设计/契约 100% 落地。1 个小修补：

- 红队测试文件 3 处有 Chinese-text-with-ASCII-double-quotes 字符串字面量 bug（如 `"必须含"绝对路径"，实际"` 中间的 `"绝对路径"` 误终结字符串）→ Edit 修复为 `"必须含 绝对路径 字样，实际"`。已统一改 3 处。

## 验证证据

- swift build: PASS
- swift test --filter Manifest: **127 tests, 0 failures, 0.023s**（含红队 12 + 既有 PluginManifestTests/Acceptance/Runtime 全套）
- SwiftLint --strict: PASS (0 violations / 97 files)
- contract-checker: PASS (0 mismatch, 6 条契约条款全部一致)
- qa-reviewer: PASS (Section A 6/6 ✅, Section B 3 个非阻塞改进建议)
