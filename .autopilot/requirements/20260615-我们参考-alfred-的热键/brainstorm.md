# Brainstorm — buddy launcher 热键配置能力

## 探索的目的与约束

**目标**：参考 Alfred 的热键配置设计（大而方便），给 buddy launcher 增加热键配置能力，默认键改成 ctrl+space。

**项目上下文探索关键发现**：
1. 热键注册现状：`LauncherHotkey.swift` 用 KeyboardShortcuts 库 (sindresorhus 2.4.0)，`Name("launcher-toggle", default: ⌘⇧Space)`，存储在 UserDefaults `KeyboardShortcuts_launcher-toggle`，注册走 Carbon `RegisterEventHotKey`。
2. 配置能力几乎为零：`LauncherConfig.hotkey`（`HotkeyConfig{key,modifiers}`）是**死代码**（无人读取）；无任何 Recorder UI 实例（仅注释"MVP 仅打日志"）；CLI `buddy launcher config` 只管 provider。
3. 已有设置面板体系：`SettingsWindowController` + Tab 枚举（skins/plugins）+ `switchTo(tab:)` + segmentedControl；menubar `SessionPopoverController` 齿轮 `onSettings` 入口。加新 tab 是成熟扩展模式（扩枚举 + 加 VC 属性 + switchTo case + segmentCount/label）。
4. SwiftUI↔AppKit 桥接已有先例（`LauncherHostingController`/`MarketHUD` 用 NSHostingController）；且 KeyboardShortcuts 库提供 AppKit 原生 `RecorderCocoa`（无需桥接）。
5. 刚解决的 bug：升级 0.18.0→0.30.0 后旧 UserDefaults 值与库 2.4.0 不兼容导致热键失效（删值重注册修复）——提示**升级迁移是该任务必处理点**。
6. 实测：Carbon 全局热键（⌘⇧Space / ⌘⇧P）在本机 macOS 26.4 正常工作。

**明确约束**：
- buddy-cli target **不能依赖 BuddyCore**（含 KeyboardShortcuts 库）——CLI 改键不能直接调库，也不应直写库内部 UserDefaults 格式（避免重蹈升级 bug）。
- LSUIElement + ad-hoc 签名既有约束（Recorder/Carbon 注册不受影响）。
- 用户已选入口范围：**设置面板 tab + CLI 命令**。

## 候选方案与权衡

### 方案 A：库 UserDefaults 单一真相源 + socket 双向命令（✅ 已选定）
- 存储统一在 KeyboardShortcuts UserDefaults（库管理，不碰内部格式）
- UI：设置面板"热键"tab → `RecorderCocoa`（库原生）+ 当前热键展示 + 「重置默认」+ 冲突提示
- CLI：`buddy launcher hotkey set/show/clear` → Unix socket → **app 进程内**调库 API（`setShortcut/getShortcut/disable`）→ 即时重注册
- 升级迁移：启动清理不兼容旧 UserDefaults 值
- 优势：无双轨同步、即时生效、CLI 零库格式耦合、复用库 Recorder+冲突检测
- 劣势：需扩展 socket 协议（加 hotkey 命令）

### 方案 B：库 UserDefaults + CLI 直写库 JSON（❌ 排除）
- CLI 直接 `defaults write` 库内部 JSON，改完重启生效
- 排除原因：CLI 耦合库内部存储格式——正是刚遇到升级 bug 的根源，库升级易再断

### 方案 C：launcher.json 真相源 + 自实现 Recorder（❌ 排除）
- 抛弃库存储，自实现 Carbon Recorder + 注册
- 排除原因：重复造库的轮子（Recorder+冲突检测），工作量大，违背 YAGNI

## 选择与理由

**选定：方案 A**

1. 复用 KeyboardShortcuts 库成熟的 Recorder + 冲突检测，不重造轮子
2. CLI 通过 socket 间接调库 API，从架构上根除"CLI 写的格式与库不兼容"（方案 B 致命缺陷）
3. 即时生效（app 进程内 `setShortcut` 自动重注册），无需重启，符合 Alfred 即时体验
4. socket 扩展是增量——buddy CLI 本就走 socket 和 app 通信（ping/emit/session），双向 query 基础已有（知识库 `socket-bidirectional` pattern）

被排除：B（库格式耦合=升级 bug 复发风险）、C（重造 Recorder 轮子）

## 待主 SKILL 接力的设计决策

以下点需在 design 阶段深化为设计文档 + 实现计划：

1. **CLI `hotkey set` 参数格式**：倾向结构化 `--key space --modifiers control,shift`（对齐 `HotkeyConfig` 语义，易校验）；`show` 输出当前 combo（标注是否 default）；`clear` 清除自定义回到 default。完整 usage/help 文案。

2. **socket 协议扩展**：在现有 HookMessage / 双向 query 基础上加 hotkey 命令。消息候选：`{action:"hotkey_set", key:"space", modifiers:["control"]}` / `{action:"hotkey_show"}` / `{action:"hotkey_clear"}`，app 侧调库 API 后回 `{ok:true, combo:"⌃Space", isDefault:bool}`。需读现有 socket 双向 query 实现对齐格式。

3. **Recorder UI（Alfred 风格"大而方便"）**：新建 `KeyboardShortcutsViewController`（AppKit，遵循 `SettingsTabClickReceiver`）+ 内嵌 `RecorderCocoa`。布局：标题"启动器热键" + 大尺寸 RecorderCocoa + 当前 combo 大字回显 + 「重置默认」按钮 + 冲突红字提示。tab 标签"热键"（segmentedControl 加第 3 段）。

4. **升级迁移逻辑**：加一次性迁移标志 UserDefaults key（如 `launcher.hotkeyMigrationV1`），老用户首次启动新版本时清理 `KeyboardShortcuts_launcher-toggle`（让库用新 default ctrl+space 重注册）+ 置标志，避免每次启动都清理。这是从根上解决刚遇到的升级 bug。

5. **默认键 ctrl+space 落地**：`LauncherHotkey.swift` 改 `default: .init(.space, modifiers:[.control])`。已确认 Ctrl+Space 在系统 symbolichotkeys 无占用（⌘+Space 是输入法 key60、⌥⌃Space 是输入法 key61，纯 ⌃+Space 空闲）。

6. **LauncherConfig.hotkey 死字段处置**：该字段与方案 A 库存储无关。设计文档需明确废弃删除 vs 保留——倾向废弃（避免双源混淆），但需确认无其他引用再删。

7. **契约规约**（contract_required=true）：socket hotkey 命令消息 schema（action/key/modifiers/返回结构）、`LauncherHotkey.toggle` 的 Name 契约不变（rawValue `"launcher-toggle"` 锁定，仅 default 改）、默认 combo 契约（ctrl+space）。

8. **测试策略**：红队验收——UI Recorder 渲染、socket hotkey_set/show/clear 往返、默认键断言（ctrl+space）、迁移清理逻辑、冲突提示。注意现有 `LauncherHotkeyDefaultAcceptanceTests`（SC-17 断言 ⌘⇧Space）需更新为 ctrl+space。
