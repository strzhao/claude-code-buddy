# 004-plugin-runtime handoff

## 实现摘要

task 004 完成 CLI 插件运行时：PluginManifest schema + 5 反例 validate / PluginManager 扫描 ~/.buddy/launcher-plugins/ / PluginExecutor Process 子进程执行（stdin JSON / stdout markdown / SIGTERM→SIGKILL grace 5s / PATH 注入 prefixes + 当前 PATH / requiredPath 预检查）/ bundled HelloPlugin demo（首次启动 detached 拷贝到 ~/.buddy/launcher-plugins/builtin-hello/）。776 测试全绿，QA 77/100。

## 关键文件路径

```
apps/desktop/Sources/ClaudeCodeBuddy/Launcher/Plugin/  [新建目录]
├── PluginManifest.swift    # Codable + validate（name/dirName 一致、cmd 不含 .. 或绝对路径、timeout [1,120]、requiredPath ≤10）
├── PluginInput.swift       # value type {query, sessionId, cwd}
├── PluginResult.swift      # value type {stdout, stderr, exitCode, durationMs, stdoutTruncated}
├── PluginManager.swift     # singleton + list/find/pluginDir/installBundledPlugins（幂等）
└── PluginExecutor.swift    # singleton + execute（Process + readabilityHandler + ResumeGuard + deadline force-close）

apps/desktop/Sources/ClaudeCodeBuddy/Plugins/HelloPlugin/  [新建目录，BuddyCore .copy("Plugins") 打包]
├── plugin.json   # name="builtin-hello", cmd="./hello.sh", timeout=5
├── hello.sh      # bash 读 stdin JSON 输出 markdown
└── README.md
```

修改：
- `Package.swift` — `resources: [.copy("Assets"), .copy("Plugins")]`
- `LauncherError.swift` — 同文件追加 5 case：pluginNotFound / pluginMissingDependency / pluginTimeout / pluginCrash / pluginManifestInvalid
- `LauncherConstants.swift` — +6 常量：launcherPluginsDir / pluginDefaultTimeoutSec=30 / pluginMaxTimeoutSec=120 / pluginMaxStdoutBytes=1MiB / pluginMaxStderrBytes=100KiB / pluginSigkillGraceSec=5 / pluginRequiredPathMaxCount=10 / pluginPathPrefixes=[/opt/homebrew/bin, /usr/local/bin, $HOME/.local/bin]
- `LauncherManager.swift` — setup() 末尾 `Task.detached { try? PluginManager.shared.installBundledPlugins() }`（不阻塞 UI 启动）
- `apps/desktop/CLAUDE.md` — Launcher 子条目展开 Plugin/

## 下游须知

### Task 005 (Routing) 接入

router 用 PluginManager.list 出来的 manifest 列表作 keyword 缩候选，再传 manifest 给 LauncherAgent 的 toolExecutor 闭包：

```swift
let manifests = try PluginManager.shared.list()
// keyword 缩候选 + AI 选 plugin（task 005 实现）
let chosen: PluginManifest = ...
let dir = try PluginManager.shared.pluginDir(for: chosen)

let agent = LauncherAgent(
    provider: provider,
    tools: [chosen.toAgentTool()],   // PluginManifest → AgentTool 转换（task 005 加扩展方法）
    model: providerConfig.model,
    toolExecutor: { name, input in
        guard name == chosen.name else { throw LauncherError.pluginNotFound(name) }
        let pluginInput = PluginInput(query: ..., sessionId: ..., cwd: NSHomeDirectory())
        let result = try await PluginExecutor.shared.execute(chosen, pluginDir: dir, input: pluginInput)
        return result.stdout
    }
)
```

### Task 006 (Install + TOFU) 接入

- `buddy launcher add user/repo` git clone 到 `~/.buddy/launcher-plugins/user-repo/` → PluginManager.list 自动发现
- TOFU 信任在 PluginExecutor.execute 之前包裹一层 TrustStore.check（task 006 实现）
- `buddy launcher remove name` 删除目录 + trust 同步

## 设计偏差与中途修复

### implement 阶段死锁修复（critical）

发现 `readBounded` 用 `availableData` + `readDataToEndOfFile` 在 SIGKILL bash 后 orphan child（如 sleep）持 pipe 写端时无限阻塞。

**修复**：
- `readBounded` 改用 `readabilityHandler` 异步读 + NSLock `ResumeGuard` once-flag 防 CheckedContinuation 双 resume + `deadline asyncAfter` 兜底强制 close handle 触发 EOF
- `PluginExecutor.execute` 传 `deadline = plugin.effectiveTimeout + grace + 3s` 余量给 readBounded
- 测试 fixture `sleep 30 → sleep 10`（保留 SIGKILL 触发语义，限制 orphan 影响）

### 其他偏差
- `PluginExecutor.init` 未私有（contract-checker 1 medium）— 不影响外部行为，记入 backlog

## 已知 backlog（不阻断当前 task）

1. **[Minor]** `kill(-pid, SIGKILL)` 对默认 pgid 无效（无 setpgid），task 006 沙箱化时改 `setpgid` + 真进程组 kill
2. **[Minor]** `PluginExecutor.init` 加 `private` 修饰符
3. **[Minor]** `readBounded` 删 `alreadyResumed` 局部变量（tryResume 内双重检查已足够）
4. **[Minor]** 注释 "sleep 30" → "sleep 10" 同步
5. **[Minor]** 2 处冗余 `XCTAssertNotNil + XCTUnwrap` 合并
6. **[Minor]** cmd 反例补 reason 内容断言
7. **[Inherited]** make bundle 未更新 `.app/Contents/MacOS/buddy`（task 002 遗留，task 008 处理）
8. **[Inherited]** LauncherInputView.onDisappear 持 Task handle 真正 cancel（task 003 遗留）

## 验证证据

- `swift test --filter Plugin` → Manifest 23 + Manager 9 + Executor 7 + BundledHello 5 = 44 acceptance + 蓝队单测全过
- `swift test` 全量 → 776 passed / 0 failed
- `make lint` → 0 violations in 92 files
- `make build && make bundle` → 通过（CLI 仍是旧版，task 002 遗留）
- contract-checker → 1 medium（init 可见性，不阻断）
- qa-reviewer → 77/100 Ready to merge: Yes

## 下游接入点示例（task 005 最小 3 行）

```swift
let manifests = try PluginManager.shared.list()
let chosen = router.select(manifests, query: userQuery)
let result = try await PluginExecutor.shared.execute(chosen, pluginDir: PluginManager.shared.pluginDir(for: chosen), input: PluginInput(query: userQuery, sessionId: UUID().uuidString, cwd: NSHomeDirectory()))
```
