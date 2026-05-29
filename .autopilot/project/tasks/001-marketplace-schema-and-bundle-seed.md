---
id: "001-marketplace-schema-and-bundle-seed"
depends_on: []
---

# Task 001 — Marketplace schema + bundle seed 迁移

## 目标（一句话）

定义 MarketplaceManifest schema（含 PluginSourceConfig 多态 enum），把 Sources/.../Plugins/{HelloPlugin,TranslatePlugin}/ 迁到 Sources/.../Marketplace/plugins/{hello,translate}/，新建 marketplace.json (seed)，plugin.json `name` 字段同步改为 `hello`/`translate`。

## 架构上下文

- 这是 DAG 第 1 个 task，零依赖
- 仅做 schema 定义 + 文件搬运，不动 runtime 代码
- 保留 `Sources/.../Plugins/` 目录与 `Package.swift` 的 `.copy("Plugins")` 兼容，task 003 删（避免本 task 引起 installBundledPlugins crash）

## 输入

- `apps/desktop/Sources/ClaudeCodeBuddy/Plugins/TranslatePlugin/plugin.json`（含 `name: "builtin-translate"`）
- `apps/desktop/Sources/ClaudeCodeBuddy/Plugins/HelloPlugin/plugin.json`（含 `name: "builtin-hello"`）

## 输出契约

### 新建文件

#### `Sources/ClaudeCodeBuddy/Launcher/Marketplace/MarketplaceManifest.swift`

```swift
struct MarketplaceManifest: Codable, Equatable {
    let schemaVersion: Int    // == 1
    let name: String          // "buddy-official"
    let description: String?
    let owner: MarketplaceOwner
    let plugins: [MarketplacePlugin]
}

struct MarketplaceOwner: Codable, Equatable {
    let name: String
    let email: String?
    let homepage: String?
}

struct MarketplacePlugin: Codable, Equatable {
    let name: String          // 全局唯一，对应 plugin.json.name
    let description: String
    let version: String       // semver
    let category: String?
    let author: MarketplaceAuthor
    let source: PluginSourceConfig
    let homepage: String?
    let editable: Bool?       // phase 2 预留
}

struct MarketplaceAuthor: Codable, Equatable {
    let name: String
    let email: String?
}

enum PluginSourceConfig: Equatable {
    case localSubdir(path: String)                                              // "./plugins/translate"
    case gitSubdir(url: String, path: String, ref: String, sha: String)
    case gitURL(url: String, sha: String?)
    case file(path: String)
}

// PluginSourceConfig 自定义 Codable
// JSON: string "./xxx" → .localSubdir
// JSON: {source: "git-subdir", url, path, ref, sha} → .gitSubdir
// JSON: {source: "url", url, sha?} → .gitURL
// JSON: {source: "file", path} → .file
```

#### `Sources/ClaudeCodeBuddy/Marketplace/marketplace.json` (seed)

```json
{
  "$schema": "https://stringzhao.dev/claude-code-buddy/marketplace.schema.json",
  "schemaVersion": 1,
  "name": "buddy-official",
  "description": "Claude Code Buddy 官方插件目录",
  "owner": {
    "name": "stringzhao",
    "homepage": "https://github.com/stringzhao/claude-code-buddy"
  },
  "plugins": [
    {
      "name": "hello",
      "description": "Hello world demo",
      "version": "0.1.0",
      "category": "example",
      "author": {"name": "stringzhao"},
      "source": "./plugins/hello"
    },
    {
      "name": "translate",
      "description": "中英互译助手",
      "version": "0.1.0",
      "category": "productivity",
      "author": {"name": "stringzhao"},
      "source": "./plugins/translate",
      "homepage": "https://github.com/stringzhao/claude-code-buddy/tree/main/marketplace/plugins/translate"
    }
  ]
}
```

#### `Sources/ClaudeCodeBuddy/Marketplace/plugins/translate/plugin.json`

完全复制 `Plugins/TranslatePlugin/plugin.json`，仅改 `"name": "builtin-translate"` → `"name": "translate"`。

#### `Sources/ClaudeCodeBuddy/Marketplace/plugins/hello/plugin.json`

完全复制 `Plugins/HelloPlugin/plugin.json`，仅改 `"name": "builtin-hello"` → `"name": "hello"`。

### 修改文件

#### `Package.swift`

```diff
 resources: [
   .copy("Assets"),
-  .copy("Plugins")        // 保留兼容，task 003 删
+  .copy("Plugins"),       // 保留兼容，task 003 删
+  .copy("Marketplace")
 ]
```

## 验收标准

### 自动化测试（红队）

1. **Codable round-trip — 4 种 source 类型**
   - `MarketplacePlugin(source: .localSubdir(path: "./plugins/translate"))` → JSON → decode → equal
   - `.gitSubdir(...)`、`.gitURL(...)`、`.file(...)` 同上
2. **解析真实 seed marketplace.json**：`Bundle.module.url(forResource: "marketplace", withExtension: "json", subdirectory: "Marketplace")` 读出后 decode 成功，含 2 个 plugin（hello + translate）
3. **schemaVersion 字段必填**：decoder 缺 schemaVersion → throw
4. **source 字符串/对象互斥**：JSON 里 source 既不是字符串也不是合法对象 → throw

### 验证命令

```bash
cd apps/desktop && swift build && swift test --filter MarketplaceManifest
```

期望：build PASS + tests 全绿。

### Tier 1.5 真实场景

```bash
# 场景 1：编译 + 资源就位
swift build
test -f .build/arm64-apple-macosx/debug/ClaudeCodeBuddy_BuddyCore.bundle/Marketplace/marketplace.json
test -f .build/arm64-apple-macosx/debug/ClaudeCodeBuddy_BuddyCore.bundle/Marketplace/plugins/translate/plugin.json

# 场景 2：name 字段已迁移
grep -q '"name": "translate"' .build/arm64-apple-macosx/debug/ClaudeCodeBuddy_BuddyCore.bundle/Marketplace/plugins/translate/plugin.json

# 场景 3：旧 Plugins 仍兼容（task 003 才删）
test -f .build/arm64-apple-macosx/debug/ClaudeCodeBuddy_BuddyCore.bundle/Plugins/TranslatePlugin/plugin.json
```

## 下游须知（handoff 要点）

- `MarketplaceManifest`、`PluginSourceConfig` 是后续所有 task 的核心类型
- bundle 内 `Marketplace/` 子目录路径 = `Bundle.module.url(forResource:..., subdirectory: "Marketplace")`
- 旧 `Plugins/` 目录与 `installBundledPlugins` **本 task 不动**，task 003 负责清理
