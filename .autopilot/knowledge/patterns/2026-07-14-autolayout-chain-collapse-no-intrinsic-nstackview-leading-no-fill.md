---
name: autolayout-chain-collapse-no-intrinsic-nstackview-leading-no-fill
description: 三类 autolayout 高度/宽度链塌缩坑同构——(1) 无 intrinsicContentSize 的 NSView（formPanel/普通容器）漏 bottom 约束 → 高度 0 → 下游 top 锚点上移与上层重叠穿插；(2) NSStackView alignment=.leading 下 arrangedSubview 默认不撑满 cross-axis，需显式 leading+trailing 钉死否则宽度由子 intrinsic 决定（content editor 宽由 NSTextView containerSize 决定非占满 cell）；(3) NSScrollView documentView 嵌套 NSSplitViewController 下 autolayout 全失效。共同特征：headless 单测不暴露（cell 渲染时序/嵌套 containment 上下文），须真机 frame dump + 视觉 oracle 诊断；红队+蓝队契约测试全绿 ≠ 真机无 bug
metadata:
  type: pattern
---

# autolayout 高度/宽度链塌缩三坑同构（无 intrinsic / StackView 不撑满 / 嵌套 scrollView）

## 共同症状

设置页 UI 真机视觉错乱（字段穿插重叠 / 输入框跑到错误位置 / 整片白屏），但 headless XCTest 契约测试全绿（红队 + 蓝队 73 tests 0 failures）。用户真机验收才发现。

## 三坑根因对比（2026-07-14 设置页交互优化，commit 5f5af1b）

| 坑 | 位置 | 根因 | 修法 |
|---|---|---|---|
| AI 配置字段穿插重叠 | ProviderSettingsViewController formPanel | formPanel（无 intrinsicContentSize 的普通 NSView）只钉 providerGroup top/leading/trailing **漏 bottom** → 高度塌缩 0 → formStackView intrinsicHeight 塌缩 → 下方 AI 工具分组 `toolsLabel.top(=formStackView.bottom)` 锚点上移到 tab 下方 → 表单 group 与工具分组在同一垂直区域重叠穿插 | 补 `providerGroup.bottomAnchor = formPanel.bottomAnchor` 钉死高度链 |
| snip content 跑到 keyword 那边 | SnipPanelVC editorContainer.stack | `NSStackView(vertical, alignment=.leading)` 下 arrangedSubview（group）默认**不撑满 cross-axis**（宽度=fitting 而非铺满 stack），group 不撑满 → contentRowBox 不撑满 → editorScrollView 宽由 NSTextView containerSize(360) 决定，det-machine 实测 184pt / cell 724pt = **25%**（create 态 307pt/42%）| group 显式钉 `leading+trailing = stack` 撑满 cross-axis；content 改独立布局（标签上 + editor 占满下方宽度），复测 676/724=**93%** |
| snip 核心 documentView 白屏 | ContentColumnView（gallery 外层）| NSScrollView documentView 嵌套 NSSplitViewController 下 autolayout 约束全失效 → 0×0 | documentView.autoresizingMask=[.width] + layout() override 手动 frame（详见 [2026-07-12 pattern](2026-07-12-nsscrollview-documentview-autolayout-nested-splitview-collapse-manual-frame.md)）|

## 共同机制：autolayout 高度/宽度链断裂

三坑都是 autolayout 链中某个节点的高度/宽度**塌缩为 0 或不撑满**，但**下游约束参考了这个塌缩值**，导致下游位置/尺寸错乱：

- 坑1：formPanel 高度 0 → formStackView 0 → `toolsLabel.top` 上移（下游 top 参考塌缩 bottom）
- 坑2：group 不撑满 → contentRowBox 不撑满 → editor 宽由子决定（下游 trailing 参考塌缩宽度）
- 坑3：documentView 0×0 → contentColumn 0 高 → 整片白屏（下游锚点参考塌缩 frame）

## 为什么 headless 单测不暴露（[[autopilot-tier-green-not-bug-free]] 再实证）

1. **cell 渲染时序**：NSTableView reloadData 后 cell 创建/布局在 headless 无 window 时不完整（AX/editor 不可达，expandedRowHeight=0）；红队用 `guard expandedRowIndex != nil else { return }` 跳过 + 真机覆盖
2. **嵌套 containment 上下文**：formPanel 高度塌缩在 headless 单测（单独实例化 ProviderSettingsViewController）不触发，因为缺完整 window/NSSplitViewController containment 链
3. **契约测试粒度**：红队测「每行单一 control」（C-AI-ONE-CONTROL-PER-ROW）在 headless PASS（行级 Y 不重叠），但测不出「两个分组跨 group 重叠穿插」（跨容器几何）

## 诊断方法（真机独立 oracle，非 headless/快照 baseline）

1. **det-machine frame dump**：扩 CLI debug 命令输出关键 view 的 frame（`debug_contentScrollViewFrame` / `debugSettingsState` 加 `snip_expanded_row`），jq 校验宽度/高度占比（content editor 676/724=93% vs 塌缩 184/724=25% — 铁证）
2. **qwen vision 真机截图**：独立视觉 oracle 判读字段顺序/位置（AI 配置穿插：激活提供者→内置能力→关闭思考→已装插件→连接测试→API密钥 = 穿插；修复后顺序正常 / snip 搜索框 85% 宽）
3. **stop-hook §5.7 谓词 artifact**：每条 PASS 谓词须真实驱动 artifact（CLI get-state / qwen vision / XCTest dump），非 mock/快照。⚠️ state.md 验收场景的 `artifact:` 路径字段不能带括号注释（stop-hook 不 strip，把括号算进文件名 → test -f 失败误报缺失）

## 修法原则（防回归）

1. **无 intrinsicContentSize 的 NSView**（普通容器 / formPanel）：四边约束钉死（top/leading/trailing/**bottom**），不能漏 bottom（否则高度塌缩 0，下游 top 锚点上移重叠）
2. **NSStackView(vertical)**：arrangedSubview 要撑满 cross-axis（宽度），必须显式钉 `leading+trailing = stackView`（alignment=.leading 默认只左对齐，不撑满 cross-axis）
3. **NSScrollView documentView 嵌套 NSSplitViewController**：autolayout 不可靠，用 autoresizingMask + 手动 frame（见 [2026-07-12](2026-07-12-nsscrollview-documentview-autolayout-nested-splitview-collapse-manual-frame.md)）
4. **大文本/多行控件**：标签上 + 输入框占满下方宽度，不用左/右双栏 row（SettingsFormRow 右侧 control 区 ~120-360pt 装不下 160 高大 editor）

## 关联 patterns

- [NSScrollView documentView 嵌套塌缩](2026-07-12-nsscrollview-documentview-autolayout-nested-splitview-collapse-manual-frame.md)（坑3 详细）
- [custom-nsview-autolayout-zero-size-testhook-blindspot](2026-07-09-custom-nsview-autolayout-zero-size-testhook-blindspot.md)（无 intrinsic NSView 0 尺寸）
- [appkit-layout-headless-geometry-in-process](2026-07-11-appkit-layout-headless-geometry-in-process.md)（headless vs 真机几何）
- memory: `autopilot-tier-green-not-bug-free`（红队全绿 ≠ 真机无 bug — 本案再实证，autolayout 塌缩类 bug 是其高发区）
