# SwiftUI ScrollViewReader：onChange(of: let) 不触发 + .center 切半 cell + scroll headless 盲区

[2026-07-15] launcher 候选列表视口与滚动修复（autopilot 20260715-开始实现）三连坑，均 headless 测不出、真机/运行时证据才暴露：

## 坑 1：`onChange(of: let selectedIndex)` 在 NSHostingView 下完全不触发

- 现象：子视图 `let selectedIndex: Int`（父视图因 @Published/@State 变化重算传新值），`.onChange(of: selectedIndex)` fireCount **恒为 0**，scrollTo 永不调用。中间尝试 `.task(id: selectedIndex)` 也只 fire 1 次且 selectedIndex 0→8 后不重启（lastNew 仍 0）。
- 根因：SwiftUI onChange/.task(id:) 要求值变化在 **view 实例生命周期内**被观察；普通 `let` 属性是父 view 重算时的新值拷贝，不满足。**「onChange 只要求 Equatable，let 也能监听」是错误直觉**——Equatable 是必要非充分，还需值在视图生命周期内可观察。
- 正解：`@Binding var selectedIndex: Int`（或父层 onChange 直接监听 @Published 源）。@Binding 让值变化在 view 生命周期内可观察，onChange 可靠触发。
- 验证：dry-run 写最小 case（commandRoute 12 候选 ↓ 到第 9 + BuddyLogger 打点）拿 fireCount 运行时证据，**不凭「理论上 onChange 能监听 let」推断**。项目先例 `.onChange(of: manager.isVisible)`（LauncherInputView:276）监听的是 @ObservedObject 的 @Published 属性（非本视图 @State），与 let 不同。
- plan-reviewer 曾标 BLOCKER 怀疑此点 → 设计预案列了 @Binding fallback → 蓝队 dry-run 证伪 let 假设后落 fallback。**verify-before-assume 救了这次**（[[root-cause-before-fixes]]）。

## 坑 2：ScrollViewReader `.center` anchor 小数偏移切半 cell

- 现象：>8 候选用 `proxy.scrollTo(new, anchor: .center)`，移到第 5 个时列表上移 **1.5 行**（小数偏移），第 1 个 cell 展示半个；继续往后移又恢复整行。
- 根因：`.center` 把选中行滚到视口**中部**，偶数行视口（8 行）中心在 3.5 行处 → offset = (selected - 3.5) * rowH = 1.5*rowH 小数 → 顶部 cell 被切半个。
- 正解：**条件式 minimal-scroll**（Alfred 式）—— `.top`/`.bottom` anchor 整行对齐（offset 恒为整数倍 rowH），仅选中越过可视边界才滚一格，可视内移动不滚（无抖动）。配合 `@State firstVisibleRow` 追踪可视窗口：
  ```swift
  .onChange(of: selectedIndex) { _, new in
      guard new >= 0 else { return }
      let T = LauncherConstants.candidateVisibleMax
      guard candidates.count > T else { return }   // ≤T 全展示不滚
      if new < firstVisibleRow {
          firstVisibleRow = new
          proxy.scrollTo(new, anchor: .top)
      } else if new >= firstVisibleRow + T {
          firstVisibleRow = max(0, new - T + 1)
          proxy.scrollTo(new, anchor: .bottom)
      }
      // else 可视内不滚
  }
  .onChange(of: candidates.count) { _, _ in firstVisibleRow = 0 }  // 新查询重置
  ```
- 每行须 `.id(index)`（scrollTo 的 id 锚）；selectedIndex<0（非活动区）guard 跳过。

## 坑 3：SwiftUI ScrollView 滚动 offset headless 盲区

- 现象：onChange 触发 scrollTo（fireCount 证实），但 `NSScrollView.documentVisibleRect.origin.y` 在 XCTest（NSHostingView + 无完整 window server）**保持 0**——滚动落地效果不可 headless 验证。更糟：headless 用 NSWindow+NSHostingView 承载 SwiftUI ScrollView 跑 9 个测试方法时 **SIGSEGV signal 11** 整类崩溃。
- 根因：SwiftUI ScrollView 的滚动行为依赖 window server / 显示链，headless XCTest 无完整 window server session（[[autopilot-tier-green-not-bug-free]] / patterns/2026-07-14 同款）。offset 读不到 + 承载崩溃。
- 正解：**滚动视觉行为路由真机 E2E**（`SKIP_FETCH_PLUGINS=1 make bundle` → 启动 → 真机 ↓ → 用户目视），**不写 headless 滚动 offset 断言测试**。headless 只覆盖：① panelHeight 纯函数（视口阈值逻辑）；② onChange 触发机制（fireCount，via test seam 如 LauncherScrollProbe ObservableObject 记调用）；③ 结构（NSHostingView 子树含 NSScrollView——但注意承载多视图可能 SIGSEGV，慎用）。
- AppKit 层介入（如需读 offset）：经 NSHostingView view 树 `findFirst<NSScrollView>` 沿 AppKit 树找底层 NSScrollView 读 `documentVisibleRect`（先例 ContentColumnViewTests / SettingsLayoutAcceptanceTests），但 offset 仍可能 headless 不变——真机为准。

## 共同元模式

- **headless 全绿 ≠ 真机正确**（[[autopilot-tier-green-not-bug-free]] / patterns/2026-07-14）：panelHeight 纯函数 + onChange fireCount headless 全绿，但 .center 切半 cell、scroll 不发生只有真机暴露。GUI 交互/滚动/动画类变更**必须真机 E2E 用户目视**，headless 只守机制与纯逻辑。
- **verify-before-assume**：onChange-on-let「理论可触发」被 dry-run 证伪；.center「能让选中可见」被真机发现切半 cell。涉及 SwiftUI 视图生命周期 / 滚动几何的假设，先拿运行时/真机证据再下结论。
- LSUIElement launcher GUI 自动化不路由（patterns/2026-06-23），scroll 视觉只能用户手动验，非 det-machine 谓词能覆盖。

## tags
swiftui, scrollviewreader, scrollto, onchange, let-vs-binding, nshostingview, center-anchor, half-cell, fractional-offset, minimal-scroll, firstvisiblerow, candidate-list, launcher, headless-blindspot, sigsegv, documentvisiblerect, real-app-verify, verify-before-assume, autopilot, gui-scroll, alfred-style
