# Launcher 子系统 — SC 覆盖矩阵

> Task 007 (端到端验收 + Snapshot 测试 + 文档) 归档。
> 验证 12 个 PRD 验收场景在现有 864 tests 中的覆盖映射，作为 future audit 追溯入口。

## 矩阵总览

| SC | 验收场景 | 覆盖测试文件 | 关键测试方法 / 路径 | 状态 |
|---|---|---|---|---|
| SC-01 | 全局快捷键召唤与隐藏浮窗 | `LauncherHotkeyAcceptanceTests.swift`<br>`LauncherManagerAcceptanceTests.swift` | `apps/desktop/tests/BuddyCoreTests/Launcher/` | ✅ 已覆盖 |
| SC-02 | BYOK Anthropic API Key 持久化 | `LauncherConfigAcceptanceTests.swift`<br>`SecretStoreAcceptanceTests.swift`<br>`SecretStoreFactoryAcceptanceTests.swift` | Keychain → EncryptedFile 探针降级路径 | ✅ 已覆盖 |
| SC-03 | 直接对话 Markdown 流式渲染 | `MarkdownStreamingAcceptanceTests.swift`<br>`LauncherAgentAcceptanceTests.swift` | AsyncStream + delta 拼接 | ✅ 已覆盖 |
| SC-04 | 插件安装与 TOFU 弹框 | `LauncherCLILauncherAcceptanceTests.swift` (SC-CLI-02)<br>`TrustStoreAcceptanceTests.swift` (SC-04) | CLI subprocess + HOME 隔离 | ✅ 已覆盖 |
| SC-05 | TOFU 允许后插件执行 | `TrustStoreTests.swift` (approve+isTrusted)<br>`PluginRuntimeAcceptanceTests.swift` | trust.json 0644 + 后续 isTrusted true | ✅ 已覆盖 |
| SC-06 | TOFU 拒绝插件不执行 | `TrustStoreAcceptanceTests.swift` (SC-04 反例)<br>`LauncherManager.swift` (grep `checkAndPrompt`) | trust check 注入点验证 | ✅ 已覆盖 |
| SC-07 | 未配置 provider 错误 | `LauncherManagerAcceptanceTests.swift` | `errorStream(.providerNotConfigured)` | ✅ 已覆盖 |
| SC-08 | 每次唤起为新 Session | `LauncherAgentAcceptanceTests.swift` | 每次 submit 创新 UUID sessionId | ✅ 已覆盖 |
| SC-09 | buddy launcher remove 卸载 | `LauncherCLILauncherAcceptanceTests.swift` (SC-CLI-04 / SC-CLI-09) | rm -rf + 同步清 trust.json | ✅ 已覆盖 |
| **SC-10** | **Launcher 与像素猫互不干扰** | **`LauncherIsolationTests.swift` (蓝)<br>`LauncherIsolationAcceptanceTests.swift` (红)** | **路径隔离 + 类型依赖 + 全局状态 + TrustStore 路径** | **✅ task 007 新增** |
| SC-11 | inspect 查看插件详情 JSON | `LauncherCLILauncherAcceptanceTests.swift` (SC-CLI-08) | JSON 含 trust_status / install_path | ✅ 已覆盖 |
| SC-12 | 本地 Ollama 配置与失联错误 | `LauncherProviderAcceptanceTests.swift`<br>`LauncherConfigAcceptanceTests.swift` | kind=openai-compatible + base-url 路径 | ✅ 已覆盖 |

## SC-10 隔离测试详情（task 007 唯一新增）

### 蓝队：`LauncherIsolationTests.swift`

静态契约断言，不依赖 NSApp 运行时（CI 友好）：

| 方法 | 验证点 |
|---|---|
| `test_SC10_pathsDoNotOverlap_withBuddySocketAndColorFile()` | `LauncherConstants.buddyDir` 不与 `/tmp/claude-buddy.sock` / `/tmp/claude-buddy-colors.json` 重叠 |
| `test_SC10_launcherManager_doesNotDependOn_catSubsystem()` | `LauncherManager.swift` 源码 grep 不含 `SessionManager` / `BuddyScene` / `CatSprite` / `FoodManager` / `BuddyEvent` |
| `test_SC10_launcherManager_doesNotModifyGlobalAppState()` | `LauncherManager.swift` 不调用 `NSApp.terminate` / `setActivationPolicy` / `NSApplication.shared.terminate` |
| `test_SC10_trustStore_pathIndependent_fromBuddyColorFile()` | `TrustStore` 路径在 `~/.buddy/launcher-trust.json`（沙盒模式 XCTSkip 兜底） |

### 红队：`LauncherIsolationAcceptanceTests.swift`

独立视角验证（不读蓝队实现代码）：

| 方法 | 验证点 |
|---|---|
| `test_SC10_pathNamespace_launcherAndPixelCat_noIntersection()` | `Set.intersection` 形式比对两子系统所有路径 |
| `test_SC10_launcherSources_noDependencyOn_pixelCatTypes()` | grep 所有 Launcher 子目录 `.swift` 文件，禁止符号 |
| `test_SC10_buddyDir_prefixIsHomeDir_notTmp()` | `buddyDir` 以 `NSHomeDirectory()` 开头，不以 `/tmp` 开头 |
| `test_SC10_launcherSources_noHardcodedPixelCatTmpPaths()` | Launcher 源文件无硬编码 `/tmp/claude-buddy` 字符串 |

## 测试统计

- **现有 launcher 测试文件**: 32 个（涵盖 11/12 SC）
- **task 007 新增**: 2 个隔离测试文件（蓝 4 测试 + 红 4 测试）
- **测试套件总计**: 864 tests（task 006 末态 856 → +8 隔离测试）
- **隔离测试覆盖率**: SC-10 双视角（静态契约 + 独立 grep 验证）

## 维护说明

后续测试文件重命名时需同步更新本矩阵。建议通过 `autopilot doctor` 命令检查 SC ↔ 测试文件映射的一致性。
