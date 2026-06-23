### [2026-06-23] LSUIElement app 标准 NSWindow 也非 key window：NSTableView/NSCollectionView 选择都需 sendEvent 兜底 + NSApp.activate() 新 API
<!-- tags: lsuielement, nswindow, key-window, sendevent, nstableview, nscollectionview, nsapp-activate, macos-14, sidebar, accessory, settings, automation-limit -->

**Scenario**: LSUIElement accessory app 用**标准 NSWindow**（非 NSPanel）承载设置界面，界面含 NSTableView（sidebar 列表）或 NSCollectionView（网格），用户点击切换/选择失效（点击无反应或选中不切换）。

**Lesson**:
- 标准 NSWindow 在 LSUIElement 下**也**不可靠成为 key window（不只 NSPanel，见 [[2026-04-19-settings-panel-sendevent-not-nscollectionview]]）→ NSTableView/NSCollectionView 的系统选择机制（didSelectItemsAt / selection）失效。
- `NSApp.activate(ignoringOtherApps: true)` 在 macOS 14+ **废弃且对 accessory policy 可能 no-op**；改用 `NSApp.activate()`（无参新 API），且顺序须 **activate 先、makeKeyAndOrderFront 后**（激活 app 再让窗口 key）。
- 解法：子类化 NSWindow 覆盖 `sendEvent`，拦截 `leftMouseDown` 双兜底——① NSTableView：`hitTest` 上溯到 tableView → `row(at:)` → `selectRowIndexes`（触发 tableViewSelectionDidChange）；② NSCollectionView（isSelectable=false 时系统完全不选中）：走 responder chain 找点击命中的手动处理入口（自定义 `handleClickAt` 坐标命中）。
- 测试限制：LSUIElement app 在自动化测试环境（另一前台进程抢 frontmost）下无法稳定 active/key，CGEvent `click at` / AXPress 对非 key 窗口**不路由**（sendEvent 收不到事件）；真实用户交互（点 app 入口打开窗口）才 active → 此类点击验证须**用户手动**，不能仅靠自动化（红队单测测 selection delegate wire 可，但 key window 路由要真机）。

**Evidence**: 本次设置窗口 sidebar 重构——`SettingsWindow.sendEvent` 的 `forwardSidebarClick`（NSTableView selectRowIndexes）+ `forwardDetailClick`（responder chain → SettingsTabClickReceiver.handleClickAt）；osascript `set frontmost` / AX 设 `AXFocused` 均无效，AXFocused 始终 false，sendEvent 调试 log 空（CGEvent 不路由到非 key 窗口）；用户手动点齿轮打开设置后 sidebar/网格/按钮全可点（功能 PASS）；`AppDelegate.showSettings` 改 `NSApp.activate()` 新 API + activate 先 makeKey 后。关联 [[2026-04-19-settings-panel-sendevent-not-nscollectionview]]（NSPanel 场景根教训）、[[2026-04-19-lsuielement-nscollectionview-sendevent-click]]。
