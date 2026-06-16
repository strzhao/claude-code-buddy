---
active: true
phase: "merge"
gate: ""
iteration: 2
max_iterations: 30
max_retries: 3
retry_count: 0
mode: ""
plan_mode: ""
fast_mode: false
brief_file: ""
next_task: ""
auto_approve: false
knowledge_extracted: ""
task_dir: "/Users/stringzhao/workspace_sync/personal_projects/claude-code-buddy/.autopilot/requirements/20260615-我们参考-alfred-的热键"
session_id: 476c39ef-72c2-4373-aaa5-cee3840be962
started_at: "2026-06-15T10:32:01Z"
contract_required: true
html_review: false
---

## 目标
我们参考 alfred 的热键支持设计（要大，要方便），给当前的 buddy launcher 支持下热键配置能力，然后把默认键改成 ctrl + space

> 📚 项目知识库已存在: .autopilot/。design 阶段请先加载相关知识上下文。

## 设计文档

### Context

**目标**：参考 Alfred 热键配置设计（大而方便），给 buddy launcher 增加热键配置能力（UI 设置面板 tab + CLI 命令），默认键改 ctrl+space，并从根上修复升级后热键失效的兼容性 bug。

**现状（已验证）**：
- 热键注册：`LauncherHotkey.swift` 用 KeyboardShortcuts 库 2.4.0，`Name("launcher-toggle", default: ⌘⇧Space)`，Carbon `RegisterEventHotKey`，存 UserDefaults `KeyboardShortcuts_launcher-toggle`。
- 配置能力为零：`LauncherConfig.hotkey`（`HotkeyConfig{key,modifiers}`）死代码；无 Recorder UI 实例；CLI `buddy launcher config` 只管 provider。
- 设置面板体系成熟：`SettingsWindowController` + Tab 枚举（skins/plugins）+ `switchTo(tab:)` + segmentedControl；menubar 齿轮 `onSettings`。加 tab = 扩枚举 + 加 VC + switchTo case + segment。
- SwiftUI↔AppKit 桥接有先例（NSHostingController）；库提供 AppKit 原生 `RecorderCocoa`（`init(for: Name)`，NSView 子类，addSubview，自动存 UserDefaults + 冲突检测）。
- socket 双向 query：有 query 分发入口（`QueryHandler.handle`）+ 标准响应格式 `{status,data}`/`{status,message}`；CLI 现有 inspect/click/food 等通过 `sendQuery` 走 socket。
- 实测：Carbon 全局热键在本机 macOS 26.4 正常（⌘⇧Space/⌘⇧P 均触发）。

**已确认方案**：方案 A —— 库 UserDefaults 单一真相源 + socket 双向命令（详见 brainstorm.md）。

### 架构设计

**核心决策**：热键存储保持 KeyboardShortcuts 库的 UserDefaults（单一真相源，库管理），**不引入 launcher.json 双轨**。UI Recorder 和 CLI 都通过库/socket 操作，避免 CLI 直写库内部格式（升级 bug 根源）。

**数据流**：
- UI 改键：`RecorderCocoa`（库）→ 直接调库 `setShortcut` → UserDefaults + 即时重注册
- CLI 改键：CLI `sendQuery(hotkey_*)` → socket → app `QueryHandler` → 调库 `setShortcut/getShortcut/disable` → 即时重注册 + 返回结果
- 启动迁移：`LauncherManager.setup` → 检测迁移标志 → 清理不兼容旧 UserDefaults 值 → 用新 default 重注册

### 各组件设计

**1. 默认键改 ctrl+space**
- `LauncherHotkey.swift`：`default: .init(.space, modifiers: [.control])`
- Ctrl+Space 系统 symbolichotkeys 无占用（已验证：⌘+Space 是输入法 key60，⌥⌃Space 是输入法 key61，纯 ⌃+Space 空闲）。

**2. UI「热键」tab（Alfred 风格大 Recorder）**
- 新建 `KeyboardShortcutsViewController`（AppKit，遵循 `SettingsTabClickReceiver` 协议）
- 布局：标题「启动器热键」+ 大尺寸 `RecorderCocoa(for: LauncherHotkey.toggle)`（宽占位）+ 当前 combo 大字回显（观察 `getShortcut`）+「重置默认」按钮（调 `KeyboardShortcuts.reset(LauncherHotkey.toggle)` 回 default —— 库 `setShortcut(nil)` 是清除非回 default，必须用 `reset`）+ 冲突红字提示（库 Recorder 自带冲突检测）
- `SettingsWindowController`：Tab 枚举加 `.hotkey`，segmentedControl 加第 3 段「热键」，`switchTo` 加 case 创建 VC
- menubar → 设置链路不变（齿轮 onSettings 已通）

