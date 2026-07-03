# brainstorm — 新增 screenshot 截屏内置插件

## 探索的目的与约束

**用户目标一句话**：为 claude-code-buddy 的 launcher 新增「screenshot 截屏」内置能力，交互对标微信截屏（区域选择 + 标注 + 贴图 + 快捷召唤），作为 `BuiltinPlugin` 实现，完全对标已有的 `lock` 锁屏能力的实现模式。

**前置研究**：通过 deep-research 工作流（99 agent / 17 源 / 25 条对抗式验证）调研了 macOS 开源截屏方案，结论是 **Capso**（`github.com/lzhgus/Capso`，原生 Swift 6 / SwiftUI，12 个独立 SPM 子包，BSL 1.1 license）是最契合「集成进现有 SwiftUI/AppKit 项目」诉求的候选——唯一明确声明模块化嵌入（可单独引入 CaptureKit/AnnotationKit 而不带入整个 shell）。

**项目上下文探索关键发现**（均带 file:line 证据）：

1. **内置插件协议与注册**：`BuiltinPlugin.swift:5-25`（`id/priority/sectionTitle/summary/description/actions(for:)`），注册在 `BuiltinPluginRegistry.swift:31-36`（现有 4 个：SystemCommand/Calculator/Paste/AppLauncher，按 priority 降序仲裁）。
2. **lock 的实现模式（screenshot 直接对齐）**：lock 是 `SystemCommandPlugin.swift` 的一个子动作，seam 协议 `ScreenLocking.swift:5-41`（生产/测试分离）+ dlopen `login.framework` 私有框架。无需额外 TCC 权限。
3. **新增 screenshot 落点**：`Sources/ClaudeCodeBuddy/Launcher/Builtin/Screenshot/`，实现 `BuiltinPlugin`，注册到 `BuiltinPluginRegistry:31-36`，日志走 `BuddyLogger`（subsystem `"builtin"`，契约 C3/C6 禁 `print`/`NSLog`）。
4. **SPM 结构**：`apps/desktop/Package.swift` 是 Swift Package（非 Xcode project），当前 `.macOS(.v14)`（Package.swift:7），依赖 `swift-snapshot-testing` 1.17+ 与 `KeyboardShortcuts` 2.0+。
5. **触发机制**：launcher 默认 `Ctrl+Space` 召唤（`LauncherHotkey.swift:7-10`，复用 KeyboardShortcuts 库），输入→`LauncherManager.updateQuery`→`BuiltinPluginRegistry.actions(for:)`→score 排序→Enter 执行。
6. **社区插件优先约定**（CLAUDE.md:221-237，2026-06-28）：新能力默认走社区插件，仅 4 类留内置（已有四插件 / 需系统私有框架 / 高频常驻 / 核心路由）。**screenshot 需常驻全屏 overlay UI + 浮动贴图窗口，社区插件是子进程画不了，走内置是技术必须，不违反约定**（契合「高频/常驻」与「需系统框架」两类）。
7. **空白地带**：项目当前**无任何 ScreenCaptureKit/CGWindowList 使用痕迹，无统一 macOS 权限（Accessibility/Screen Recording/Automation）工具类**——screenshot 是首个引入屏幕录制权限的能力。

**明确约束（用户已确认）**：

- 截屏是**辅助功能、非主功能** → Capso BSL 1.1 的 Additional Use Grant 边界允许（BSL 禁止「以截屏为主功能的商业产品/服务」，本场景不触发；2029-04-08 自动转 Apache 2.0）。
- **macOS 部署版本升到 15**（用户决策，接受 Sonoma 14 存量用户掉队；影响面是整个 app 不只截屏）。
- **触发方式：只走 launcher 命令**（`Ctrl+Space` → 输「截屏」→ Enter 启动选区 overlay），**不占独立全局热键**，与 lock 完全一致，架构最简。
- **v1 范围：拖框区域选择 + 全套标注（画笔/箭头/矩形/椭圆/马赛克/文字/序号）+ 复制到剪贴板/保存**。
- **v2 范围：贴图 pin-to-screen**（浮动置顶 + 透明度 + click-through + 跨 Space）。
- 日志必须 `BuddyLogger`；`.autopilot` 必须 git 提交。

