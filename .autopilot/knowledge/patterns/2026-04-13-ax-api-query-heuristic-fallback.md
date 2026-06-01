# AX API 查询 + 启发式回退

<!-- tags: accessibility, dock, ax-api, fallback -->
**Scenario**: 需要获取 macOS Dock 图标区域的精确像素边界来限制猫咪活动范围
**Lesson**: `DockIconBoundsProvider` 先尝试 AX API（`AXUIElementCreateApplication` → `kAXChildrenAttribute` → 找 `AXList` → 读 position/size），失败时回退到启发式估算（屏幕中央 ~60%）。AX API 必须在主线程调用。Timer 轮询 3s 间隔 + NSWorkspace 通知检测 Dock 变化。
**Evidence**: DockIconBoundsProvider.swift, AppDelegate.swift 的 `setupDockMonitoring()` 方法
