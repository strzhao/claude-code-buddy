# SwiftUI 在 AppKit 设置窗口（NSHostingController）的 3 个陷阱

> 2026-07-08 | snip GUI 面板（SnipPanelView，NSHostingController 嵌入 NSSplitView detailContainer）开发总结

适用场景：AppKit 设置窗口（SettingsWindowController）里嵌 SwiftUI 视图（NSHostingController）做 child VC。纯 SwiftUI App 或独立 NSPanel 不一定触发。

## 陷阱 1：Form labeled-content 把 content 挤到右侧 1/3 宽

**现象**：`Form { Section { TextField/VStack/TextEditor } }.formStyle(.grouped)` 在 macOS 上，Section 行默认 labeled-content 布局（leading label + trailing content）。TextField/TextEditor/VStack 被挤到右侧约 1/3 宽度，用户「只有点击右侧小区域才响应」/「content 看不见」。

**无效尝试**（都已验证无效，图大小不变）：
- `.frame(maxWidth: .infinity)` on TextField/VStack/TextEditor
- 去掉 `.formStyle(.grouped)`（图微变但仍挤）
- VStack 包 TextField（keyword 占满是因为 TextField 短勉强能用，content TextEditor 同样被挤只是用户没抱怨）

**根因**：macOS SwiftUI Form Section 行布局引擎对非 LabeledContent 内容仍分两列（label 空 + content 窄），`.frame` 改不了 trailing 区宽度。

**方案**：不用 Form，改纯 VStack + 卡片背景（对齐 AppKit SettingsGroupView）：
```swift
VStack(alignment: .leading, spacing: 0) {
    HStack { Text("label").font(.caption); Spacer(); Text(value) }.padding(12)
    Divider()
    VStack(alignment: .leading, spacing: 4) {
        Text("content").font(.caption)
        TextEditor(text: $editContent).frame(maxWidth: .infinity, minHeight: 120)
    }.padding(12)
}
.background(Color(nsColor: SettingsTheme.cardBackgroundColor))
.cornerRadius(SettingsTheme.cardCornerRadius)
```

**验证**：SnapshotTesting `record: .all` + analyze_image 确认 content 占满（图大小变化 + 视觉）。

## 陷阱 2：@Binding 不触发 body 重算（点按钮无反应）

**现象**：`@Binding var editingItem: T?` 桥接外部 ObservableObject 的 @Published，但 view 未 `@ObservedObject` 订阅该 source → editingItem 变化不触发 body 重算 → detailPane 不切换 → 用户「点新增片段无反应」。

**日志铁证**：状态变化点加 `BuddyLogger.info` → 真机操作 → `buddy log grep` 显示 startCreate 触发了（editingItem 变）但 detailPane 的 .onAppear 日志没换分支。

**根因**：@Binding 是读写桥，不自动观察 source。source 变化要触发渲染，view 必须 @ObservedObject/@StateObject 订阅，或用 @State（SwiftUI 原生管理触发）。

**方案**：纯 UI 状态用 @State（非 @Binding 桥接外部 ObservableObject）：
```swift
@State private var editingItem: SnippetItem?  // 非 @Binding
@State private var isCreating: Bool = false
```
NSHostingController 构造时不用再传 Binding 桥（删 SnipPanelState 引用桥 class）。

## 陷阱 3：SwiftUI Button 进程内 performClick 盲区

**现象**：进程内 XCTest 想触发 SwiftUI Button（如「新增片段」/「编辑」），用 `findButton(titled:) + performClick` —— **找不到**（SwiftUI Button 不是 NSButton，不在 NSView 子树，无法递归定位）。

**方案**：init 注入初始 @State 绕开点击，直接渲染目标态：
```swift
init(initialEditingItem: SnippetItem? = nil, initialIsCreating: Bool = false, ...) {
    self._editingItem = State(initialValue: initialEditingItem)
    self._isCreating = State(initialValue: initialIsCreating)
}
// 测试：SnipPanelView(initialEditingItem: item, initialIsCreating: true) → 直接渲染 createForm
```
配合 `assertSnapshot(..., record: .all)` 强制渲染 + analyze_image 验证（进程内读 view 树对 SwiftUI 有盲区，像素 snapshot 是 ground truth）。

## 通用诊断方法（SwiftUI 交互问题）

点击/选中无反应时用日志定位根因（不靠猜）：
1. 加 `BuddyLogger.info` 到状态变化点（`.onChange(of:)` / `.onAppear` / action 闭包 / @State setter 后）
2. 真机操作 + `buddy log grep "<subsystem>"` 确认执行路径
3. 判断：**状态变了→切换/渲染问题**（body 不重算 → 陷阱 2，或渲染了但布局挤 → 陷阱 1）；**状态没变→事件不触发**（Button 盲区 → 陷阱 3，或 selection 绑定问题）

**注**：诊断日志用完清理（生产代码不留 debug 日志，commit 前删 BuddyLogger 调用）。

## 关联

- [[2026-06-27-modal-runloop-task-not-pump-installsync-bypass]]：SwiftUI @ObservedObject 在 modal 不刷新（数据流陷阱另一面）
- [[2026-06-23-lsuielement-standard-nswindow-key-window-sendevent-fallback]]：AppKit 设置窗口交互兜底

---
<!-- tags: swiftui, nshostingcontroller, appkit, form, labeled-content, binding, state, button, performClick, snapshot-testing, record-all, settings-panel, in-process-test, blind-spot, buddy-logger, diagnostics, nssplitview, containment -->
