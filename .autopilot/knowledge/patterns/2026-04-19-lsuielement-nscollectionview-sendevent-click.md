# LSUIElement app 中 NSCollectionView 选择机制不工作

<!-- tags: appkit, lsuielement, nscollectionview, key-window, nswindow, click -->
**Scenario**: 皮肤市场 Settings 面板用 NSCollectionView + isSelectable=true 实现皮肤选择，单击无反应，双击才响应
**Lesson**: LSUIElement=true 的 menubar agent app 无法可靠激活（NSApp.isActive 始终 false），因此其窗口无法成为 key window。NSCollectionView 的 didSelectItemsAt 依赖 key window，在 LSUIElement app 中完全失效。尝试过的无效方案：NSClickGestureRecognizer（不可靠）、mouseUp override（第一次点击被窗口激活消耗）、acceptsFirstMouse（无效）、makeKey()（app 未激活时无效）、NSApp.activate()（LSUIElement 下不生效）。正确方案：在 NSPanel 子类的 sendEvent(_:) 中拦截 mouseUp，通过 collectionView.indexPathForItem(at:) 坐标计算找到目标 item，直接调用回调。sendEvent 是最底层且 100% 可靠的事件入口，不依赖 key window 状态。
**Evidence**: 诊断日志显示 appActive=false + isKeyWindow=false 贯穿所有点击事件。修改为 sendEvent 拦截后单击 100% 响应。
