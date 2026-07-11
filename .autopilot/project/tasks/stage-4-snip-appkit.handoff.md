# stage-4 Handoff（最后阶段，项目结束）

## 实现摘要
snip 迁 AppKit（plan Task 10-13）：SnipPanelVC 重写 NSViewController master-detail + 删 SnipPanelView.swift + sizingOptions hack + 四态统一（create/edit/preview/空）+ objectWillChange.sink 刷新 + testHook performClick + 测试迁移 + 快照重录。

## 文件变更（4 commits + merge）
- `1d74fe8` master-detail 骨架（import Combine + AnyCancellable）
- `c18e935` 四态 + content editor NSScrollView 包 + width 三件套（B1+B2）
- `efd162a` 数据流 + 删 SnipPanelView.swift + sizingOptions hack（grep==0）
- `e56f8b3` 测试适配（AC-13 NSTextField 强断言）+ 重录 + 真机（buddy health ok）
- merge commit（红队 SnipAppKitAcceptanceTests）

## 🎉 项目结束（5 阶段闭环）
stage-4 是 5 阶段最后。整个布局重构闭环：
- **stage-0** 栅格 token（4 倍数 scale + 布局常量）
- **stage-1** ContentColumnView（限宽居中 + 防贴底 patterns/2026-07-03）
- **stage-2** 设置主体（frame 谓词首次验证 + blocker 2 AX 唯一性修订 4 处）
- **stage-3** 插件面板（左栏固定 240 + plain NSSplitView headless 盲区修正）
- **stage-4** snip 迁 AppKit（sizingOptions hack 消除 + 删 SwiftUI + 四态统一）
- **29 验收谓词**（28 det-machine）全 in-process XCTest + 真机覆盖
- 布局"简陋"根因（贴边拉满/硬编码/拖动跳/技术栈混杂）**全部解决**

## 知识沉淀
AppKit 布局 headless 几何验证 pattern（frame 谓词 in-process 真实 NSWindow + plain NSSplitView setPosition + 快照 host NSWindow），补充 patterns/2026-07-03。

## 偏差说明
plan-reviewer 2 轮修 4 blocker（import Combine / content editor NSScrollView+三件套删 scrollerWrapper / SnipWindowSizingTests 删 sizingOptions 断言+AC-WIN-02 替代 / AnyCancellable）。蓝队顺带修红队 `vc is NSHostingController` Swift type checker bug（改类型名检查，语义不变）。无功能偏差。