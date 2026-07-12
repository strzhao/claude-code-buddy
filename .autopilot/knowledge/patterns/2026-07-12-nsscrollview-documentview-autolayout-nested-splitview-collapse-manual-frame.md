---
name: nsscrollview-documentview-autolayout-nested-splitview-collapse-manual-frame
description: NSScrollView 的 documentView 作嵌套 NSSplitViewController 的 detail 子视图时，autolayout 约束钉尺寸（width==contentView.width / top / height≥contentView.height）全部失效 → documentView 塌缩 0×0 → contentColumn 0 高 → 整片白屏（换 scrollView.heightAnchor 锚点也无效，documentView 上 autolayout 整体不可靠）；修法 = documentView.autoresizingMask=[.width] + layout() override 手动设 documentView.frame；诊断 = in-process bounds（BuddyLogger dump）非截图裁剪
metadata:
  type: pattern
---

# NSScrollView documentView 嵌套 NSSplitViewController 下 autolayout 全失效，须手动 frame

## 现象

设置页 5 个 section（plugins/hotkey/ai/general/about）右侧整片白屏，**只有 skins 正常**。窗口能打开、sidebar 正常、detail 容器有尺寸，但右侧内容区空白。

## 根因（in-process bounds 真机铁证）

`ContentColumnView`（限宽居中滚动容器：`NSScrollView → documentView → contentColumn`）作 `NSSplitViewController` 的 detail child VC 的子视图时，`documentView` 塌缩 **0×0**。contentColumn 钉 documentView 四边 → contentColumn 0 高 → 内容不可见 → 白屏。

诊断（BuddyLogger dump detail 链 bounds，切 section 后 async 0.2s 读）：

| section | scrollView | **documentView** | contentColumn | 用户观测 |
|---|---|---|---|---|
| skins | —（不用 ContentColumnView） | — | — | ✅ 正常 |
| general/about/hotkey/ai/plugins | 600×540 | **0×0** | 48~120×**0** | ❌ 白屏 |

documentView 用 autolayout 约束钉 scrollView.contentView：
```swift
documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor)   // 钉宽
documentView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor)       // 钉顶
documentView.heightAnchor.constraint(greaterThanOrEqualTo: scrollView.contentView.heightAnchor)  // 钉高
```
`scrollView.contentView.heightAnchor` 在嵌套 NSSplitViewController 下解析为 **0**（contentView 依赖 documentView + scrollView，documentView 又依赖 contentView，循环依赖 + NSScrollView 内部 layout 时序不稳）→ 整个 documentView 约束块求解失败 → 0×0。

**逐条验证 autolayout 全失效**：
- 删 width 约束 + documentView.autoresizingMask=[.width] → documentView.width 0→1712 ✅（width 修好）
- 但保留 `documentView.heightAnchor ≥ scrollView.contentView.heightAnchor` → height 仍 0（contentView.heightAnchor=0）
- 换锚点 `documentView.heightAnchor ≥ scrollView.heightAnchor`（scrollView.heightAnchor 稳定 540）→ height **仍 0**
- 把 height 约束挂到 contentColumn（普通 NSView，autolayout 正常）→ contentColumn.height 撑到 1050，但 documentView.height **仍 0**

结论：**NSScrollView 的 documentView 上，autolayout 约束（无论钉 contentView 还是 scrollView，无论 width/top/height，无论 ≥ 还是 ==）整体不可靠**——NSScrollView 用自身 tile 机制管理 documentView.frame，覆盖 autolayout（documentView.translatesAutoresizingMaskIntoConstraints 默认 true，autoresizing 生成的约束 + NSScrollView tile 共同覆盖手动约束）。

**对照：SkinGalleryViewController 不用 ContentColumnView**（scrollView + NSCollectionView 直接 autolayout 撑满 container，collectionView 自管 frame），所以不受影响——这正是「只有 skins 正常」的真因。

## 修法

`ContentColumnView`：documentView 完全脱离 autolayout，改 autoresizing + 手动 frame：

