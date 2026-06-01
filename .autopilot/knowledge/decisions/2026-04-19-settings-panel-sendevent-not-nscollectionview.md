# Settings 面板点击事件通过 Panel.sendEvent 而非 NSCollectionView 选择

<!-- tags: appkit, lsuielement, panel, click, settings -->

**决策**: 在 SettingsPanel（NSPanel 子类）的 sendEvent(_:) 中拦截 mouseUp 事件，通过 collectionView.indexPathForItem(at:) 坐标计算找到目标 item，直接调用 gallery 的处理方法。NSCollectionView.isSelectable 设为 false。

**否决**:
- Strategy A: NSCollectionView.isSelectable=true + didSelectItemsAt delegate
- Strategy B: NSClickGestureRecognizer
- Strategy C: 自定义 NSView.mouseUp override

**理由**:
- 本 app 是 LSUIElement menubar agent（无 Dock 图标），NSApp.isActive 始终 false
- NSCollectionView 选择和手势识别器都依赖 key window，在未激活 app 中不可靠
- sendEvent 是 NSWindow 事件分发的最底层入口，不依赖 window/app 激活状态

**影响文件**: SettingsWindowController.swift, SkinGalleryViewController.swift

**约束**: 任何需要在 Settings 面板中处理点击的新控件，都应通过 SettingsPanel.sendEvent → Gallery.handleClickAt 链路，不要依赖 NSCollectionView 的选择机制。