**3. CLI `buddy launcher hotkey set/show/clear`**
- 参数：`--key <key> --modifiers <comma-list>`（结构化，对齐 HotkeyConfig 语义）。例 `--key space --modifiers control`。`set` 需 key；`show`/`clear` 无参。
- `main.swift`：parseArguments 加 `--key`/`--modifiers` flag；launcher 分发加 `hotkey` case → set/show/clear；printHelp 加文案
- 每命令通过 `sendQuery` 发 socket，打印返回 combo/状态
- 校验：key 非空、modifiers ∈ {command,shift,control,option}；非法 exit 非 0 + stderr；app 未运行 sendQuery 超时 exit 非 0

**4. socket hotkey 命令扩展**
- 消息：`{action:"hotkey_set", key:"space", modifiers:["control"]}` / `{action:"hotkey_show"}` / `{action:"hotkey_clear"}`
- app 侧 `QueryHandler` 加 3 case：
  - `hotkey_show` → `getShortcut(for:.toggle)` → `{status:"ok", data:{combo:"⌃Space", isDefault:bool}}`
  - `hotkey_set` → 参数校验（key 非空、modifiers ∈ {command,shift,control,option}）→ `setShortcut(.init(key,modifiers), for:.toggle)` → 即时重注册 → `{status:"ok", data:{combo, isDefault:false}}`；参数非法 → `{status:"error", message:"invalid key/modifiers"}`。注：库 `setShortcut` 不做系统级冲突检测（仅 Recorder UI 路径有 alert），CLI 不预检系统冲突
  - `hotkey_clear` → `KeyboardShortcuts.reset(.toggle)`（回 default，**非** `setShortcut(nil)` 后者是清除）→ `{status:"ok", data:{combo:default, isDefault:true}}`
- 精确 QueryHandler 注入点蓝队实现时定位（对齐现有 inspect/click 分发模式）

**5. 升级迁移（修复兼容性 bug）**
- 加迁移标志 UserDefaults key `launcher.hotkeyMigrationV1`
- `LauncherManager.setup`：标志未置时清理 `KeyboardShortcuts_launcher-toggle`（删旧值，库用新 default ctrl+space 重注册）+ 置标志
- 一次性、幂等（标志已置则跳过）——从根上解决"升级后旧值与新库不兼容"

**6. LauncherConfig.hotkey 死字段处置**
- 与方案 A 库存储无关。决策：`HotkeyConfig` 类型保留（供 socket 消息/CLI 参数结构复用 key/modifiers 语义），但 `LauncherConfig.hotkey` 字段蓝队 grep 确认无注册路径引用后移除（避免双源混淆）。

### 契约规约（contract_required）

**契约 1 — `LauncherHotkey.toggle` Name 不变**：`rawValue == "launcher-toggle"`（锁定，向后兼容，SC-17 守护）；仅 `default` 改：`⌘⇧Space` → `Ctrl+Space`（`.space` + `[.control]`）。

**契约 2 — socket hotkey 命令 schema**：请求 `action ∈ {hotkey_set, hotkey_show, hotkey_clear}`；`hotkey_set` 参数 `key:String` + `modifiers:[String]`（∈ {command,shift,control,option}，非法→error）；响应成功 `{status:"ok", data:{combo:String, isDefault:Bool}}`，失败 `{status:"error", message:String}`（**仅** 参数非法/app 未运行，**不含系统级热键冲突** —— 库 `setShortcut` 不检测冲突，冲突由 UI Recorder 自带 alert 处理）；`combo` 格式与 UI Recorder 显示一致（如「⌃Space」）。

**契约 3 — 默认 combo**：默认 = Ctrl+Space，硬编码 `LauncherHotkey.default`，SC-17 类测试守护。

**契约 4 — CLI 命令接口**：`set --key <k> --modifiers <csv>` → exit 0 + 打印新 combo，非法/冲突/app 未运行 → exit 非 0 + stderr；`show` → exit 0 + stdout 当前 combo（+ isDefault）；`clear` → exit 0 + 打印回退的 default combo。