## 候选方案与权衡

### 方案 A（选定）：Capso SPM 子包 + 分期实现

- **v1**：拖框区域选择（Capso `CaptureKit`）+ 全套标注（Capso `AnnotationKit`）+ 复制/保存
- **v2**：贴图 pin-to-screen（Capso 12 子包无独立 PinKit，基于 `NSPanel` 自研，参照 DodoShot `FloatingWindowService`）
- **优势**：标注若 AnnotationKit 现成则成本极低；原生 Swift 6/SwiftUI 与项目栈一致；模块化嵌入契合「集成」诉求；贴图风险与集成风险分期解耦。
- **劣势**：强制 macOS 15（掉 Sonoma 用户）；AnnotationKit 的 API 面（现成编辑器 UI vs 底层图元）**未实测**；贴图无现成子包需自研；BSL 边界依赖「非主功能」判定（需向作者留痕确认）。

### 方案 B：一次性全功能（Capso + 自研贴图一次做完）

- v1 直接含区域选择 + 全套标注 + 贴图，一步对标微信。
- **优势**：一次达成完整对标。
- **劣势**：贴图（NSPanel 浮窗生命周期 + 多 Space + 透明度 + click-through）与 Capso 集成双重未验证风险叠加，周期最长、返工概率最高。
- **排除原因**：违背「先验证 Capso 集成再啃最不确定的贴图」的递进原则，风险未隔离。

### 方案 C：最小 v1（仅区域选择 + 复制）

- v1 只用 Capso `CaptureKit` 做拖框选区 + 复制/保存，标注与贴图都延后。
- **优势**：最快验证 Capso 集成 + Screen Recording 权限链路。
- **劣势**：v1 体验最薄（无标注），离微信对标最远。
- **排除原因**：标注若走 AnnotationKit 成本可控，没必要切这么薄；用户明确要标注。

> **研究中其他候选（已排除，保留为退路）**：fork Snapzy（BSD-3，macOS 13+，标注最全）/ DodoShot（MIT，macOS 14+，贴图最强）/ 基于 ScreenCaptureKit 完全自研。因用户选定 Capso 且愿升 macOS 15 而排除。
>
> **退路备忘**：若实现期发现 Capso 子包无法干净嵌入 SPM，回退到基于 ScreenCaptureKit 自研轻量版（届时 macOS 15 也不必升，回到 14），标注参照 Snapzy 实现、贴图参照 DodoShot `FloatingWindowService`。

## 选择与理由

**选定方案：A（Capso SPM 子包 + 分期：v1 区域选择+标注，v2 贴图）**

- **选择理由**：用户基于深度研究选定 Capso（功能最完整、唯一模块化、原生 Swift），并愿为此升 macOS 15；分期把「Capso 集成风险（子包 API 未实测）」与「贴图风险（无现成子包）」解耦——先打通可用的区域选择+标注（Capso 现成能力），再啃最不确定的贴图（自研 NSPanel）。
- **排除 B**：风险叠加、周期长、返工多。
- **排除 C**：标注成本低，切太薄不划算，且偏离用户对标微信的明确诉求。

## 待主 SKILL 接力的设计决策（设计文档需深化）

1. **Capso 子包选型与嵌入验证（设计文档第一步，阻断性）**：
   - clone Capso，确认 `CaptureKit`/`AnnotationKit` 是否独立可编译、API 面（AnnotationKit 是现成编辑器 UI 还是底层图元集合）。
   - 核实 CONTRIBUTING.md（8 包）vs README（12 包）的文档不一致，确认真实包结构与依赖图。
   - 确认 BSL 1.1 边界：向作者 @lzhgus 发 issue 留痕确认「claude-code-buddy 截屏作为辅助功能」落在 Additional Use Grant 允许范围内。
   - **若嵌入失败 → 启动退路（自研路线 + 回退 macOS 14）**。

