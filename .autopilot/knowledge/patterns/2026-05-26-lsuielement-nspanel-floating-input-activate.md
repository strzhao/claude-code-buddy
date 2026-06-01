# LSUIElement app 中的浮窗输入框用 NSPanel + nonactivatingPanel + NSApp.activate

<!-- tags: nspanel, lsuielement, launcher, alfred, key-window, floating-window, swiftui, appkit, nshostingcontroller -->
**Scenario**: 在 buddy（LSUIElement=true 的 menu bar app）中实现 Alfred 式启动器浮窗，需要：① 浮在最前不抢主窗口主性 ② 可获键盘焦点接收输入 ③ 失焦自动隐藏 ④ 全 Space 可见。已有的 BuddyWindow（NSWindow + borderless + ignoresMouseEvents=true）用于点击穿透，不能复用做输入框。
**Lesson**: 标准做法是 NSPanel 子类 + `styleMask=[.titled, .fullSizeContentView, .nonactivatingPanel]` + `level=.floating` + `collectionBehavior=[.canJoinAllSpaces, .stationary, .transient]` + `hidesOnDeactivate=true` + override `canBecomeKey=true` / `canBecomeMain=false`。show 时必须调 `NSApp.activate(ignoringOtherApps: true)` 才能让 NSPanel 真正获键盘焦点（LSUIElement app 默认不接收键盘事件）。SwiftUI 视图通过 NSHostingController(rootView:) 包成 NSViewController 赋 panel.contentViewController。
**Evidence**: task 001 落地 LauncherWindow.swift + LauncherManager.swift，49 个 acceptance/snapshot 测试全绿；`make build && open ClaudeCodeBuddy.app && buddy ping` 验证启动器与像素猫共存正常。AppDelegate 现有 SettingsWindowController.swift 已用相同 NSApp.activate 模式，可作先例参考。
