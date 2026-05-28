---
id: "006-install-and-tofu"
depends_on: ["004-plugin-runtime"]
complexity: M
milestone: M5
acceptance_scenarios: [SC-02, SC-04, SC-05, SC-06, SC-09, SC-11, SC-12]
contract_required: true
---

# 006 — 插件安装 CLI + TOFU 信任 + NSAlert 弹框

## 目标

扩展 BuddyCLI 加 5 个 `buddy launcher` 子命令（add / list / remove / config / inspect），实现 git clone 安装、TOFU 信任记录、首次执行 NSAlert 确认弹框。

## 架构上下文

- **不引入 swift-argument-parser**：BuddyCLI/main.swift 已 841 行 raw CommandLine + switch；在现有 switch 内追加 `case "launcher":` nested switch 分发 5 个子命令
- 文件：`Launcher/Plugin/TrustStore.swift` + main.swift 内的 nested switch handler 函数
- TOFU NSAlert 在 launcher 浮窗显示时弹出（modal），需测试不卡死

## 输入

- Task 002 handoff（LauncherConfig + SecretStore，本任务 config 子命令复用）
- Task 004 handoff（PluginManager + PluginManifest）
- Task 005 handoff（router 中 toolExecutor 闭包内 trustStore 检查位置）

## 输出契约

### CLI 子命令签名（invariant）

```bash
# 安装
buddy launcher add <user/repo>                # git clone https://github.com/user/repo
                                              # → ~/.buddy/launcher-plugins/user-repo/
                                              # 自动校验 plugin.json
                                              # 退出码: 0 成功 / 1 网络失败 / 2 manifest 无效 / 3 已存在

# 列表
buddy launcher list                            # 输出表格：name, version, description, trust
                                              # 格式（每行）：name (v0.1.0) [trusted|untrusted|never_run] - desc

# 卸载
buddy launcher remove <name>                   # 删 ~/.buddy/launcher-plugins/<dir>/
                                              # 同步从 launcher-trust.json 删除条目
                                              # 退出码: 0 成功 / 1 plugin 不存在

# 详情
buddy launcher inspect <name>                  # 输出 plugin.json 字段 + trust 状态 + 安装路径
                                              # 格式（JSON，便于解析）：
                                              # {
                                              #   "name": "...", "version": "...", "description": "...",
                                              #   "trust_status": "trusted|untrusted|never_run",
                                              #   "install_path": "/Users/.../.buddy/launcher-plugins/..."
                                              # }

# 配置（task 002 已实现，本任务确保接入 nested switch）
buddy launcher config set --provider <id> --kind <anthropic|openai-compatible> ...
buddy launcher config get [--provider <id>]
buddy launcher config use <provider>
```

### TrustStore（invariant）

```swift
struct TrustRecord: Codable {
    let trustKey: String      // SHA256 hex lowercase, 64 chars
    let pluginName: String
    let approvedAt: Date
}

final class TrustStore {
    init(file: URL = URL(fileURLWithPath: NSHomeDirectory()).appending(path: ".buddy/launcher-trust.json"))
    
    static func trustKey(for plugin: PluginManifest, executablePath: URL) throws -> String {
        // SHA256(plugin.cmd + plugin.args.joined("\n") + sha256(executable_bytes))
        // 用 CryptoKit.SHA256
    }
    
    func isTrusted(_ plugin: PluginManifest, executablePath: URL) -> Bool
    func approve(_ plugin: PluginManifest, executablePath: URL) throws
    func remove(pluginName: String) throws
    func list() throws -> [TrustRecord]
}

// NSAlert 弹框（在 task 005 router 的 toolExecutor 闭包内调用）
enum TrustPrompt {
    @MainActor
    static func askUser(plugin: PluginManifest, executablePath: URL) async -> Bool {
        // NSAlert with:
        //   messageText: "插件 \(plugin.name) 首次执行"
        //   informativeText: plugin.description + "\n命令: \(plugin.cmd) \(plugin.args.joined(separator: " "))"
        //   buttons: ["允许", "拒绝"]
        //   style: .warning
        // 用户点允许 → trustStore.approve + return true
        // 用户点拒绝 → return false
    }
}
```

### git clone 安装流程（伪代码）

```swift
func handleLauncherAdd(_ userRepo: String) throws {
    // userRepo 格式校验：必须 <user>/<repo>
    guard userRepo.split(separator: "/").count == 2 else { throw "Invalid user/repo format" }
    
    let dirName = userRepo.replacingOccurrences(of: "/", with: "-")  // user-repo
    let targetDir = URL(fileURLWithPath: NSHomeDirectory()).appending(path: ".buddy/launcher-plugins/\(dirName)")
    
    guard !FileManager.default.fileExists(atPath: targetDir.path) else {
        FileHandle.standardError.write(Data("Plugin already installed: \(dirName)\n".utf8))
        exit(3)
    }
    
    // 调 git CLI（macOS 自带）
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["clone", "--depth", "1", "https://github.com/\(userRepo).git", targetDir.path]
    process.environment = ProcessInfo.processInfo.environment
    try process.run()
    process.waitUntilExit()
    
    guard process.terminationStatus == 0 else { exit(1) }
    
    // 校验 plugin.json
    let manifestURL = targetDir.appending(path: "plugin.json")
    guard FileManager.default.fileExists(atPath: manifestURL.path) else {
        try FileManager.default.removeItem(at: targetDir)
        FileHandle.standardError.write(Data("Missing plugin.json in \(userRepo)\n".utf8))
        exit(2)
    }
    
    do {
        let _ = try JSONDecoder().decode(PluginManifest.self, from: Data(contentsOf: manifestURL))
    } catch {
        try FileManager.default.removeItem(at: targetDir)
        FileHandle.standardError.write(Data("Invalid plugin.json: \(error)\n".utf8))
        exit(2)
    }
    
    print("Installed \(userRepo) → \(targetDir.path)")
}
```