2. **macOS 15 升级影响面评估**：
   - 改 `Package.swift:7` `.macOS(.v14)` → `.macOS(.v15)`。
   - 评估存量 Sonoma 14 用户影响、是否需要版本提示或灰度。
   - 复核现有依赖（KeyboardShortcuts 2.4.0 / swift-snapshot-testing 1.19.2）在 macOS 15 的兼容性。

3. **ScreenshotPlugin 架构（对齐 lock 模式）**：
   - 目录 `Sources/ClaudeCodeBuddy/Launcher/Builtin/Screenshot/`。
   - `ScreenshotPlugin: BuiltinPlugin`（`id="screenshot"`、`sectionTitle="截屏"`、`priority` 与 SystemCommand 协调避免压栈）。
   - seam 协议（参照 `ScreenLocking.swift`）：`ScreenCapturing`（区域捕获）+ `ScreenAnnotating`（标注），生产/测试分离，便于 mock。
   - 注册到 `BuiltinPluginRegistry.swift:31-36`。
   - 关键词匹配：`截屏 / screenshot / jietu / 截图`（参照 `SystemCommandPlugin.swift:58-112`）。

4. **Screen Recording 权限链路（项目首次引入，需设计）**：
   - Info.plist 增加屏幕录制 usage key（`NSScreenCaptureDescription` 或当前等价键）。
   - 首次使用授权流程：项目无统一权限工具类，设计是否新建 `PermissionHelper` 或复用现有 TOFU（`TrustPrompt.swift`/`TrustStore.swift`）模式。
   - 授权被拒/未授予的降级提示与引导到系统设置。

5. **选区 overlay UI**：
   - 全屏透明 `NSPanel`/`NSWindow`（参照 `LauncherWindow.swift` 的 NSPanel 模式），覆盖所有屏幕/多显示器。
   - 拖框选区 + `ESC` 取消 + `Enter` 确认 + 鼠标放大镜/像素坐标（**放大镜仅 macshot 有、Capso 未确认；建议 v1 先不做，v2 视用户反馈**）。

6. **标注编辑器（v1）**：
   - 全套工具：画笔/箭头/矩形/椭圆/马赛克/文字/序号 + undo/redo + 颜色/粗细。
   - 若 Capso `AnnotationKit` 是现成编辑器 → 直接嵌；若是底层图元 → 自建编辑器壳（参照 Snapzy `AnnotationToolType` enum）。

7. **复制/保存（v1）**：`NSPasteboard` 写图 + 文件保存（`NSSavePanel` 或固定目录 + BuddyLogger 记录）。

8. **贴图 pin-to-screen（v2，设计文档先占位）**：
   - `NSPanel` floating always-on-top + 可调透明度 + click-through + 跨 Space 持久。
   - 参照 DodoShot `Services/FloatingWindowService.swift`、Cindori floating-panel 实现。

9. **测试策略**：
   - 单测：`ScreenshotPlugin` 关键词匹配/路由（参照 `SystemCommandAcceptanceTests.swift`）+ seam 协议 mock。
   - 快照测试：标注编辑器 UI（swift-snapshot-testing，参照 `tests/BuddyCoreTests/SnapshotTests/`）。
   - 权限/真实捕获层走 seam mock，CI 不触发真实 TCC 弹窗。

10. **日志**：`BuddyLogger` subsystem `"builtin"`，关键节点（选区启动 / 捕获成功 / 失败 / 权限状态 / 复制/保存结果）。

**交接**：本 brainstorm 至此结束，主 SKILL 接力——读取本文档 → 写设计文档（重点先做第 1 项 Capso 嵌入验证，结论决定走 A 还是退路）→ plan-reviewer → AskUserQuestion 审批。
