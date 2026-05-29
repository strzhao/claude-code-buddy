---
id: "002-plugin-source-resolver"
depends_on: ["001"]
---

# Task 002 — PluginSourceResolver 多态加载

## 目标（一句话）

实现 PluginSourceResolver，把 4 种 PluginSourceConfig 类型解析为本地插件目录 URL（含 plugin.json），git 类型复用现有 cmdLauncherAdd 的 git clone 实现 + sha 校验。

## 架构上下文

- 依赖 001 的 PluginSourceConfig enum
- 复用 `BuddyCLI/main.swift:1117-1140` 附近的 git clone 实现（/usr/bin/git Process + --depth 1 + 60s timeout）
- 输出"插件目录 URL"由调用方负责拷贝到 `~/.buddy/launcher-plugins/<name>/`（不本任务的事）

## 输入

- `PluginSourceConfig` enum（task 001）
- 现有 git clone 实现（cmdLauncherAdd 内）

## 输出契约

### 新建 `Sources/ClaudeCodeBuddy/Launcher/Marketplace/PluginSourceResolver.swift`

```swift
final class PluginSourceResolver {
    static let shared = PluginSourceResolver()
    
    /// 解析 source 到本地"插件目录 URL"（必含 plugin.json）
    /// - localSubdir(path): 返回 bundleRoot.appending(path)
    /// - gitSubdir/gitURL: clone 到临时目录，验证 sha（如有），返回 subdir URL
    /// - file(path): 直接返回 URL(fileURLWithPath: path)
    /// - 抛: LauncherError.networkFailure / LauncherError.pluginInvalid("sha mismatch")
    func resolve(_ source: PluginSourceConfig, bundleRoot: URL?) async throws -> URL
}
```

### 内部实现关键点

1. **gitClone helper**: 抽出复用，签名 `gitClone(url: String, ref: String?, depth: Int = 1, timeoutSeconds: Int = 60) async throws -> URL`（临时目录路径）
2. **sha 验证**: clone 后 `git rev-parse HEAD` 比对 expected sha；失配抛 `LauncherError.pluginInvalid("sha mismatch: expected X got Y")`
3. **临时目录清理**: 调用方负责（resolver 仅返回路径；调用方拷贝到 ~/.buddy/ 后清理 temp）

## 验收标准

### 自动化测试（红队）

1. **localSubdir 解析**：传 bundleRoot + "./plugins/translate" → 返回正确 URL，含 plugin.json
2. **localSubdir + bundleRoot=nil**：throw `LauncherError.pluginInvalid("local subdir requires bundleRoot")`
3. **file 解析**：传 `/tmp/test-plugin` 含 plugin.json → 返回该 URL
4. **gitURL 解析 mock**：用 LocalHTTPServer mock 一个 git repo（或测试用 fixture git bundle）→ clone → sha 验证通过 → 返回临时目录
5. **gitURL sha 不匹配**：mock repo 实际 sha 与 expected 不等 → throw pluginInvalid
6. **gitSubdir 解析**：clone 后访问 `path` 子目录返回 URL
7. **gitURL 超时**：mock 一个不响应的 url，60s 后 throw `LauncherError.networkFailure`

### 验证命令

```bash
cd apps/desktop && swift build && swift test --filter PluginSourceResolver
```

### Tier 1.5 真实场景

不需要 — 单元测试已充分覆盖。

## 下游须知（handoff 要点）

- `gitClone` helper 抽出后可被 task 003 MarketplaceManager 复用
- resolver 返回的是 **临时目录 URL（git）或永久 URL（local/file）**，调用方需要识别并清理 temp
- 不要写入 `~/.buddy/launcher-plugins/`（那是 task 003 的事）
