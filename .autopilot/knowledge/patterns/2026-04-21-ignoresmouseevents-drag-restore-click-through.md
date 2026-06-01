# ignoresMouseEvents 在拖拽后未恢复导致窗口拦截点击

<!-- tags: appkit, window, mouse-events, drag, click-through -->
**Scenario**: BuddyWindow 默认 ignoresMouseEvents=true（点击穿透），hover 时切为 false。拖拽结束后 MouseTracker 的 isDragging 置 false 但没有恢复 ignoresMouseEvents=true，导致整个窗口持续拦截鼠标事件，用户无法点击窗口后面的应用。
**Lesson**: 任何修改 ignoresMouseEvents 的代码路径，必须有配对的恢复逻辑。拖拽结束（mouseUp）时应立即恢复 ignoresMouseEvents=true 并清除 hover 状态。落体+弹跳动画完全由 SKAction 驱动，不需要鼠标事件。通用规则：临时打开 mouse event 接收后，确认每个退出路径（正常结束、app 失焦、取消）都会恢复 click-through。