## 实现计划

### 蓝队任务（实现）
- [x] T1 默认键：`LauncherHotkey.swift` default 改 `.init(.space, modifiers:[.control])`
- [x] T2 UI：新建 `KeyboardShortcutsViewController.swift`（AppKit + RecorderCocoa +「重置默认」按钮调 `KeyboardShortcuts.reset` + combo 回显 + 冲突提示）
- [x] T3 UI：`SettingsWindowController` 加 `.hotkey` tab（Tab 枚举 + switchTo case + segmentedControl 第 3 段「热键」）
- [x] T4 socket：`QueryHandler` 加 hotkey_set/show/clear（set→`setShortcut`+参数校验、show→`getShortcut`、clear→`KeyboardShortcuts.reset` 回 default；set 不预检系统冲突；即时重注册）
- [x] T5 CLI：`main.swift` 加 `hotkey` 子命令（--key/--modifiers flag + set/show/clear 分发 + sendQuery + 参数校验 + help 文案）
- [x] T6 迁移：`launcher.hotkeyMigrationV1` 标志 + `LauncherManager.setup` 清理旧 UserDefaults `KeyboardShortcuts_launcher-toggle` 值（一次性幂等）
- [x] T7 死字段：grep 确认 `LauncherConfig.hotkey` 无注册路径引用后移除字段（HotkeyConfig 类型保留供 socket/CLI 复用）
- [x] T8 测试更新：`LauncherHotkeyDefaultAcceptanceTests`（SC-17）⌘⇧Space→Ctrl+Space；`LauncherHotkeyAcceptanceTests` combo 字符串
- [x] T9 文档：根 `CLAUDE.md` + `apps/desktop/CLAUDE.md` 的 ⌘⇧Space→Ctrl+Space、移除 launcher hotkey 字段引用、补 `buddy launcher hotkey set/show/clear` CLI 文档

### 风险与缓解
- **Ctrl+Space 与部分第三方输入法（搜狗/鼠须管）冲突**：symbolichotkeys 无系统占用，但第三方输入法可能用。缓解：UI Recorder 库自带冲突 alert 让用户改键；文档声明；被占机器热键不响应时用户经 Recorder 改键恢复。
- **库 `setShortcut(nil)` vs `reset` 语义**：重置/回默认一律用 `KeyboardShortcuts.reset(.toggle)`，**禁用** `setShortcut(nil)`（后者清除非回 default）。
- **CLI set 不预检系统冲突**：库 `setShortcut` 不检测冲突（仅 Recorder UI 有 alert），契约2 已声明降级，依赖 UI Recorder alert。

### 红队验收测试（implement 阶段编写）
基于验收场景生成器 16 场景，红队编写可自动化的 acceptance 测试 + 文本清单覆盖手动场景：
- A1/A2/A3 默认值与 Recorder 一致性（断言 LauncherHotkey.default + combo 回显）
- D1 hotkey show 输出（mock socket 响应）
- E2 非法组合 CLI 参数校验拒绝
- F2 坏值升级清理（迁移逻辑单元测试）
- G2 重启持久化（UserDefaults）

### 验证方案（真实测试场景）

**自动化测试可覆盖**（红队 acceptance + 单元）：
- A1 全新安装默认 Ctrl+Space｜A2 ⌘⇧Space 不再默认｜A3 Recorder 反映真实生效热键
- D1 hotkey show 输出（mock）｜E2 非法组合被拒｜F2 坏值升级清理｜G2 重启持久化

**手动 QA / 集成测试**（需真实 app + socket，QA 阶段执行）：
- B1/B2/B3 UI Recorder 录制/重置/取消（GUI 交互 + Observable State Transitions：RecorderCocoa 录制态 placeholder → 按键 → stringValue 变 combo → shortcutDidChange 通知 → getShortcut 返回新值；B2 reset 后 getShortcut==defaultShortcut）
- C1/C2 冲突提示（需外部应用占键）
- D2/D3 CLI set/clear 即时生效（运行中 app + socket 真实往返）—— 命令后**立即**按新热键验证，不插重启
- E1 app 未运行 CLI 行为（超时失败）｜E3 CLI set 冲突组合（**降级**：CLI 不预检系统冲突，仅验证参数校验拒绝路径；系统冲突由 UI Recorder C1 覆盖）
- F1 合法旧值升级保留｜G1 UI/CLI 双向一致｜G3 既有功能无连带回归

