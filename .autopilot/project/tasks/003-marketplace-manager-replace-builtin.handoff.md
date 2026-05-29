# Task 003 Handoff — MarketplaceManager 替换 installBundledPlugins

## 实现摘要

buddy-plugin-market 项目的核心 runtime 切换点。删除 `PluginManager.installBundledPlugins()` 旧 builtin-plugin 路径，新建 `MarketplaceManager` 统一管理 bundle seed + remote sync + 老用户迁移。**老用户体验无感**：`~/.buddy/launcher-plugins/builtin-translate/` + `launcher-trust.json` 的 pluginName 自动迁移到新 "translate"，trustKey 不变（prompt-mode trustKey 不依赖 pluginName，已验证）。

**5 BLOCKER 全部修复落地**：
- B1: migrateOne 每 Phase（1/1.5/2）入口重新 read state，不复用前 Phase 变量（5 行幂等性矩阵覆盖任意 crash 点重启行为）
- B2: addRecord extension 写在 TrustStore.swift 同文件（Swift 同文件 extension 可访问 private）
- B3: installPlugin replacing=false + targetExists → skip + log（sideloaded conflict 不抛错）
- B4: MarketplaceInspection 双视角：`plugins`（marketplace cache）+ `sideloadedPlugins`（目录扫描未覆盖）
- B5: MarketplaceManager.init 注入 trustStore

## 文件变更（commit a0aabce）

**新增**:
- `Sources/.../Launcher/Marketplace/MarketplaceManager.swift`（~470 行：6 公开方法 + 私有 helpers）
- `tests/.../Launcher/MarketplaceManagerTests.swift`（蓝队 12 单测，含 UnitStubResolver + UnitMockURLProtocol）
- `tests/.../MarketplaceManagerAcceptanceTests.swift`（红队 20 AT，独立 MockURLProtocol）

**修改**:
- `TrustStore.swift`：同文件末尾追加 `addRecord(_:)` extension
- `PluginManager.swift`：删 `installBundledPlugins()` + `installBundledPlugin(bundleSubdir:targetName:)`
- `LauncherManager.swift`：setup rewire migrateLegacy → seedFromBundle → syncFromRemote 三步链
- `Package.swift`：删 `.copy("Plugins")`，保留 `.copy("Marketplace")`
- 2 个旧测试文件：删 `BuiltinTranslateAcceptanceTests` SC-6/7/8 + `PluginBundledHelloAcceptanceTests` class

**删除**:
- `Sources/.../Plugins/HelloPlugin/` 整目录（README + hello.sh + plugin.json）
- `Sources/.../Plugins/TranslatePlugin/plugin.json`

## 验证证据

- swift build: PASS
- swift test --filter "Marketplace|PluginRuntime|BuiltinTranslate": **66 tests / 0 failures**
- SwiftLint --strict: PASS（0 violations / 103 files）
- contract-checker: PASS（1 个 low 文字笔误）
- **Tier 1.5 5/5 真实场景 PASS**（headless app boot 验证）：
  - S1 首启离线可用：translate + hello + marketplace.json + plugins 完整创建
  - S2 老用户迁移：trustKey 不变 + 旧 record 删 + 新 record 加（验证 prompt-mode trustKey 与 pluginName 解耦）
  - S3-S4 静态契约（installBundledPlugins / Plugins/ / .copy("Plugins") 全删）
  - S5 launcher-sync.log 结构化 JSON 写入
- qa-reviewer Section A 12/12 + Section B 3 个 ≥80 follow-up（不阻塞）

## 下游须知

### task 004 (disable/enable) 直接复用

- `PluginManager.list()` 已能扫到 `~/.buddy/launcher-plugins/` 含 translate / hello
- 加 `.disabled` 标记文件后，list() 应过滤；MarketplaceInspection.PluginInspection.enabled 字段已就位（task 003 inspect 已扫描 .disabled）
- `PluginManager` 需新增 `disable(name:) / enable(name:) / disabledNames()` 方法
- `MarketplaceManager.inspect()` 中 PluginInspection.enabled 已正确反映 .disabled，无需改

### task 005/006/007 复用

- task 005 UI 用 `MarketplaceManager.shared.inspect()` 获取 plugins + sideloadedPlugins 双视角
- task 006 后台 sync 用 `MarketplaceManager.shared.syncFromRemote()`；HUD 提示替代当前 `NSLog` 占位
- task 007 CLI `buddy launcher reseed` 调 `MarketplaceManager.shared.reseed()`，`install/list --json` 调 `install/inspect`

### Tier 1.5 fixture 文档错误警告

**设计文档 Tier 1.5 脚本中 trust.json fixture 用了 flat array `[{...}]`，实际 TrustStore schema 是 `{"records":[...]}` nested wrapper**。后续 task 设计真实场景验证时**必须用正确格式**：

```bash
cat > ~/.buddy/launcher-trust.json <<'JSON'
{"records":[{"trustKey":"...","pluginName":"...","approvedAt":"2026-01-01T00:00:00Z"}]}
JSON
```

### 3 个 ≥80 follow-up（不影响契约，task 004+ 顺手处理）

1. **syncFromRemote 无并发互斥**：同进程并发 install/reseed/sync 会双写 cache + 双 append log。建议加 actor 或 NSLock 包 syncFromRemote 主体。
2. **appendSyncLog 无 flock**：多 app 实例并发写撕裂 JSON 行。建议 O_APPEND open(2) 或文档单实例假设。
3. **temp dir 清理判定**：`path.contains("buddy-resolver-")` 比子串而非前缀。建议 `path.hasPrefix(NSTemporaryDirectory())` + `lastPathComponent.hasPrefix("buddy-resolver-")` 严格化。

### Worktree stale .app 警告

**注意**：主仓库根 `/Users/stringzhao/workspace/claude-code-buddy/ClaudeCodeBuddy.app` 是 May 4 stale 旧版本。worktree 开发必须用 `apps/desktop/ClaudeCodeBuddy.app`（fresh `make bundle` 产出）。

## 偏差说明

- renamePluginJSON 用 JSONSerialization 而非 PluginManifest decode/encode（设计文档 #4 允许此简化，因 PluginManifest.name 是 `let`）
- 删 2 个旧测试文件（SC-6/7/8 + PluginBundledHelloAcceptanceTests class）：旧测试依赖已删方法，无等价价值（被新 MarketplaceManagerTests 覆盖）
- **无契约偏差**。
