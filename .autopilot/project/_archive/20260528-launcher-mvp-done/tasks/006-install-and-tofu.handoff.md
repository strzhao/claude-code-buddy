# 006-install-and-tofu handoff

## 实现摘要

task 006 完成启动器插件安装 + TOFU 信任 + NSAlert 弹框：TrustStore singleton（SHA256 trustKey 包含 cmd+args+exe，任一改动失效）/ TrustPrompt @MainActor NSAlert 2 按钮（允许/拒绝） / LauncherError +pluginNotTrusted / LauncherManager.submit toolExecutor 注入 trust check（PluginExecutor.execute 之前） / BuddyCLI 4 子命令（add/list/remove/inspect）内联。Tier 0 红队 20 ✅ + Tier 1 unit/build/lint ✅ + Tier 1.5 真实场景 10/10 ✅，全套 856 tests 0 failures，contract-checker PASS。

## 关键文件路径

```
apps/desktop/Sources/ClaudeCodeBuddy/Launcher/Plugin/
├── TrustStore.swift            # [新] singleton + trustKey static + isTrusted/approve/remove/list/checkAndPrompt + ~/.buddy/launcher-trust.json
└── TrustPrompt.swift           # [新] @MainActor NSAlert + NSApp.activate + 允许/拒绝

apps/desktop/Sources/ClaudeCodeBuddy/Launcher/
├── LauncherError.swift         # [修改] +case pluginNotTrusted(String) + 中文 errorDescription
└── LauncherManager.swift       # [修改] toolExecutor 内调用 await TrustStore.shared.checkAndPrompt(manifest, executablePath:)

apps/desktop/Sources/BuddyCLI/main.swift
                                # [修改] +buddyHomeDir($HOME?fallback NSHomeDirectory) + 4 子命令内联实现
                                #   cmdLauncherAdd（git clone --depth 1 + 60s DispatchWorkItem 超时 + plugin.json 校验 + 失败回滚）
                                #   cmdLauncherList（扫描 + 计算 trustKey + 比对 trust.json → trusted/untrusted/never_run）
                                #   cmdLauncherRemove（rm -rf + 同步清 trust.json）
                                #   cmdLauncherInspect（输出 JSON 含 trust_status / install_path）

apps/desktop/Tests/BuddyCoreTests/Launcher/
├── TrustStoreTests.swift                       # [新] 蓝队 11 单元（trustKey/approve/remove/0644/cmd 变化失效）
├── TrustStoreAcceptanceTests.swift             # [新] 红队 11 验收 (SC-01..SC-10，含 Python3 跨语言独立复现算法)
└── LauncherCLILauncherAcceptanceTests.swift    # [新] 红队 9 CLI subprocess (SC-CLI-01..SC-CLI-09，HOME 隔离)
```

## 下游须知

### Task 007 (e2e-and-docs) 接入

task 006 + 005 之后，launcher 完整流（快捷键 → 路由 → trust check → plugin 执行）已可端到端使用。task 007 应：

1. **端到端 E2E 测试**：
   - 启动 app → ⌘⇧Space 弹框 → 输入 query → router 缩候选 → AI 选 plugin → 首次执行弹 NSAlert → 允许后 PluginExecutor 跑通
   - 用 builtin-hello（task 004 bundled plugin）作为标准 E2E 路径
   - 模拟未信任路径：清空 trust.json + 弹 NSAlert（手动验证）

2. **用户文档**：
   - README 增 `~/.buddy/launcher.json` 配置模板
   - 增 `buddy launcher add stringzhao/some-plugin` 安装示例
   - 增 TOFU 安全说明（trustKey 算法 + 信任失效场景）
   - 增故障排查（trust.json 损坏 / 快捷键冲突 / SecretStore 探针降级）

3. **构建/发布**：
   - 确认 make bundle 完整 LauncherWindow + Trust* 都在
   - 更新 homebrew/Casks/claude-code-buddy.rb 配方（version 已升 0.25.0）
   - .autopilot 完整提交，包含 task 001-006 全部归档

### 集成点

- TrustStore.shared 单例 + LauncherConstants.buddyDir.appendingPathComponent("launcher-trust.json")
- LauncherManager.submit 当前已注入 trust check（task 006 验证 LauncherManager.swift:186-190）
- BuddyCLI 通过 `$HOME` 环境变量隔离测试（生产语义不变）

## 偏差说明

无偏差。所有契约项 contract-checker PASS，0 mismatch。

实现层修复 2 项低优先级 qa-reviewer 建议（机会修复，非必需）：
- 删除 TrustStore 中未使用的 DispatchQueue 字段（B-1）
- BuddyCLI add 增加 `.` 前缀校验防御（B-3）

未修复 1 项设计取舍：
- TrustStore.checkAndPrompt 中 `try? approve` 错误静默（B-2）：若用户允许但 approve 失败，下次执行仍会弹框，属 fail-safe，非安全漏洞，保留当前实现。

## 已知限制（handoff 标注）

- 仅 HTTPS git clone（无 SSH 格式 `git@github.com:user/repo`）— MVP 接受
- ~/.buddy/launcher-trust.json 并发写无锁（CLI + app 同时写 race）— MVP 接受
- 无 `buddy launcher update` / `buddy launcher search` — v2+