**关键回归断言**：`LauncherHotkeyDefaultAcceptanceTests`（SC-17）从 ⌘⇧Space 更新为 Ctrl+Space，是改默认键的契约守护，红队必须覆盖。

## 红队验收测试

- `tests/BuddyCoreTests/Launcher/LauncherHotkeyDefaultAcceptanceTests.swift`（更新 SC-17：4 用例，默认 ⌘⇧Space→Ctrl+Space 守护 + modifiers 精确位 + rawValue "launcher-toggle" 锁定）
- `tests/BuddyCoreTests/Launcher/LauncherHotkeyConfigAcceptanceTests.swift`（新建 17 用例：socket 契约 hotkey_set/show/clear schema、Ctrl+Space 默认、reset 语义非 setShortcut(nil)、非法 modifiers/key 拒绝、类型契约、迁移幂等、持久化、单一真相源状态转移序列）

**验收标准覆盖**：A1/A2/A3 默认值与 Recorder 一致性｜D1 show 输出 combo+isDefault｜E2 非法 modifiers(foobar/BANANA)/空 key/类型不符 拒绝｜F2 迁移清理+幂等｜G2 持久化｜契约1(rawValue 锁定) 契约2(socket schema+reset 语义) 。强 XCTAssert 断言，无 soft skip。

## QA 报告

### 轮次 1 (2026-06-15T11:40:00Z)

**Wave 1 — 命令执行**
- **Tier 0 红队验收**：✅ 含在 test-fast 1117 内（LauncherHotkeyConfigAcceptanceTests 17 用例 + LauncherHotkeyDefaultAcceptanceTests 4 用例 SC-17 Ctrl+Space）
- **Tier 1 编译**：✅ `make test-fast` 编译通过（SourceKit IDE 报错 "Cannot find type 'KeyboardShortcutsViewController'/'HotkeyKeyMapper'" + "No such module 'KeyboardShortcuts'/'XCTest'" 确认为**新建文件索引滞后误报**，权威 `swift build` 通过）
- **Tier 1 单元测试**：✅ 1117 tests, 1 skipped, 0 failures (58.5s)
- **Tier 1 lint**：✅ SwiftLint 0 violations, 0 serious (135 files)

**Tier 1.5 真实场景**（QA 独立执行，dev app + dev buddy-cli `.build/x86_64-apple-macosx/debug/buddy-cli`，不采信蓝队）

| 场景 | 执行 | 输出 | 结果 |
|---|---|---|---|
| A1/A3/D1 | `hotkey show` | `{"data":{"combo":"⃒Space","isDefault":true},"status":"ok"}` exit 0 | ✅ |
| D2/B1-socket/G1 | `set --key p --modifiers command,shift` → 立即 show | set `⇧⌘P` isDefault:false；show 立即反映 | ✅ 即时生效 |
| D3/B2-socket | `hotkey clear` → show | `⃒Space` isDefault:true（reset 非 setShortcut(nil) 清除） | ✅ |
| A2 | clear 后默认 combo | `⃒Space`（非 ⌘⇧Space） | ✅ |
| E2 | `set --modifiers foobar` / 缺 key / 缺 modifiers | `invalid modifier`/Usage/`--modifiers is required` 均 exit 2 | ✅ |
| E1 | 退出 dev app 后 `hotkey show` | `Buddy app is not running. Start the app first.` exit 非0 | ✅ |
| F2 | 注入坏值 `GARBAGE_NOT_JSON` + 清标志 + 重启 dev app | show → `⃒Space` isDefault:true；迁移标志=1 | ✅ 清理 |
| F1/G2 | `set ⌘K` + 重启（标志已置）→ show | `⌘K` isDefault:false（保留，幂等不清理 + 持久化） | ✅ |
| G3 | `launcher config get` | `No providers configured...`（既有命令正常） | ✅ |
| E3 | 降级 = E2 参数校验路径（契约 2 声明 CLI 不预检系统冲突） | 同 E2 exit 2 | ✅ |
| B3 | GUI Recorder 录制态取消 | 无 socket 等价（RecorderCocoa 库自带 Esc 取消 + qa-reviewer 验证用法） | ⚠️ 手动 QA |
| C1/C2 | 外部应用占键冲突 | 契约 2 降级：CLI 不预检系统冲突，依赖 UI Recorder alert；qa-reviewer Section A 验证 setShortcut 不检测冲突 | ⚠️ 手动 QA |

