---
id: "003-marketplace-manager-replace-builtin"
depends_on: ["001", "002"]
---

# Task 003 — MarketplaceManager 替换 installBundledPlugins

## 目标（一句话）

新建 MarketplaceManager（seedFromBundle/syncFromRemote/install/migrateLegacy/reseed/inspect），LauncherManager.setup 切换调用，删除 PluginManager.installBundledPlugins；migrateLegacy 两阶段（先复制新目录+新 trust，再删旧），幂等。

## 架构上下文

- 依赖 001（MarketplaceManifest）+ 002（PluginSourceResolver）
- 本 task 完成后 `Sources/.../Plugins/` 目录可删，`Package.swift` 的 `.copy("Plugins")` 一并删
- 关键：老用户 `~/.buddy/launcher-plugins/builtin-translate/` 必须无感迁移，trust 不丢

## 输入

- `MarketplaceManifest` (task 001)
- `PluginSourceResolver` (task 002)
- 现有 `PluginManager.installBundledPlugins`（待删）
- 现有 `TrustStore` + `TrustRecord(pluginName, trustKey, approvedAt)`

## 输出契约

### 新建 `Sources/ClaudeCodeBuddy/Launcher/Marketplace/MarketplaceManager.swift`

```swift
struct MarketplaceInspection: Codable {
    let plugins: [PluginInspection]
    let lastSyncedAt: Date?
    let consecutiveSyncFailures: Int
    
    struct PluginInspection: Codable {
        let name: String
        let version: String
        let enabled: Bool      // !contains .disabled
        let source: String     // human-readable
    }
}

final class MarketplaceManager {
    static let shared: MarketplaceManager
    
    /// 首启时调；幂等。
    /// 1. 从 BuddyCore.bundle/Marketplace/marketplace.json 读 seed
    /// 2. 拷贝到 ~/.buddy/marketplace.json（如果不存在或 schemaVersion 升级）
    /// 3. 遍历 plugins[]，按 source 用 PluginSourceResolver 解析到临时/bundle URL
    /// 4. 拷贝到 ~/.buddy/launcher-plugins/<name>/ （如果不存在）
    /// 5. 保留现有 .disabled 标记
    /// 失败抛 LauncherError；UI error 态展示
    func seedFromBundle() throws
    
    /// 异步从 GitHub Raw 拉远程 marketplace.json
    /// - 1h debounce（读 ~/.buddy/marketplace-lastSyncedAt，未到 1h 跳过）
    /// - JSONDecoder 失败：本地 cache 不写，consecutiveSyncFailures += 1
    /// - schemaVersion 不兼容：cache 不写，HUD 提示"需升级 app"
    /// - 成功：写 cache，consecutiveSyncFailures = 0
    /// - diff 非空：MarketHUD.show（task 006 提供，本 task 用 print 占位）
    /// - 每次执行追加结构化 JSON 行到 ~/.buddy/launcher-sync.log
    func syncFromRemote() async
    
    /// CLI / UI 重装按钮
    /// 从当前 marketplace.json 找到 entry，用 PluginSourceResolver 解析，覆盖 ~/.buddy/launcher-plugins/<name>/
    func install(name: String) async throws
    
    /// 老 builtin 迁移：两阶段，幂等
    /// Phase 1（写新）:
    ///   1a. 若 ~/.buddy/launcher-plugins/builtin-translate 存在 + ~/.buddy/launcher-plugins/translate 不存在
    ///       → cp -r builtin-translate translate；改 translate/plugin.json 的 name 字段为 "translate"
    ///   1b. 若 launcher-trust.json 含 pluginName="builtin-translate" + 不含 pluginName="translate"
    ///       → 复制一条 TrustRecord(pluginName="translate", trustKey 保留)
    ///   builtin-hello 同步
    /// Phase 2（删旧）:
    ///   2a. 若 ~/.buddy/launcher-plugins/translate 存在 + builtin-translate 存在 → rm -rf builtin-translate
    ///   2b. 若 launcher-trust.json 含 pluginName="translate" → 删 pluginName="builtin-translate"
    /// 任一阶段失败：log 并继续，下次启动重跑
    func migrateLegacy() throws
    
    /// CLI `buddy launcher reseed`
    /// 强制重新调 seedFromBundle，但保留 .disabled 标记不动
    func reseed() throws
    
    /// 导出当前 marketplace 状态供 QA 断言
    func inspect() throws -> MarketplaceInspection
}
```

