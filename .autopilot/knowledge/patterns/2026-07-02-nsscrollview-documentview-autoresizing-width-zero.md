<!-- tags: appkit, nsscrollview, documentview, nstextview, autoresizingmask, width-tracks-text-view, width-zero, layout, ax-dump, osascript, coordinate-verification, test-blind-spot, iseffectivelyvisible, settings, provider-settings, autopilot -->
# NSScrollView.documentView 是 NSTextView 时缺 autoresizingMask=.width → textView width=0 内容不可见

## 现象
设置页「AI 配置」JSON 面板（`ProviderSettingsViewController`）切到 JSON tab 后，编辑器区域经常一片空白，但 `jsonTextView.string` 确有值（log 显示 jsonLength=177）。"经常"而非"每次"——窗口尺寸变化或切分类再回来时偶尔能看到内容。

## 根因（AX dump 实测定位，非理论推算）
`jsonTextView` 作为 `jsonScrollView.documentView` 设置，但**没设 `autoresizingMask` 也没 `widthTracksTextView`**：
- NSScrollView 的 `documentView` **不参与 scrollView 的 Auto Layout 约束系统**，它用 autoresizing mask；`documentView = jsonTextView` 后 textView.frame 保持初始 `.zero`，scrollView resize 不传宽度给 documentView → `jsonTextView.bounds.width == 0`。
- AX dump（`osascript` `entire contents` + `position`/`size`）铁证：修复前 `AXTextArea size=0x198 valLen=177`（width=0，height 有值），string 有值但被 0 宽度裁剪 → 视觉空白。
- "经常看不到、偶尔能看到"：window resize 时 AppKit 偶发触发 autoresizing 给 documentView 宽度，此时内容冒出来；静态打开切 tab 时 width=0。

## Choice（修复）
`documentView = jsonTextView` 之后立即配三件套：
```swift
jsonScrollView.documentView = jsonTextView
jsonTextView.autoresizingMask = [.width]              // width 跟随 scrollView
jsonTextView.textContainer?.widthTracksTextView = true // container 宽跟 textView
jsonTextView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
```
`widthTracksTextView=true` 让 textContainer 宽度跟随 textView 宽度（内容正确换行）；`containerSize.height=greatestFiniteMagnitude` 让文本垂直无限延伸（scrollView 自动出竖滚条）。

## 陷阱
- **documentView 用 autoresizing，不是约束**：别给 `documentView` 加 `translatesAutoresizingMaskIntoConstraints=false` + 约束到 contentView，会与 scrollView 的 documentView 管理冲突。
- **`isEffectivelyVisible`（遍历 superview isHidden 链）查不出 width=0**：isHidden 链全 false 但 width=0 仍不可见。红队 P1 原断言 `isEffectivelyVisible` 在 width=0 时仍 PASS——漏报。必须补**机制断言**（`autoresizingMask.contains(.width)` + `widthTracksTextView == true`）或**效果断言**（`bounds.width > 0`，但需有窗口布局，测试环境无窗口时 width 仍 0，故测试用机制断言、真机用 AX 效果实测）。
- **测试环境无窗口 → bounds.width 恒 0**：XCTest `forceLoadView` 不上窗口，autoresizing 不触发，textView width=0 即使修复正确。断言"效果"会误报，断言"机制配置"才稳。

## 何时复用
任何 `NSScrollView.documentView = NSTextView`（或 `NSTextView` 作 documentView 的代码块/JSON 编辑器）。复用前先 AX dump 看 `size`——width=0 即此坑。相关：[[appkit-contentviewcontroller-root-view-frame-fitting-size]]（NSViewController root view 层面的 autoresize 坑，同主题不同层面）、[[coordinate-verification]]（UI 定位必须 AX 实测，禁纯理论推算——本次初版"时序/textContainer"诊断错，AX size=0x198 才定位真因）。