**场景计数**：独立执行 E=16，设计场景 N=19（A1-G3），差额 3 = B3/C1/C2（GUI Recorder / 外部应用占键，设计标「手动 QA 需外部依赖」，CLI 环境不可执行）。Wave 1 契约测试（17 用例）+ qa-reviewer Section A 代码契约审查覆盖其语义。

**Tier 1.5 ⚠️ 复盘**: B3/C1/C2 为 GUI/外部依赖手动 QA 场景（非功能不可用）—— C1/C2 设计明确「需外部应用占键」，契约 2 已降级声明 CLI 不预检系统冲突；B3 为 GUI Recorder 行为。属「测试环境/工具配置」类 → 保持 ⚠️。

**Wave 2 — qa-reviewer 独立审查**：**PASS**（可合并）
- Section A 设计符合性：6/6 契约全 PASS（契约1 rawValue 锁定+default Ctrl+Space、契约2 socket schema+reset 语义、契约3 默认 combo、契约4 CLI exit code、迁移 T6 幂等）。两处实现宽松化（modifiers 别名、socket 层空 modifiers）不违约。
- Section B 代码质量：3 个非阻断技术债：
  - B-1 [85] `MainActor.assumeIsolated` 隐式主线程契约（依赖 SessionManager.onQuery 派主线程）→ 建议 P1 加固（handle 标 @MainActor 或 dispatchPrecondition）
  - B-2 [88] 主线程同步写 socket 循环（所有 query 派主线程，过度修正）→ 建议 P2 仅 hotkey 分支上主线程
  - B-3 [82] socket 层允许空 modifiers（CLI 禁止）→ 建议 P2 app 侧加 !isEmpty 校验
- 均纵深防御/技术债，不影响当前功能（Tier 1.5 端到端验证通过），不阻断交付。

**结果判定**：Tier 0 ✅ / Tier 1 ✅（1117 测试 + lint 0 + 编译通过，SourceKit 报错确认误报）/ Tier 1.5 ✅（QA 独立执行 16 场景 + 3 基础设施类 ⚠️）/ Tier 2 ✅（qa-reviewer PASS）。全部 ✅（仅基础设施类 ⚠️）→ **gate: review-accept**。

**轮次 1 加固（review 后修 qa-reviewer B-1+B-3）**：用户 review 要求顺手修。B-1：`QueryHandler.handle` 标 `@MainActor`（编译期保证主线程，去掉 hotkey 分支 `MainActor.assumeIsolated` 隐式契约，`SessionManager.onQuery` 改 `Task { @MainActor }`）；B-3：`handleHotkeySet` 拒绝空/nil modifiers（`guard !isEmpty`，与 CLI 护栏对齐）。重验：test-fast 1117 passed 0 failures + lint 0 + 真实 socket 往返（hotkey show/set/clear 经 Task @MainActor 正常返回不 hang）。

**轮次 1 加固补充（B-2 修复）**：用户要求继续修 B-2。`SocketServer` 加 `sendResponseAsync`（`queue.async` 上执行同步写循环），`SessionManager.onQuery` 改用 `sendResponseAsync` —— handle 仍 @MainActor 主线程，sendResponse 回 socket queue 不阻塞 UI。重验：test-fast 1117 passed 0 failures + lint 0 + 真实 socket 往返（hotkey show/set/clear + 非 hotkey status 全部经 sendResponseAsync 正确返回不 hang）。**qa-reviewer B-1/B-2/B-3 全部修复，无遗留技术债**。