### 修改 `LauncherManager.setup()`

```diff
- Task.detached {
-     do {
-         try PluginManager.shared.installBundledPlugins()
-     } catch {
-         NSLog("[Launcher] installBundledPlugins failed: \(error)")
-     }
- }
+ Task.detached {
+     do {
+         try MarketplaceManager.shared.migrateLegacy()
+         try MarketplaceManager.shared.seedFromBundle()
+         await MarketplaceManager.shared.syncFromRemote()
+     } catch {
+         NSLog("[Launcher] marketplace setup failed: \(error)")
+     }
+ }
```

### 删除

- `PluginManager.installBundledPlugins()` 方法
- `Sources/ClaudeCodeBuddy/Plugins/` 目录
- `Package.swift` 的 `.copy("Plugins")` 行

## 验收标准

### 自动化测试（红队）

1. **seedFromBundle 幂等**：连续调 2 次，第 2 次不报错、不重写已存在的 plugin
2. **seedFromBundle 失败**：mock bundle 无 marketplace.json → throw
3. **syncFromRemote 1h debounce**：第 1 次拉成功 + 第 2 次立即调 → 不发请求
4. **syncFromRemote malformed JSON**：mock server 返回非法 JSON → 本地 cache 不写，consecutiveSyncFailures = 1
5. **syncFromRemote schemaVersion 不兼容**：返回 schemaVersion=99 → cache 不写
6. **migrateLegacy Phase 1**：手动建 builtin-translate 目录 + 老 trust 记录 → 调 migrateLegacy → 新目录存在 + 新 trust 存在
7. **migrateLegacy Phase 2**：Phase 1 完成后再调 → 旧目录删 + 旧 trust 删
8. **migrateLegacy 幂等**：连续调 N 次结果相同
9. **migrateLegacy crash 模拟**：Phase 1 写完新目录后人工删除 → 再调 → 应能正确清理孤儿
10. **install(name) 不在 marketplace**：throw pluginNotFound
11. **inspect 输出含 enabled=true**：seed 完后调 inspect → translate enabled=true
12. **reseed 保留 .disabled**：禁用 translate（建 .disabled 文件） → reseed → .disabled 仍在

### 验证命令

```bash
cd apps/desktop && swift build && swift test --filter MarketplaceManager
```

### Tier 1.5 真实场景

```bash
# 场景 1：首启离线可用
rm -rf ~/.buddy && open ClaudeCodeBuddy.app && sleep 3
test -f ~/.buddy/launcher-plugins/translate/plugin.json
grep -q '"name": "translate"' ~/.buddy/launcher-plugins/translate/plugin.json

# 场景 2：老用户迁移
rm -rf ~/.buddy && mkdir -p ~/.buddy/launcher-plugins/builtin-translate
echo '{"name":"builtin-translate","mode":"prompt","systemPrompt":"x","maxIterations":1}' > ~/.buddy/launcher-plugins/builtin-translate/plugin.json
echo '[{"pluginName":"builtin-translate","trustKey":"prompt:abc","approvedAt":"2026-01-01T00:00:00Z"}]' > ~/.buddy/launcher-trust.json
open ClaudeCodeBuddy.app && sleep 3
test -d ~/.buddy/launcher-plugins/translate
test ! -d ~/.buddy/launcher-plugins/builtin-translate
jq -e '.[] | select(.pluginName=="translate")' ~/.buddy/launcher-trust.json
test "$(jq '[.[] | select(.pluginName=="builtin-translate")] | length' ~/.buddy/launcher-trust.json)" = "0"
```

## 下游须知（handoff 要点）

- `MarketHUD` 在本 task 用 NSLog 占位，task 006 提供实现后替换
- `disable/enable` 不本 task 实现（task 004），inspect 中的 `.disabled` 检查仅判存在性
- `lastSyncedAt` 持久化到 `~/.buddy/marketplace-meta.json`（含 lastSyncedAt + consecutiveSyncFailures）
