# 新增 command mode + 通用图片通道：零 LLM bypass agent loop，子进程产 PNG 经 BUDDY_OUTPUT_IMAGE 回传

<!-- tags: launcher, command-mode, image-channel, agent-loop-bypass, plugin-mode, tofu, stdin-executor, plugin-result, agent-event -->
**Context**: Launcher 外部插件所有输出通道此前只承载文本（stdout/stderr 1MiB 截断、MarkdownRenderer inlineOnly、CopyService 仅 setString）。「产物是图片」的需求（二维码等）无法在 launcher 内展示。需要：(1) 新增独立 command mode（零 LLM、bypass agent loop，与 prompt mode bypass 对称）；(2) 通用图片回传通道（stdin + command 共享）。

**Decision**:
1. **回传走输出文件而非 stdout**：`StdinExecutor` 注入环境变量 `BUDDY_OUTPUT_IMAGE=/tmp/buddy-plugin-<uuid>.png`，子进程写 PNG，框架读文件成 `Data` 填 `PluginResult.image`。stdout 保持纯文本不被污染（stdin mode toolExecutor 回灌 LLM 不受影响）。读前 `resolvedPath == outputImagePath` 校验防 symlink（/tmp 防御）；`count > pluginMaxImageBytes`（5MiB）丢弃为 nil；finally 删临时文件（防累积）。
2. **command mode bypass agent loop**：`PluginModeConfig` 加 `.command(CommandConfig)`（与 StdinConfig 同构）。`LauncherManager.submit` switch 加 `.command` 分支，仿 prompt mode 提前 return（stripKeywordPrefix → StdinExecutor → yield `.text`/`.image`/`.done`），不构造 LauncherAgent、不发 LLM 请求。
3. **5+1 处穷尽 switch 同步改**：加 enum case 后 `TrustStore.trustKey`（无 default，BLOCKER）/ `PluginDispatcher.execute` / `PluginManifest init+encode+validate` / `TrustPrompt.askUser` / `LauncherManager.submit` / `LauncherInputView` event switch 全部必须覆盖，否则编译错。command trustKey 复用 stdin 算法 + "command:" 前缀（mode 隔离防伪造）。
4. **UI**：纯图片居中白底 200pt 卡片（白底保证扫码对比度），点击 → `CopyService.copyImage`（clearContents + setData .png）+ ✓ 反馈（1.2s 复位）。无图片无 stdout 时显示占位「未生成图片」（降级非 error）。

**Rationale**: stdout 回灌 LLM 的 stdin mode 不能用 stdout 传图片字节（污染文本通道 + toolExecutor 回灌）；bypass agent loop 的 command mode 与 prompt mode 对称（已有先例），零 LLM 适合确定性子进程产物（二维码）；mode 前缀隔离 trustKey 防止 stdin 已信任的 plugin 被冒充成 command 跳过 TOFU。

**Evidence**: state.md `## 设计文档` §1-§7 + `## 契约规约`；PluginManifest.swift CommandConfig + .command；StdinExecutor.swift BUDDY_OUTPUT_IMAGE + readImageOutputSafely；LauncherManager.swift submit .command 分支；LauncherInputView.swift resultImageCard；端到端冒烟通过。
