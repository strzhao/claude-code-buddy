<!-- tags: appkit, nsapp-mainmenu, edit-menu, lsuielement, accessory, paste, cmd-v, field-editor, responder-chain, swiftui-textfield, keyequivalent, spm, no-nib, launcher -->
# LSUIElement + 纯代码 NSApplication：NSApp.mainMenu 为 nil 导致 ⌘V/⌘C/⌘X/⌘A 全部失效

**问题**：launcher 输入框（SwiftUI `TextField`）无法 ⌘V 粘贴（连带 ⌘C/⌘X/⌘A 也无效），但输入框获焦、能正常打字。

**根因**：本 app 是 `LSUIElement=true` + `setActivationPolicy(.accessory)` 的 **SPM 可执行文件（无 MainMenu.nib）**，且 `AppDelegate` 从未给 `NSApp.mainMenu` 赋值 → `NSApp.mainMenu == nil`。macOS 分发 key equivalent（⌘V）时，`NSApplication.sendEvent` 先调 `NSApp.mainMenu?.performKeyEquivalent(event)` 在主菜单里查找匹配 keyEquivalent 的菜单项，命中后才沿 responder chain 把该 item 的 action（`paste:`）发给 first responder（SwiftUI TextField 背后的 AppKit field editor）。mainMenu 为 nil → 没有任何 Paste 菜单项 → ⌘V 找不到归宿，静默失效。普通 .app 由 MainMenu.nib 自动提供标准 Edit 菜单，所以不会遇到。

**解法**：在 `AppDelegate` 构造一个最小标准 Edit 菜单赋给 `NSApp.mainMenu`，菜单项用 **AppKit 标准 first-responder selector**（`cut:`/`copy:`/`paste:`/`selectAll:`/`undo:`/`redo:`），关键是 `target = nil`（走 responder chain，由 field editor 自动响应+启停）。`.accessory` 下菜单栏不显示，但 keyEquivalent 路由照常工作（`performKeyEquivalent` 不要求菜单可见）。在 `applicationDidFinishLaunching` 调一次即可，全 app 所有文本输入受益。

**教训**：① LSUIElement + 纯代码 NSApplication（无 nib）必须手动建 Edit 菜单，否则 SwiftUI/AppKit 文本框的剪贴板快捷键全失效；标准 selector + target=nil 是正解，不要自定义 NSTextField 拦截 keyDown 或事件 monitor（脆弱）。② **GUI 行为验证前必须确认跑的是含改动的新构建产物（`nm` 查符号），且关闭可能占用全局热键的旧 bundle 实例** —— 本次第一次「仍不能粘贴」就是因为测了未重新编译的旧二进制。
