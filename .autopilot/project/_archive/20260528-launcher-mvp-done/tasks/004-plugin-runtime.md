---
id: "004-plugin-runtime"
depends_on: ["001-launcher-skeleton"]
complexity: M
milestone: M3
acceptance_scenarios: [SC-04, SC-05]
contract_required: true
---

# 004 — Plugin Runtime（manifest + executor + PATH 注入 + hello-world demo）

## 目标

实现插件协议运行时：plugin.json schema、PluginManager 扫描 `~/.buddy/launcher-plugins/`、Process 子进程执行（stdin=JSON / stdout=markdown / timeout / PATH 注入）。本任务**不**做 git clone 安装（留 006）和 AI 路由（留 005），但放一个内置 hello-world demo plugin 验证完整链路。

## 架构上下文

- 文件：`Launcher/Plugin/`
- 子进程在 LSUIElement app 中默认 PATH 仅 `/usr/bin:/bin`，**必须**注入扩展 PATH（`/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin`）
- PluginManifest 含 `requiredPath: [String]?` 字段预检查关键 binary

## 输入

- Task 001 handoff（LauncherManager.shared）
- PRD 决策 3/4/9（CLI 插件原子 / manifest+README / stdout=markdown）

## 输出契约

### 接口签名（invariant）

```swift
struct PluginManifest: Codable {
    let name: String              // 必须匹配目录名最后一段 <repo>
    let version: String
    let description: String
    let keywords: [String]
    let cmd: String               // 相对路径，禁止绝对路径
    let args: [String]
    let env: [String: String]?
    let timeout: Int?             // 秒，缺省 30，上限 120
    let requiredPath: [String]?   // 预检查外部 binary
}

struct PluginInput: Codable {
    let query: String
    let sessionId: String         // UUID，每次唤起一个
    let cwd: String               // 用户当前工作目录（buddy app 启动时的 HOME）
}

struct PluginResult {
    let stdout: String            // ≤ 1 MiB，截断警告
    let stderr: String            // 仅日志，不进 prompt
    let exitCode: Int32
    let durationMs: Int
}

final class PluginManager {
    init(rootDir: URL = URL(fileURLWithPath: NSHomeDirectory()).appending(path: ".buddy/launcher-plugins"))
    
    func list() throws -> [PluginManifest]   // 扫描 rootDir 子目录中的 plugin.json
    func find(name: String) throws -> PluginManifest?
}

final class PluginExecutor {
    func execute(_ plugin: PluginManifest, pluginDir: URL, input: PluginInput) async throws -> PluginResult
    // 步骤：
    // 1. 预检查 requiredPath（每个 binary 在扩展 PATH 中查找，缺失抛 pluginMissingDependency）
    // 2. 构造 Process：
    //    - executableURL = pluginDir.appending(plugin.cmd)
    //    - arguments = plugin.args
    //    - currentDirectoryURL = pluginDir
    //    - environment = [扩展 PATH] + ProcessInfo.processInfo.environment + plugin.env
    //    - standardInput = Pipe（写 JSON.encode(input) + close）
    //    - standardOutput / standardError = Pipe（异步 readData）
    // 3. 启动 + 等待，超时 SIGTERM → +5s SIGKILL
    // 4. 收集 stdout/stderr/exit code，组装 PluginResult
}

// 内置 demo plugin
// apps/desktop/Sources/ClaudeCodeBuddy/Resources/HelloPlugin/
//   ├── plugin.json
//   ├── README.md
//   └── hello.sh  (打印 "## Hello, {query}!")
// 首次启动时 PluginManager.installBundledPlugins() 将其拷贝到 ~/.buddy/launcher-plugins/builtin-hello/
```

### 接口签名（example）

```
# Manager.list 正例
Given: ~/.buddy/launcher-plugins/user-repo/plugin.json 存在
When:  list()
Then:  返回 [PluginManifest(name:"repo", ...)]

# Manager.list 跳过无 plugin.json 的目录
Given: ~/.buddy/launcher-plugins/broken-dir/ 无 plugin.json
When:  list()
Then:  日志警告，跳过该目录，不抛错

# Executor.execute 正例
Given: manifest={cmd:"./hello.sh", args:[], timeout:5},
       input={query:"world", sessionId:"abc", cwd:"/Users/foo"}
When:  execute(...)
Then:  PluginResult(stdout:"## Hello, world!\n", stderr:"", exitCode:0, durationMs:<100)

# Executor.execute 超时反例
Given: manifest={cmd:"./sleep-forever.sh", timeout:1}
When:  execute(...)
Then:  抛 LauncherError.pluginTimeout(1)，进程已 SIGKILL

# Executor.execute 依赖缺失
Given: manifest={requiredPath:["nonexistent-binary"]}
When:  execute(...)
Then:  抛 LauncherError.pluginMissingDependency("nonexistent-binary")，进程未启动

# Executor.execute exit code 非 0
Given: cmd 返回 exit 1，stderr="invalid input"
When:  execute(...)
Then:  抛 LauncherError.pluginCrash(1, "invalid input")
```

