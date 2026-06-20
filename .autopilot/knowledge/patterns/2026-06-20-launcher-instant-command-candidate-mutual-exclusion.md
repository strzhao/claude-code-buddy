# launcher 内置 instant 候选与外部 command 候选显示互斥，command 插件对用户不可达

<!-- tags: launcher, instant-candidates, builtin-plugin, command-mode, candidate-display, mutual-exclusion, routing-conflict, app-launcher, qzh, ux, known-issue, followup, hasoutput-guard, performselectedinstantaction -->

**Scenario**: 做 qzh command 插件（keywords:["qzh"]）控制 QzhddrSrv。E2E 验证（`buddy launcher debug candidates "qzh"`）返回的是**内置 AppLauncherPlugin 的「Qzhddr」app 候选**（`/Applications/Qzhddr.app` 命中，score 1050），不是 qzh command 候选。

**Lesson**:
- **根因三连**：① `LauncherInputView:80` 历史上**删除了外部 plugin 候选行**（改用 `PluginWatermarkChip` 水印，注释「外部 plugin 候选行已删」），command 插件不显示为候选行；② `showInstantCandidates`（`:42-45`）的 `hasOutput` 守卫（含 `pluginCandidates`）让 instant 与外部候选互斥；③ `submit()`（`:369`）Enter 优先 `performSelectedInstantAction` 先于 command/router。
- **后果**：输入 qzh → instant（AppLauncher Qzhddr app）候选行显示 + Enter 优先执行（**打开 Qzhddr app**），qzh command 既不显示为候选行、Enter 又被抢占 → **command 插件对用户完全不可达**。
- **关键词冲突**：用户主动安装的 command 插件（keywords）与内置 AppLauncher（匹配 `/Applications` app 名）竞争同一输入，instant 优先级 + 候选行缺失让 command 永远不触发。这是 command mode 落地后首类 UX 死锁。
- **后续改造方向**（独立任务，~2 天，方案 B 分区渲染）：① 恢复 router 命中的 command 插件为候选行（不只水印 chip）；② command 候选区排序在 instant 区**之上**（用户主动安装 > 内置）；③ `submit()` Enter 优先级改为 command > instant。改动聚焦展示层 + Enter 选择，**不动** submit 管线 / StdinExecutor / 候选通道（均已验证）。
- **测试盲区**：`buddy launcher debug candidates` 走内置 BuiltinPluginRegistry 管线（instant），不触发外部 command 的 StdinExecutor，无法直接覆盖 command 候选的 GUI 端到端——这类「内置 vs 外部候选竞争」需 GUI 真机验证或扩展 debug CLI 覆盖 command 管线。

**Evidence**: E2E `debug candidates "qzh"` → `{"pluginId":"app-launcher","title":"Qzhddr","score":1050}`；`LauncherInputView.swift:42-45`(showInstantCandidates)、`:80`(外部候选行已删改 chip)、`:369`(submit instant 优先)；Explore 改造评估方案 B（分区 + command 优先，~2 天，低风险）。
