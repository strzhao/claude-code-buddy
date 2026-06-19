# launcher debug CLI：Registry 直驱的无侵入功能测试入口

<!-- tags: launcher, cli, debug, functional-testing, registry-direct, queryhandler, buddy-cli, socket, ipc, builtin-plugin, calculator, candidates, perform, json, deterministic, non-destructive, qa, automation -->

**Scenario**: launcher 是热键（Ctrl+Space）召唤的 NSPanel 浮窗。功能测试有两个缺口：① osascript 键盘自动化抢占用户屏幕（见 [[2026-06-19-launcher-e2e-keyboard-automation-destructive-use-cli]]，被 reject）；② 单元测试只测 plugin 纯函数，不覆盖"真实 app 进程内 QueryHandler→Registry→候选→perform"全链路。猫咪子系统有 `buddy` CLI（session/emit/inspect）可无侵入驱动，launcher 缺等价入口。

**Lesson**: 给 launcher 补 CLI 调试入口，**镜像既有 hotkey IPC exemplar** 扩展，三命令覆盖候选生成全链路：

```
buddy launcher debug candidates <query>          # 返回候选 JSON
buddy launcher debug perform <query> [--index N] # 执行候选 perform，读 pasteboard 返回 copied
buddy launcher debug registry                    # 列出已注册插件（priority 降序）
```

实现链路（全部复用既有基础设施，零新 IPC）：
- **CLI**（`BuddyCLI/main.swift`）：`sendQuery(["action":"launcher_debug_*", ...])` —— 既有请求-响应 socket helper（line ~149），镜像 `cmdLauncherHotkeyShow`。
- **IPC**：`SocketServer.handleLineWithFD` 识别 `"action"` 字段 → `SessionManager.onQuery` 在 `Task{@MainActor}` 内 `await queryHandler.handle(query:)`（见 [[2026-04-16-socket-bidirectional-action-field]] 的双向 query/response 决策）。
- **QueryHandler**：`handle(query:)` 改 async（registry.actions 是 async），switch 加三分支，**直接调 `BuiltinPluginRegistry.shared`**（不经 LauncherManager）。

**关键决策——Registry 直驱而非 LauncherManager**：候选生成是 `BuiltinPluginRegistry.actions(for:)` 纯管线。LauncherManager 在其上加了 debounce(120ms)/UI 状态/路由的异步不确定性——对功能调试是噪声。直接调 Registry 确定性高（同输入两次调用 JSON 完全一致，这是本工具区别于 osascript 的本质属性）、红队易写硬断言、不触发 UI 副作用。LauncherManager 的 UI 集成由 SwiftUI 快照测试覆盖，不归 CLI 调试管。

**How to apply**:
- 未来给 launcher 加新内置插件 / 改候选生成：autopilot QA Tier 1.5 直接用 `buddy launcher debug candidates '<query>'` 批量验证（det-machine：stdout JSON 字段 + exit code），**禁止**再碰 osascript 键盘模拟。
- `perform` 命令执行真实副作用（计算器复制 / app 启动 / 锁屏）——文档化；测试用注入的具名 `NSPasteboard` 隔离（镜像 [[2026-05-29-nspasteboard-test-isolation-via-named-pasteboard]]）。
- 加新 debug action：① main.swift 加 cmd 函数（sendQuery）② QueryHandler switch 加分支（@MainActor async handler）③ action 名 `launcher_debug_<op>`。三处，零新基础设施。

**Evidence**: 2026-06-19 合入（commit `6c16cb9`）。红队 `LauncherDebugQueryHandlerAcceptanceTests` 13/13；真机 CLI 冒烟三命令全绿 + 计算器 17 表达式全对（含上轮键盘自动化测不稳的 `2^10`/`2^3^2`）。`perform '1+3'` → `copied:"4"` + pbpaste 实测 [4]。

**关联**：
- [[2026-06-19-launcher-e2e-keyboard-automation-destructive-use-cli]]（问题）—— 本条是其解法闭环。
- [[2026-04-16-socket-bidirectional-action-field]]（IPC 基础）—— debug CLI 走同一 socket query/response 协议。
- [[2026-05-30-launcher-builtin-plugin-direct-action-pipeline]]（BuiltinPlugin 架构）—— Registry 直驱的对象。