### 数据结构

- plugin.json 字段全必填除 `env / timeout / requiredPath`
- `PluginManifest.cmd` 校验：不含 `/..`、不以 `/` 开头（必须相对路径）
- `PluginManifest.name` 校验：与父目录名最后一段匹配（防止恶意 manifest）
- `PluginResult.stdout` 截断到 1 MiB 时末尾追加 `\n[...output truncated]`

### 边界值（DbC）

- timeout：≤ 30s 缺省、≤ 120s 上限（manifest 可改）
- stdout 大小：≤ 1 MiB
- stderr 大小：≤ 100 KiB（截断不警告）
- requiredPath 数组长度：≤ 10
- 扩展 PATH 拼接顺序：`/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:` + `ProcessInfo.processInfo.environment["PATH"]`

### 边界值（example）

- 正例：插件 5s 内 exit 0，stdout 1 KiB → ✅ PluginResult
- 边界：插件正好 30s 时 exit 0 → 接受（≤30s 含 30s）
- 反例：插件 31s 仍未退出 → SIGTERM + 5s 后 SIGKILL，抛 pluginTimeout
- 边界：stdout 恰好 1 MiB → 接受全部
- 反例：stdout 1.5 MiB → 截断到 1 MiB + 末尾追加 truncated

### 错误契约

| 错误码 | 触发 |
|---|---|
| `pluginNotFound(String)` | Manager.find 找不到名字 |
| `pluginMissingDependency(String)` | requiredPath 中 binary 在扩展 PATH 不存在 |
| `pluginTimeout(Int)` | SIGTERM 后超时 |
| `pluginCrash(Int32, String)` | exit code 非 0 |
| `pluginManifestInvalid(String)` | plugin.json 解析失败或字段校验失败 |

### 副作用清单

- 扫描 `~/.buddy/launcher-plugins/<dir>/plugin.json`
- 启动 `Process`，cwd = pluginDir
- env 构造顺序（后覆盖前）：`[扩展 PATH]` → 当前进程 env → manifest.env
- 写 Pipe stdin（JSON）、读 Pipe stdout/stderr
- 首次启动时拷贝 bundled HelloPlugin 到 `~/.buddy/launcher-plugins/builtin-hello/`

## 验收标准

- ✅ SC-04 部分（手动安装）：手动 `cp -r demo-plugin ~/.buddy/launcher-plugins/test-demo/` 后 `PluginManager.list()` 能枚举到
- ✅ SC-05 部分（执行）：内置 hello plugin 能 execute 并返回 "## Hello, ..." markdown
- 完整 SC-04/05 在 task 006 完成 TOFU 后联调

## 测试要求

- `PluginManifestTests.swift`：Codable 解析 / 字段校验（name 匹配目录、cmd 不含 `/..`）
- `PluginManagerTests.swift`：mock fs 验证扫描行为
- `PluginExecutorTests.swift`：
  - 正例（echo "hi"）
  - 超时（sleep 5 + timeout=1）
  - exit code 非 0
  - 依赖缺失（requiredPath=["nonexistent"]）
  - stdout > 1 MiB 截断
- `PluginExecutor.acceptance.test.swift`（红队）：跑 bundled hello plugin

## 风险与缓解

- **子进程 stdin/stdout buffering**：用 `Pipe` + `readDataToEndOfFile`（同步）或 `bytes` AsyncSequence；测试用 1 MiB 输出 fixture
- **manifest.cmd 路径遍历攻击**：解析时禁止 `/..`、`./..`、绝对路径；fixture 测试这些反例必须抛 manifestInvalid
- **SIGTERM 后子进程没退出**：测试 fixture 用 `trap '' TERM` shell 脚本，确认 +5s 后 SIGKILL 生效
- **bundled HelloPlugin 拷贝到 ~/.buddy/ 的幂等性**：用 file existence 检查跳过已存在；版本号变化时重新拷贝

## 接出

handoff 写：PluginManager.shared 单例 + PluginExecutor.execute 签名 + bundled hello plugin 路径；下游 task 005 怎么把 PluginManager.list() 喂给 LauncherRouter；下游 task 006 怎么写 trust check 包裹 execute。
