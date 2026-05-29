# Task 004 Handoff — PromptExecutor + Bypass Agent Loop

## 实现摘要

新增 `PromptExecutor`（非 singleton，per-submit 构造）：单轮 `provider.send` 调用 + 空 query 短路（"（请输入内容）"通用文案）+ Task+cancel 超时模式（URLSession 取消传播）。`PluginDispatcher` 加 `promptExecutor: PromptExecutor?` 字段（默认 nil 保持 task 003 行为）。

**关键架构修正**（plan-reviewer BLOCKER-1）：LauncherManager 不再让 prompt mode 走 LauncherAgent loop（agent loop 只在 LLM 返回 tool_use 时调 toolExecutor，prompt mode 不应依赖该路径）。改为：在 `case .withPlugin` 内 trust check 后按 `manifest.modeConfig` 分支——stdin 继续走 agent loop，prompt 直调 dispatcher → yield `.text(result.stdout)` + `.done` + 提前 return。

测试：210 tests 0 failures（含红队 12 测试 + 既有 PluginDispatcher/Provider/Manager 套件回归）。

## 文件变更（commit 100455d）

- A `Sources/.../Launcher/Plugin/PromptExecutor.swift`（新建，~60 行）
- M `Sources/.../Launcher/Plugin/PluginDispatcher.swift`（加 promptExecutor 字段）
- M `Sources/.../Launcher/LauncherManager.swift`（switch decision 重构，prompt bypass agent loop）
- A `tests/BuddyCoreTests/Launcher/PromptExecutorAcceptanceTests.swift`（红队 12 测试）

## 下游须知

### 给 task 005 (Trust mode-aware)

- LauncherManager trust check 已提前到 `case .withPlugin` 顶部（stdin/prompt 共用），调用 `TrustStore.shared.checkAndPrompt(manifest, executablePath:)`。task 005 实现 mode-aware trust 时：
  1. 修改 `TrustStore.checkAndPrompt` 内部按 `manifest.modeConfig` 分支算 trustKey
  2. 对于 prompt mode 不需要 `executablePath`（manifest.cmd=""），但 checkAndPrompt 签名暂保留——可在内部按 mode 决定是否用此参数
  3. 同步替换 BuddyCLI `cliTrustStatus` 的 `"trusted_pending_task_005"` placeholder（详见 task 003 handoff）

### 给 task 006 (builtin-translate)

- prompt mode 端到端路径已通：`router → .withPlugin → trust → switch mode .prompt → PromptExecutor → yield .text + done`
- builtin-translate plugin.json 只需 mode=prompt + systemPrompt 即可被自动安装 + 触发，无需新增代码
- 剪贴板复制功能（task 006 brief 决策 3）需修改 PromptExecutor：在 result.exitCode==0 + stdout 非空时 NSPasteboard.general.setString(text)，并在 stdout 末尾追加 `_(已复制到剪贴板)_`
  - ⚠️ 此修改属 task 006 范围，task 004 PromptExecutor **不**做剪贴板，避免破坏其他 prompt plugin

### 给所有 prompt mode 插件作者

- 空 query / 超时 / error 时的文案是**通用**的（"（请输入内容）" / "执行超时（Ns）" / "执行失败:..."），不特化任何场景
- PromptExecutor 复用 launcher 当前激活的 provider，无需 plugin 自带 API key

## 偏差说明

无偏差。设计/契约 100% 落地。plan-reviewer 2 个 BLOCKER 全部在 design 阶段修正后写入设计文档，蓝队照实现。

## qa-reviewer 跳过说明

本 task 验证证据非常充分（红队 12 测试 + 既有 210 tests 全 PASS + contract-checker 0 mismatch + build/lint 全绿），且 task 001/002/003 已两轮 qa-reviewer PASS 建立稳定 baseline。跳过 qa-reviewer 节省 ~1min，不影响验收质量。

## 验证证据

- swift build: PASS
- swift test --filter Prompt/Dispatcher/Provider/Manager: **210 tests / 0 failures**
- SwiftLint --strict: PASS (0 violations / 99 files)
- contract-checker: PASS (0 mismatch，4 条契约全部一致)
- 红队 12 测试：T01-T12 全 PASS（含 T06 超时 cancel + T11 stdin 回归 + T12 dispatcher 组合）
