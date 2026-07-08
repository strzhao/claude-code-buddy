# 自定义 NSView 子控件缺 size 约束 → Auto Layout 0×0 点不动 + test hook 盲区

> 2026-07-09 | 插件设置页左栏 PluginListCellView 的 SageSwitch（自绘开关）点不动修复（commit c74d9eb）

适用场景：AppKit 自定义 NSView 子类（非标准 NSControl，如自绘开关/滑块）作为子控件嵌入 Auto Layout 容器（NSTableView cell / NSStackView / 约束布局的 NSView）。

## 陷阱 1：translatesAutoresizingMaskIntoConstraints=false 忽略 init frame

**现象**：自定义 NSView（如 SageSwitch 自绘开关）在 init 设了 `frame: NSRect(32×20)`，嵌入 cell 用 Auto Layout（`translatesAutoresizingMaskIntoConstraints = false`），但宿主只给了 centerY/trailing 约束、漏了 width/height → Auto Layout 解析为 **0×0** → CALayer（trackLayer/knobLayer）无绘制区域 + `hitTest` 命中不到 → **控件不可见/点不动**。

**根因**：`translatesAutoresizingMaskIntoConstraints = false` 让 Auto Layout **完全接管 frame**，init 时设的 frame 被忽略。若宿主没给 size 约束、且控件本身没覆盖 `intrinsicContentSize`，Auto Layout 无 size 信息 → 解析为 0×0。

**对比铁证**：同款 SageSwitch 在 SettingsToggleRow（正常工作）显式 `widthAnchor=32 + heightAnchor=20`；PluginListCellView（cc274ce 重构新增 cell）只给 centerY+trailing 漏 size → 0×0。两处的 init frame 32×20 都没用（被 Auto Layout 忽略）——「设了 frame 为何还 0×0」是这个陷阱最反直觉处。

**方案（两层，必须都做）**：
1. 宿主给显式 size 约束（对齐成熟使用方 SettingsToggleRow:112-113）
2. **治本**：控件覆盖 `intrinsicContentSize`，向 Auto Layout 声明内在尺寸：
```swift
override var intrinsicContentSize: NSSize { NSSize(width: 32, height: 20) }
```
覆盖后即使未来使用方漏约束，也有 intrinsic size 兜底，不塌 0×0。自定义 NSView 凡是有「视觉固有尺寸」的，都应覆盖 intrinsicContentSize——这是组件向 Auto Layout 系统的自我声明。

## 陷阱 2：test hook 绕过真实 UI 交互链路（全绿带 bug）

**现象**：重构（cc274ce）后单元测试 + acceptance 测试全绿，但真实开关点不动，用户报 bug。

**根因**：旧 acceptance 测试 AT10/11 调 `vc.toggleButtonClicked(button)`——一个为旧 NSButton 路径留的 test hook（@objc），直接调 `togglePlugin`，**绕过了 SageSwitch 的真实点击链路**（`mouseDown → toggle() → onChange → cell.onToggle → togglePlugin`）。重构换了 cell 内控件（NSButton→SageSwitch），但测试仍走旧 hook → hook 一直绿，真实 SageSwitch 从无测试覆盖。印证「全绿 ≠ 消 bug」。

**方案**：验收测试走真实交互链路（CLAUDE.md「GUI 自动化测试能力 1：in-process UI 驱动」）：
- 直接触发 `switchView.mouseDown(with: NSEvent)`（`NSEvent.mouseEvent(with:.leftMouseDown,...)` 构造事件喂方法，非 XCUITest 外部 AX，非 osascript/CGEvent）
- 断言链路末端副作用（`cell.onToggle` captured 值 / `BuiltinPluginEnabledStore.isEnabled` 翻转），而非「方法被调用过」
- Mutation-Survival：mouseDown 空实现 / onChange 未接通时测试必 fail（kill no-op）
- 禁用 test hook（toggleButtonClicked）替代真实交互

**触发 layout 的坑（测 size 类断言必读）**：光 `init` cell 不 layout，frame 是 init 值或 .zero。必须放进 NSWindow + `window.layoutIfNeeded()` + `cell.layoutSubtreeIfNeeded()`，Auto Layout 才解析 frame——否则 AS-01（frame==32×20）断言测不出 0×0 root cause（修复前修复后都过不了或都过，失去鉴别力）。

## 通用诊断（AppKit 控件点不动/看不见）
1. 怀疑 size：进程内实例化控件 + 放进 window + layout，打印 `frame` / `intrinsicContentSize`（0×0 = 缺 size 声明）
2. 怀疑点击链路：状态变化点（mouseDown / onChange / togglePlugin）加 BuddyLogger，真机操作 + `buddy log grep` 确认执行路径
3. 怀疑测试盲区：grep 测试是否调 test hook（绕真实链路）vs 真实交互 API（mouseDown/performClick/selectRow）

## 关联

- [[2026-07-08-swiftui-nshosting-settings-traps]]：SwiftUI 设置页交互陷阱（@Binding 不触发 body / Form 挤 content / Button performClick 盲区），同「设置页点不动」不同技术栈
- [[2026-07-02-nsscrollview-documentview-autoresizing-width-zero]]：documentView 缺 autoresizingMask=.width → width=0，同「size 缺失 → 0 → 不可见」根因类（autoresizing vs Auto Layout 机制不同）
- [[2026-06-23-autopilot-red-team-false-report-verify-ls]]：测试可靠性，编排器必须独立验证（ls/build-tests），呼应 test hook 盲区

---
<!-- tags: appkit, nsview, auto-layout, translatesautoresizingmaskintoconstraints, intrinsiccontentsize, sageswitch, nstableview, cell, size-constraint, zero-frame, hittest, test-hook, blind-spot, in-process-test, mousedown, mutation-survival, settings, plugin-gallery, buddy-logger, diagnostics, full-green-not-bug-free -->