## 变更日志
- [2026-06-16T03:33:03Z] 用户批准验收，进入合并阶段。反馈: &
- [2026-06-15T10:32:01Z] autopilot 初始化，目标: 我们参考 alfred 的热键支持设计（要大，要方便），给当前的 buddy launcher 支持下热键配置能力，然后把默认键改成 ctrl + space
- [2026-06-15T10:36:30Z] 模式决策: standard (fast_mode=false) — 任务跨 UI/CLI/配置层 + 存储统一架构决策 (launcher.json vs KeyboardShortcuts UserDefaults) + contract_required=true，非同质 diff。现状: LauncherConfig.hotkey 死字段、无 UI Recorder、CLI 不支持 hotkey；已有 SettingsWindowController tab 体系可挂 Recorder；约束: buddy-cli 不依赖 BuddyCore (KeyboardShortcuts 库)
- [2026-06-15T10:46:00Z] design: brainstorm 选定方案 A（库 UserDefaults 单一真相源 + socket 双向命令）。plan-reviewer 初审 FAIL（BLOCKER-1: setShortcut(nil) 是清除非回 default；BLOCKER-2: 库 setShortcut 不检测系统冲突，CLI 冲突检测不可实现）。修正：reset 替代 setShortcut(nil)、契约2 降级（CLI 不预检系统冲突）、加 T9 文档任务、风险章节、B 场景补 Observable State Transitions。第2轮 PASS（reset API KeyboardShortcuts.swift:320 独立验证语义为回 defaultShortcut）。剩余非阻塞重要问题：implement 实测 setShortcut 后库自动重注册。
- [2026-06-15T10:48:00Z] design 审批通过（用户选「通过，开始实现」）。phase → implement。启动蓝红队对抗实现。
- [2026-06-15T10:56:00Z] 红队完成：交付 LauncherHotkeyDefaultAcceptanceTests.swift（更新 SC-17 → Ctrl+Space）+ LauncherHotkeyConfigAcceptanceTests.swift（新建 17 用例：契约 schema/默认值/reset 语义/非法参数/迁移幂等/持久化/单一真相源）。红灯确认：swift build --target BuddyCoreTests 仅 4 个 migrateLegacyIfNeeded 缺失 error（T6 蓝队待实现），测试代码零语法错误。蓝队仍在跑。
- [2026-06-15T11:35:00Z] 蓝队完成 T1-T9（17 文件 +1225/-115，46 相关测试全绿，真实场景验证：socket 往返即时生效/迁移清理/非法参数 exit 2 全通过）。[!] T4 QueryHandler @MainActor 隔离用 MainActor.assumeIsolated 解决。设计偏差：① combo 本地化（zh「空格」/en「Space」）测试改本地化无关 ② CLI 强制 modifiers 非空（全局热键不带修饰键与打字冲突）③ SocketServer onQuery 改派主线程。合流完成，phase → qa。
- [2026-06-15T12:10:00Z] QA 完成（轮次1）：Wave 1 全绿（make test-fast 1117 passed 0 failures + lint 0 + 编译通过，SourceKit 报错确认新建文件索引滞后误报）；Tier 1.5 QA 独立执行 16 场景全通过（dev app + dev buddy-cli socket 往返/迁移清理/幂等持久化/app 未运行/非法参数 exit 2，E=16 N=19 差额 3=B3/C1/C2 GUI·外部手动 QA）；Wave 2 qa-reviewer PASS（6/6 契约 + 3 非阻断技术债 B-1/B-2/B-3）。判定全部 ✅（仅基础设施类 ⚠️）→ gate review-accept。
- [2026-06-15T12:50:00Z] QA 后加固（用户 review 要求修 qa-reviewer B-1+B-3）：B-1 QueryHandler.handle 标 @MainActor（编译期保证，去掉 hotkey 分支 MainActor.assumeIsolated，SessionManager.onQuery 改 Task { @MainActor }）；B-3 handleHotkeySet 拒绝空/nil modifiers（与 CLI 护栏对齐）。重验：test-fast 1117 绿 + 真实 socket 往返（show/set/clear Task @MainActor 正常不 hang）+ lint 0。B-2（主线程写 socket P2）未修（需重构 sendResponse，本地小 payload影响小，单独跟进）。
- [2026-06-16T01:10:00Z] B-2 修复（用户要求继续修）：SocketServer 加 sendResponseAsync（queue.async 上执行同步写循环），SessionManager.onQuery 改用 sendResponseAsync —— handle 仍 @MainActor 主线程（B-1），sendResponse 回 socket queue 不阻塞 UI。重验：test-fast 1117 passed 0 failures + lint 0 + 真实 socket 往返（hotkey show/set/clear + 非 hotkey status 全部经 sendResponseAsync 正确返回不 hang）。**qa-reviewer B-1/B-2/B-3 全部修复完成**。
