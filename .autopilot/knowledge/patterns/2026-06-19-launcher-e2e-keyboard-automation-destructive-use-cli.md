# launcher 功能测试禁用 osascript 键盘自动化（抢占用户屏幕）—— 走 CLI / 编程接口

<!-- tags: launcher, e2e, testing, osascript, keyboard-automation, system-events, nspanel, hotkey, ctrl-space, destructive-test, cli-testing, qa, automation, accessibility, hijack, buddy-cli -->

**Scenario**: autopilot QA 阶段对 CalculatorPlugin 做"真机 E2E"——`osascript -e 'tell application "System Events" to keystroke ...'` 模拟 Ctrl+Space 召唤 launcher 浮窗 + 键入表达式 + Enter，用 `pbpaste` 断言剪贴板结果。

实测能跑通（`1+2*3`→剪贴板 `7`、`9/2`→`4.5`、`7%3`→`1` 都验证成功），但**用户连续两次 reject 该方案**并明确反馈"自动化测试的方案破坏性太大"。

破坏性根因（launcher 的 GUI 形态决定的）：

1. **抢占真实键盘焦点**：launcher 是 LSUIElement accessory app 的 NSPanel，`osascript keystroke` 把字符打到**当前前台 app**（用户的编辑器/终端/聊天框），不是隔离的测试沙箱。键入期间用户正在敲的代码/消息会被污染。
2. **热键 toggle 状态机**：Enter 执行后 launcher 不一定立即关闭，下一轮 Ctrl+Space 可能变成"关闭"而非"打开"toggle → 输入落空（实测批次里前 2 个用例空、后 2 个才成功，根因即此），导致**假阴性**（功能正确但 E2E "失败"）。
3. **AX 权限门槛**：System Events keystroke 要求控制进程有 Accessibility 权限，CI/headless 环境不可用。
4. **无法稳定观测候选 UI**：SwiftUI 文本不一定走 AX static text，截图又要人眼判读（非 det-machine）。

**Lesson**: launcher 这类"热键召唤的全局浮窗"子系统，**功能测试不要走键盘模拟**。两条正确路径：

- **编程接口（首选）**：候选生成是纯代码路径 `BuiltinPluginRegistry.actions(for:)` / `CalculatorPlugin.actions(for:)` → `LauncherAction`。XCTest 直接调这些（在真实 BuddyCore SDK 下运行，与运行时同一代码路径），等价于 E2E 的"输入→候选"段，且零侵入、det-machine、CI 可跑。本次 71/71 验收测试即此路径。
- **CLI 驱动（端到端补充）**：若需覆盖"召唤→渲染→选中→Enter→副作用"全链路，应给 launcher 加**可被 CLI 触发的编程入口**（类似 `buddy` CLI 驱动猫咪 session 的模式：CLI → socket → LauncherManager 注入 query / 模拟选中 / 读候选），而非抢键盘。这是后续单开的 autopilot 任务的目标。

**How to apply**:
- autopilot QA 遇 launcher / 全局热键浮窗 / NSPanel 输入类变更：Tier 1.5 用 XCTest 编程接口断言（候选 title / perform pasteboard / registry 仲裁），**禁止** `osascript keystroke` / `cliclick` / System Events 键盘模拟。
- 若 Tier 1.5 必须验真实键盘链路，先确认是否有 CLI/编程入口；没有则记为待补基础设施（→ doctor），不要用抢键盘方案凑。

**Evidence**: 2026-06-19 CalculatorPlugin QA：osascript 键盘 E2E 跑通 3/5（另 2 个假阴性是 toggle 时序），但被用户 reject；改由 71/71 XCTest（编程接口）作为权威验证合入。用户决定单开 autopilot 做 CLI 驱动的完整功能测试。

**关联**：
- [[2026-05-29-nspasteboard-test-isolation-via-named-pasteboard]]：同为"GUI 副作用的测试隔离"，但本文是"输入链路"，彼文是"输出（剪贴板）副作用"。
- [[2026-05-27-sc-coverage-matrix-as-e2e-substitute]]：项目模式用 SC 覆盖矩阵替代重复 e2e，精神一致——避免脆弱的端到端自动化。
- 与猫咪子系统对比：猫咪有 `buddy` CLI（session/emit/inspect）可无侵入驱动；launcher 目前缺等价 CLI，是待补缺口。