```swift
// setupView：documentView 宽度用 autoresizing 跟随 clipView（NSScrollView 自管）
documentView.autoresizingMask = [.width]
scrollView.documentView = documentView

// 删 documentView 全部 autolayout 约束（width==contentView.width / top / height≥ 全删）

// 新增 layout() override：手动设 documentView.frame 撑开 + 防贴底
override func layout() {
    super.layout()
    guard scrollView.bounds.height > 0 else { return }
    let clipWidth = scrollView.contentView.bounds.width
    let newFrame = NSRect(x: 0, y: 0, width: clipWidth, height: scrollView.bounds.height)
    if documentView.frame != newFrame { documentView.frame = newFrame }
}

// contentColumn 仍 autolayout 钉 documentView 四边（contentColumn 是普通 NSView，autolayout 正常；
// 其 anchors 反映 documentView.frame，故 contentColumn 随 documentView 撑开）
```

防贴底不再用 `documentView.heightAnchor ≥ contentView.heightAnchor`（无效），改手动 frame height = scrollView.bounds.height。

## 诊断教训（核心）

**in-process bounds 是 NSScrollView layout 问题的可靠诊断，截图裁剪不可靠**。

本轮前几轮反复误判「已修复渲染」（基于截图像素方差 sd=5400-10800），实际是截图裁剪坐标错（窗口 `center()` 随 section 宽度移位 + Cocoa y 坐标左下角换算错裁到空白桌面）。改用 BuddyLogger 在切 section 后 dump detail 链关键 view bounds（splitView / detailContainer / childRoot / ContentColumnView / scrollView / **documentView** / contentColumn），`buddy log grep` 读，才定位 documentView 0×0 真根因。

截图像素方差只能判「窗口某处有内容」，不能定位「哪个 view 0×0」。NSScrollView layout 问题必须 dump 到 documentView/clipView 层 bounds。

## Lesson

- **NSScrollView documentView 上 autolayout 约束钉尺寸整体不可靠**（嵌套 NSSplitViewController 下尤甚）：[[nsscrollview-documentview-autoresizing-width-zero]] 只说 width=0，本轮深化发现 height 约束（钉 contentView/scrollView 均无效）+ 整体 autolayout 不可用。documentView 用 autoresizing（width）+ 手动 frame（height）管理。
- **防贴底约束挂 documentView 无效，挂 contentColumn（普通 NSView）有效但撑不开 documentView**：documentView 的 frame 由 NSScrollView tile 管，子视图 autolayout 撑不开父 documentView。须手动设 documentView.frame。
- **NSSplitViewController fittingSize 缩窗可抬 splitView 自身约束治理**：NSSplitViewController 作 contentViewController 后按 splitView fittingSize 缩窗（bypass setContentSize/minSize），给 splitView 加 `widthAnchor/heightAnchor ≥ visibleFrame` 抬高 fittingSize → 缩窗目标 = visibleFrame → 窗口充满屏幕（既有 `heightAnchor ≥ 常量` 已证明此机制有效，widthAnchor 同理）。
- **「只有 X 正常」是强信号**：对比正常与异常 view 的构建差异（skins 不用 ContentColumnView），快速锁定共用组件为根因。
- **已知 trade-off**：documentView.frame.height 固定 = scrollView 高时，contentColumn 超高内容截断不滚动。大窗口下设置内容基本不超高 + ProviderSettings 有内层 jsonScrollView 兜底，可接受。演进：layout() 里 `documentView.frame.height = max(contentColumn.fittingHeight, scrollView.bounds.height)` 恢复竖滚（注意 fittingSize 递归风险，需两阶段布局）。

## Related

- [[nsscrollview-documentview-autoresizing-width-zero]]（documentView width=0 单一，autorisizing 修 width；本 pattern 是其嵌套深化——height 也失效 + 整体 autolayout 不可用）
- [[nsscrollview-documentview-bottom-align-snapshot-blindspot]]（documentView 贴底，headless 复现不了须真机）
- [[nshostingcontroller-deep-child-sizingoptions-collapses-window]]（NSHostingController 深层 child sizingOptions 塌窗；⚠️ 该 pattern 的 SnipPanelVC 已从 NSHostingController 迁纯 AppKit NSViewController，sizingOptions 不再适用，但 NSHostingController 深层 child 教训仍有效）
- [[ci-fetch-plugins-dual-path-fallback-masks-workflow-gap]]（全绿≠消 bug，须真机端到端）
