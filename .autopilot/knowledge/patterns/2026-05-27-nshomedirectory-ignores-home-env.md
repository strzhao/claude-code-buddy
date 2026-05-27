# NSHomeDirectory() 在 macOS 上忽略 HOME 环境变量，CLI 测试需显式读 $HOME

<!-- tags: nshomedirectory, macos, foundation, home-env, getpwuid, cli-testing, test-isolation, process-environment, buddy-cli, subprocess-tests -->

## 上下文

CLI 测试需要将 `~/.buddy/` 隔离到临时目录，常规方案是给子进程注入 `HOME=/tmp/test-xxx`。这在 Linux 上通常奏效，但在 macOS 上 `NSHomeDirectory()` 会忽略 `HOME` 环境变量，导致测试污染开发者真实 home 目录。

## 现象

```swift
// BuddyCLI 中（旧）
private let launcherConfigDir = "\(NSHomeDirectory())/.buddy"
```

测试代码：
```swift
var env = ProcessInfo.processInfo.environment
env["HOME"] = tempDir.path
process.environment = env
try process.run()
```

测试期望：子进程读 `tempDir/.buddy/launcher-plugins/`
实际现象：子进程仍然读 `/Users/stringzhao/.buddy/launcher-plugins/`，污染真实 home

`NSHomeDirectory()` 在 macOS 上调用 CFCopyHomeDirectoryURL，最终走 `getpwuid_r` 拿登录用户的 home，**不读 $HOME env**（apple 文档没明说，但实证如此）。

## 根因

macOS Foundation 设计为获取"安全的" home 目录（防止恶意 env var 让 app 读非用户 home 的路径）。在 sandboxed app 中这是好事，但在 CLI / 测试场景下让 isolation 失效。

## 解决

CLI 端显式读 $HOME，fallback NSHomeDirectory：

```swift
private let buddyHomeDir: String = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
private let launcherConfigDir = "\(buddyHomeDir)/.buddy"
```

生产环境 $HOME 与 NSHomeDirectory 等价（macOS 登录会话总是设 $HOME），fallback 保证 $HOME 未设时仍可用。测试时只需 `env["HOME"] = tempDir.path` 即可隔离。

## 验证

`LauncherCLILauncherAcceptanceTests` 通过 subprocess + HOME 隔离运行 9 个 buddy launcher 子命令，测试前后开发者真实 `~/.buddy/launcher-plugins/` 完全不动。

## 适用范围

- 任何 macOS CLI 工具需要支持测试隔离时
- 需要支持用户自定义 HOME 路径（如沙盒 / docker 容器场景）

## 反例

不要用 `FileManager.default.homeDirectoryForCurrentUser` — 行为与 NSHomeDirectory 一致，同样忽略 $HOME。

## 关联

- [[buddy-cli-nested-switch]] BuddyCLI 不依赖 BuddyCore 的内联实现策略
