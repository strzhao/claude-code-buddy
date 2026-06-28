### [2026-06-29] AppKit NSPopUpButton programmatic selectItem 触发 target-action 副作用污染 UI 状态：`isPopulating` 标志位防污染

<!-- tags: appkit, nspopupbutton, selectitem, target-action, side-effect, populateui, ispopulating, guard, settings, uikit -->

**Background**: `ProviderSettingsViewController.populateUI()` 调用 `kindPopup.selectItem(at:)` 填充初始状态时，触发了 `kindDidChange(_:)` target-action。该方法会清空 `modelField`/`baseURLField` 并调用 `saveCurrentProvider()`，导致配置被空字段覆盖（丢失 noThinking 等字段）。

**Lesson**: 任何 `populateUI()` / `reloadData()` / `refresh()` 方法中使用 `NSPopUpButton.selectItem(at:)` 时，程序化选择会同步触发 target-action。解决方案：

```swift
private var isPopulating = false

func populateUI() {
    isPopulating = true
    defer { isPopulating = false }
    // ... selectItem(at:) 等操作
}

@objc private func kindDidChange(_ sender: NSPopUpButton) {
    guard !isPopulating else { return }
    // ... 副作用逻辑
}
```

**How to apply**: 任何 NSPopUpButton（以及类似 NSControl 子类如 NSMatrix）在程序化设置 selected 状态前，如果 target-action 有副作用（保存、网络请求、状态变更），使用 `isPopulating` 标志位跳过。最干净的写法：`isPopulating = true; defer { isPopulating = false }`。
