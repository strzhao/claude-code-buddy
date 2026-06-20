# command mode 候选输出通道 BUDDY_OUTPUT_CANDIDATES + 选中回调重入 submitWithCandidate

<!-- tags: launcher, command-mode, candidates-channel, submit-callback, plugin-input, tofu, agent-event, exhaust-switch, qzh, launchd, bootout, sudoers, image-channel-sibling, plugin-result, readcandidateoutputsafely -->

**Context**: [[2026-06-19 command mode + image 通道]] 已支持文本+图片输出（零 LLM bypass agent loop），但插件无法返回「候选列表供用户选择 + 选中后回调执行」（如 qzh 输入后给「关闭/打开监控」候选）。需要一条与 image 通道对称的「候选输出通道」+ 选中回调重入机制。

**Decision**:
1. **候选通道完全对称 image 通道**：`StdinExecutor` 注入 `env["BUDDY_OUTPUT_CANDIDATES"]=/tmp/buddy-plugin-<uuid>.json`（同 UUID 生命周期 + defer 删），子进程写 JSON 数组，框架 `readCandidatesOutputSafely`（文件存在 + symlink 校验 `resolvedPath == expected` + `<= pluginMaxCandidatesBytes`(64KiB) + JSON 解码，任一失败降级 nil）→ `PluginResult.candidates`。stdin + command 共享（非 command 专属）。
2. **LauncherCandidate 值类型**（Codable/Equatable/Identifiable）：`{id, title, subtitle?, selection}`。`selection` 仅标识字符串，**禁含命令/路径**——执行权留插件（C5 安全红线）。
3. **AgentEvent.candidates + `==` 同步**（穷尽 switch 陷阱）：新增 `case candidates([LauncherCandidate])` 必须**同步加 `AgentEvent.==` 比较分支**（漏则不报编译错但两相等流被判不等→假阴性；历史 `.toolCall` == 漏比已被 plan-reviewer 抓）。这是 command mode 同类「5+1 处穷尽 switch」陷阱。
4. **选中回调重入 submitWithCandidate**：`PluginInput` 加可选 `selection`（Codable 向后兼容，老 JSON 解码 nil），`submitWithCandidate(_:selection:query:)` 以 selection 重入 command mode（bypass LLM，同静态短路路径）。command trustKey = `"command:" + SHA256(cmd+args+exeBytes)`（`TrustStore.swift:41-48`，**不含 stdin/selection**）⇒ 回调不重复弹 TOFU 框。

**Rationale**: image 通道（env 注入 + 文件回传 + 安全读 + 降级 nil）是验证过的「子进程→框架」输出通道模板，候选通道完全对称复用，零新模式风险；selection 走 stdin（非 args）使 trustKey 不变，回调免重信任。

**Constraint**: 候选仅 command mode（stdin/prompt 走 LLM loop 语义不同，候选回调不适用）；bootout/bootstrap 真副作用（sudo + root + KeepAlive）不可自动求值，用 spy/日志 det-machine 断言调用链，不真改系统（参 [[2026-05-31 macos 锁屏私有 API]] pattern）。

**Evidence**: b878341 feat；`StdinExecutor.readCandidatesOutputSafely`；`AgentEvent.candidates` + `==`；`LauncherManager.submitWithCandidate`；qzh 插件（`Marketplace/plugins/qzh/`，首个使用者：pgrep 查状态 + [关闭/打开]候选 + bootout/bootstrap + sudoers 免密）。
