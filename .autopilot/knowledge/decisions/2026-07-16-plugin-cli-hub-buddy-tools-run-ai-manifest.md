# 统一 CLI hub 暴露插件能力给外部 AI — buddy tools/run + JSON manifest（无 MCP）

**日期**: 2026-07-16
**tags**: launcher, cli, plugin, manifest, ipc, ai-tool, toagentool, socket, buddy-cli, foundation-only, no-mcp, camelcase, contract, dynamic, tofu

## 背景
`toAgentTool()`（把外部插件转 `{name,description,inputSchema}`）+ 具名执行任意插件（`buddy launcher run` → IPC `launcher_debug_run_plugin`）此前**只服务 in-app AI 路由**（selectWithTools）。外部 AI（Claude Code 等）无法发现 + 调用 buddy 的插件能力。需求：一个 CLI 把每个启用插件能力暴露给 AI + 人类，插件零适配，启停自动反映。

## 决策（方案 B）
1. **顶层 `buddy tools` + `buddy run`**（非嵌套 launcher 子命令）：短而稳定的 AI 契约面，AI tool description 里干净。
2. **CLI + JSON manifest，不上 MCP**（用户明确选）：AI harness 自己实现「读 manifest → shell-out 调 run」循环；无 MCP server 打包/维护成本。
3. **manifest + 执行均经 socket IPC 到常驻 app**：CLI Foundation-only **不依赖 BuddyCore**（[[2026-04-14-cli-foundation-only-no-buddycore]]）→ 不能调 `toAgentTool()`/`PluginManager`，**必须 IPC 让 app 算** manifest，CLI 只转发。
4. **新增 2 隔离 IPC action**：`launcher_list_tools`（manifest live 算自 `PluginManager.list()`，启停自动反映）+ `launcher_run_tool`（富 JSON 含 image base64/candidates）。**不动 `launcher_debug_run_plugin`**（瘦契约，`buddy launcher run` 零变化，C-DEBUG-ISOLATION）。
5. **manifest 条目 camelCase 手构 dict**（`{name,summary,description,inputSchema,mode}`）：**不用 AgentTool 的 Codable**（其 JSON key 是 snake `input_schema`，会泄漏到对外契约）。
6. **抽 `runPluginCore` 共享执行核**（find + TOFU + execute），debug/run 两 handler 只差序列化，消 duplication。
7. **内置插件（Calculator/Paste/Screenshot/AppLauncher/SystemCommand）不入 manifest**：逐个审判 0 高 AI 必要（冗余 / bash 等价 / 候选列表形状不符 / GUI 阻塞）。future AI 截图走 command-mode 社区插件，不硬扭 GUI 内置。

## 理由
gap 很窄（toAgentTool + run 已存在，只是没对外）；IPC 复用全执行链（TOFU/deps/图片通道）零 duplication；manifest 在 app 侧 live 计算 → 启停天然反映，无需动态 CLI verb 解析。`selectWithTools` 已证枚举式 schema 对弱模型友好，manifest 直接复用同款 `synthesizeToolDescription` + `effectiveToolInputSchema`。

## 后果
- **契约冻结 10 条 C-***（camelCase inputSchema、stdout_truncated、not trusted、C-TOFU-NOBYPASS、C-INPUT-CONTRACT 等），AI 依赖的对外字段不得漂移（红队 场景7 稳定性守护）。
- **红蓝对抗抓到 1 真 bug**：蓝队 `runPluginCore` 把 `--input` 整串塞 PluginInput.query 而非提取 `.query`（R05b，C-INPUT-CONTRACT 违规）→ 修：core 改收 `resolvedQuery`，run_tool 解析 JSON 提取，坏 JSON 报错（顺带消 CONTRACT_AMBIGUITY）。
- **TOFU modal 与 CLI timeout 冲突** → sendQuery 双超时（见 `patterns/2026-07-16-tofu-modal-sendquery-timeout-split-connect-execute.md`）。
- **延期**：web 端 AI 使用指南（先落 CLAUDE.md）、manifest 版本/hash（YAGNI）。

## 关联
- 前置（toAgentTool 源）：`2026-06-29-select-with-tools-plugin-as-llm-tool.md`
- IPC 约束：`decisions/2026-04-14-cli-foundation-only-no-buddycore.md` + `patterns/2026-05-26-buddycli-inline-subcommand-no-buddycore-dep.md`
- 同期 timeout 教训：`patterns/2026-07-16-tofu-modal-sendquery-timeout-split-connect-execute.md`
- brainstorm 共识：`.autopilot/requirements/20260716-插件能力cli-hub/brainstorm.md`