### 接口签名（example）

```
# add 正例
Given: 网络可达，user/repo 仓库存在含合法 plugin.json
When:  buddy launcher add stringzhao/buddy-translate
Then:  exit 0，stdout "Installed stringzhao/buddy-translate → ..."，目录 ~/.buddy/launcher-plugins/stringzhao-buddy-translate/ 存在

# add 已存在
Given: 目标目录已存在
When:  buddy launcher add stringzhao/buddy-translate
Then:  exit 3，stderr "Plugin already installed: ..."

# inspect 正例
Given: stringzhao-translate 已装且 trust=untrusted
When:  buddy launcher inspect stringzhao-translate
Then:  exit 0，stdout JSON {name:"translate",...,trust_status:"untrusted",install_path:"/Users/..."}

# TOFU 首次执行允许
Given: plugin 未信任，用户触发
When:  toolExecutor 闭包内 trustStore.isTrusted → false → TrustPrompt.askUser → 用户点允许
Then:  trustStore.approve 写入 ~/.buddy/launcher-trust.json，PluginExecutor.execute 继续

# TOFU 拒绝
Given: 同上但用户点拒绝
When:  TrustPrompt.askUser 返回 false
Then:  抛 LauncherError.pluginNotTrusted，UI 显示拒绝提示

# remove 同步清 trust
Given: plugin 已信任
When:  buddy launcher remove translate
Then:  目录消失，trust.json 中无该 plugin 条目
```

### 数据结构

- TrustStore 文件路径：`~/.buddy/launcher-trust.json`，权限 0644
- `TrustRecord.trustKey` 长度 == 64（SHA256 hex）
- 文件 schema：`{"records": [TrustRecord, ...]}`

### 边界值（DbC）

- git clone 超时：≤ 60s（网络慢可调整，但 CI 必须 ≤ 60s）
- TOFU NSAlert 等待用户响应：无超时（用户决定）
- trust.json 文件大小：≤ 100 KiB（保护用，正常 < 1 KiB）

### 错误契约

| 错误码 | 触发 |
|---|---|
| `pluginNotFound(String)` | inspect/remove 找不到 |
| `pluginNotTrusted(String)` | TOFU 未通过 |
| `pluginManifestInvalid(String)` | git clone 后 plugin.json 解析失败 |

### 副作用清单

- 写 `~/.buddy/launcher-trust.json`（approve / remove 时）
- 写 `~/.buddy/launcher-plugins/<dir>/`（add 时，git clone）
- 删 `~/.buddy/launcher-plugins/<dir>/`（remove 时）
- 调 `/usr/bin/git` 子进程
- 弹 NSAlert（modal，调用线程必须是 main thread）

## 验收标准

- ✅ SC-02（CLI 部分）：`buddy launcher config set` 写入 SecretStore + LauncherConfig
- ✅ SC-04：`buddy launcher add stringzhao/buddy-translate` 成功；`list` 显示；触发时弹 NSAlert
- ✅ SC-05：NSAlert 点"允许"后 plugin 执行；trust 记录写入；下次同插件不再弹框
- ✅ SC-06：NSAlert 点"拒绝"后 plugin 不执行；UI 显示拒绝提示
- ✅ SC-09：`remove` 清目录 + trust 条目
- ✅ SC-11：`inspect` 输出 JSON 含 name/version/description/trust_status/install_path
- ✅ SC-12（CLI 部分）：Ollama 配置子命令工作

## 测试要求

- `TrustStoreTests.swift`：approve / isTrusted / remove / trustKey 计算
- `LauncherCLITests.swift`（红队 acceptance）：调 `swift run buddy launcher ...` 子进程，断言 stdout/stderr/exit code
- `TrustPromptTests.swift`：用 swift-snapshot-testing 抓 NSAlert 视觉快照（可选，因 NSAlert 系统 UI）
- 集成测试：mock GitHub 仓库（用本地 file:// URL 或 git daemon）验证 git clone 流程

## 风险与缓解

- **NSAlert 在 LauncherWindow 显示时被卡**：测试 `NSAlert.runModal()` 与 LauncherWindow 共存；如卡死 fallback 用 SwiftUI Alert + `@State` 等待
- **git clone HTTPS 在 corporate proxy 环境失败**：让 git 自动用用户 ~/.gitconfig（不重写 env）
- **trust.json 并发写入**：CLI 和 app 都可能写，加 NSFileCoordinator 或 advisory lock；MVP 暂时不做并发写，记录已知限制到 handoff
- **buddy launcher add github.com:user/repo (SSH 格式)**：MVP 仅支持 HTTPS `<user>/<repo>` 简短格式；其他格式报"Invalid format"

## 接出

handoff 写：trustStore.shared 接入 task 005 toolExecutor 的具体改动行；TrustPrompt.askUser 调用位置；buddy CLI 5 个子命令各自的 exit code 表；已知并发写限制。
