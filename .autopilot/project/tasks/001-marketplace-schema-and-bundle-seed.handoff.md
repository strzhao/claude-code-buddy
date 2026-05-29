# Task 001 Handoff — MarketplaceManifest schema + bundle seed 迁移

## 实现摘要

定义 marketplace 协议数据层（5 个 Codable+Equatable 类型 + PluginSourceConfig 多态 Codable 自定义实现），把 `Sources/.../Plugins/{HelloPlugin,TranslatePlugin}/` 迁移为 `Sources/.../Marketplace/plugins/{hello,translate}/`，plugin.json `name` 字段同步改为 `hello`/`translate`。bundle 内同时保留旧 `Plugins/` 目录（task 003 才删），确保本 task 不破坏 installBundledPlugins runtime 路径。

**关键设计选择**：
- PluginSourceConfig 自定义 Codable：decode 先 try `singleValueContainer().decode(String.self)`（命中 `.localSubdir` 简写），失败再 try keyed container 按 `source` 字段分发 `git-subdir` / `url` / `file`；encode 对 `.localSubdir` 走 singleValueContainer 输出裸字符串
- schemaVersion=1 字段必填，为 phase 2 演进留出兼容空间
- `editable: Bool?` phase 2 预留，phase 1 不暴露

## 文件变更（commit 9032631）

**新建**：
- `apps/desktop/Sources/ClaudeCodeBuddy/Launcher/Marketplace/MarketplaceManifest.swift`（5 类型 + 自定义 Codable）
- `apps/desktop/Sources/ClaudeCodeBuddy/Marketplace/marketplace.json`（seed，含 hello + translate）
- `apps/desktop/Sources/ClaudeCodeBuddy/Marketplace/plugins/hello/plugin.json`（name=hello，基于 HelloPlugin/plugin.json）
- `apps/desktop/Sources/ClaudeCodeBuddy/Marketplace/plugins/translate/plugin.json`（name=translate，基于 TranslatePlugin/plugin.json）

**测试**：
- `apps/desktop/tests/BuddyCoreTests/MarketplaceManifestTests.swift`（蓝队 10 单测）
- `apps/desktop/tests/BuddyCoreTests/MarketplaceManifestAcceptanceTests.swift`（红队 15 AT）

**修改**：
- `apps/desktop/Package.swift`（resources 加 `.copy("Marketplace")`，**保留** `.copy("Plugins")` 兼容）

## 验证证据

- swift build: PASS
- swift test --filter MarketplaceManifest: **25 tests / 0 failures / 0.003s**
- SwiftLint --strict: PASS (0 violations / 101 files)
- contract-checker: PASS（1 个 low severity 注释建议，不阻塞）
- Tier 1.5 6 个真实场景全部 PASS（E=N=6）
- qa-reviewer Section A 6/6 设计符合 + Section B 0 重大问题

## 下游须知

### task 002 (PluginSourceResolver)
- 直接 import 并使用 `PluginSourceConfig` enum（4 cases 已稳定）
- 解析 git-subdir/git-url 时复用 `BuddyCLI/main.swift:1117` 附近的 git clone Process 实现
- localSubdir 解析需传入 `bundleRoot: URL?`；测试时可 mock Bundle.module

### task 003 (MarketplaceManager)
- bundle 内 marketplace 资源路径：`Bundle.module.url(forResource: "marketplace", withExtension: "json", subdirectory: "Marketplace")`
- 子目录访问：`Bundle.module.url(forResource: "plugin", withExtension: "json", subdirectory: "Marketplace/plugins/translate")`
- 旧 `Plugins/` 目录与 `Package.swift` 的 `.copy("Plugins")` **本 task 完成时仍存在**，task 003 删除时记得：
  1. 改 `Package.swift` 删 `.copy("Plugins")` 这一行（同时保留 `.copy("Marketplace")`）
  2. 删 `Sources/.../Plugins/` 目录
  3. 删 `PluginManager.installBundledPlugins()` 方法

### 通用
- `MarketplaceManifest` 是纯数据层，**不引用** runtime 类型（PluginManager / TrustStore 等）
- JSONEncoder 默认会把 `/` 转义为 `\/`，断言时用解码值比对而非字符串字面量比对
- `name` 字段约束 `[a-z0-9-]+` 仅在契约文档，**未运行时校验**；后续 task 可考虑加 validate 方法

## 偏差说明

无契约偏差。红队 AT01 测试断言从"字符串字面量等值"放宽为"解码值相等"，因 Foundation JSONEncoder `/` 转义为合法 JSON 但非字节相等——这是 Foundation 行为而非契约偏差。

contract-checker 标 1 low severity（缺约束注释），不阻塞，可在后续 task 顺手补 doc comment。
