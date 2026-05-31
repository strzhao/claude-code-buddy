---
id: "007-cli-install-disable-enable-reseed"
depends_on: ["004"]
---

# Task 007 — CLI: install/disable/enable/reseed + list --json

## 目标（一句话）

加 `buddy launcher install <name>` (marketplace 装) / `disable <name>` / `enable <name>` / `reseed`；`list` 显示 [禁用]；新增 `list --json` 输出 MarketplaceInspection JSON 供 autopilot QA 断言；旧 `buddy launcher add user/repo` 保留兼容；help 文案明确 install vs add 区别。

## 架构上下文

- 依赖 004（disable/enable）+ 003（install/reseed/inspect）
- 与 task 005/006 并行
- 现有 `cmdLauncherAdd` 行 1101 附近保留不动

## 输入

- 现有 `BuddyCLI/main.swift:886` 附近的 launcher 子命令分发
- `MarketplaceManager.{install, reseed, inspect}` (task 003)
- `PluginManager.{disable, enable, disabledNames}` (task 004)

## 输出契约

### 修改 `Sources/BuddyCLI/main.swift`

#### 1. 命令分发新增 install/disable/enable/reseed

```swift
case "install":
    cmdLauncherInstall(opts.positionalArgs.first ?? "")
case "disable":
    cmdLauncherDisable(opts.positionalArgs.first ?? "")
case "enable":
    cmdLauncherEnable(opts.positionalArgs.first ?? "")
case "reseed":
    cmdLauncherReseed()
```

#### 2. `list` 加 `--json` flag

```swift
case "list":
    if opts.flags.contains("--json") {
        cmdLauncherListJSON()
    } else {
        cmdLauncherList()  // 现有，加 [禁用] 后缀
    }
```

#### 3. 新增 4 个 cmd 函数

```swift
private func cmdLauncherInstall(_ name: String) {
    // 调 MarketplaceManager.shared.install(name:)
    // 成功 → print "Installed: \(name)"
    // 失败 → print 错误 + exit 1
}

private func cmdLauncherDisable(_ name: String) {
    // 调 PluginManager.shared.disable(name:)
}

private func cmdLauncherEnable(_ name: String) {
    // 调 PluginManager.shared.enable(name:)
}

private func cmdLauncherReseed() {
    // 调 MarketplaceManager.shared.reseed()
    // 成功 → print "Reseeded"
}

private func cmdLauncherListJSON() {
    // 调 MarketplaceManager.shared.inspect()
    // print(JSONEncoder().encode(inspection))
}
```

#### 4. 修改 `cmdLauncherList()` 加 [禁用] 后缀

```swift
let disabled = (try? PluginManager.shared.disabledNames()) ?? []
let disabledSet = Set(disabled)

for plugin in plugins {
    let suffix = disabledSet.contains(plugin.name) ? " [禁用]" : ""
    print("  - \(plugin.name)\(suffix): \(plugin.description)")
}
// 还要列出 disabled 但未在 list() 返回的（disabled 插件不在 list 中）
for name in disabled {
    if !plugins.contains(where: { $0.name == name }) {
        print("  - \(name) [禁用]: (信息不可用)")
    }
}
```

#### 5. help 文案

```
USAGE:
  buddy launcher <subcommand>

SUBCOMMANDS:
  config get/set/use              查看/设置/切换 LLM provider
  install <name>                  从官方 marketplace 安装插件
  add <user>/<repo>               从任意 GitHub repo 安装插件（非 marketplace）
  list [--json]                   列出已装插件（含禁用状态）；--json 输出结构化数据
  disable <name>                  禁用插件（保留文件，路由跳过）
  enable <name>                   重新启用插件
  remove <name>                   完全删除插件目录
  reseed                          强制从 bundle 重新 seed marketplace（自救命令）
  inspect <name>                  查看插件详情（JSON）
```

## 验收标准

### 自动化测试（红队）

1. **install 命令调通**：mock MarketplaceManager.install → cmdLauncherInstall("translate") → install 被调
2. **install 失败 exit 1**：mock install throw → exit code != 0
3. **disable 命令调通**：cmdLauncherDisable("translate") → PluginManager.disable("translate") 被调
4. **enable 命令调通**：cmdLauncherEnable("translate") → PluginManager.enable("translate") 被调
5. **reseed 命令调通**：cmdLauncherReseed → MarketplaceManager.reseed 被调
6. **list 含禁用后缀**：disable("translate") 后 cmdLauncherList → 输出含 "[禁用]"
7. **list --json 输出合法**：cmdLauncherListJSON → stdout 解析为 MarketplaceInspection JSON
8. **list --json 含 enabled 字段**：禁用 translate → list --json → translate.enabled == false

### 验证命令

```bash
cd apps/desktop && swift build && swift test --filter "BuddyCLI|LauncherInstall|LauncherDisable"
```

### Tier 1.5 真实场景

```bash
# 场景 1：install 第三方
# 准备 fake marketplace entry → buddy launcher install fake-plugin
buddy launcher install translate
buddy launcher list --json | jq '.plugins[] | select(.name=="translate")'

# 场景 2：disable/enable 循环
buddy launcher disable translate
buddy launcher list --json | jq '.plugins[] | select(.name=="translate") | .enabled'  # → false
test -f ~/.buddy/launcher-plugins/translate/.disabled
buddy launcher enable translate
buddy launcher list --json | jq '.plugins[] | select(.name=="translate") | .enabled'  # → true
test ! -f ~/.buddy/launcher-plugins/translate/.disabled

# 场景 3：reseed 自救
rm -rf ~/.buddy/launcher-plugins/translate
buddy launcher reseed
test -f ~/.buddy/launcher-plugins/translate/plugin.json

# 场景 4：help 不破坏
buddy launcher --help | grep -q "install"
buddy launcher --help | grep -q "add"
```

## 下游须知（handoff 要点）

- `cmdLauncherAdd`（旧）保留兼容，help 文案明确 add 不走 marketplace
- `list --json` 输出格式即 `MarketplaceInspection` 的 JSON，autopilot QA 直接断言
- `inspect` 子命令（task 003 已加 manifest 字段，本 task 不重做）已存在，本 task 不动
