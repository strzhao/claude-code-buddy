<!-- tags: calayer, cgcolor, appkit, appearance, viewDidChangeEffectiveAppearance, nscollectionviewitem, nsview, dark-mode, light-mode, settings, snapshot -->

# CALayer CGColor 外观切换不刷新 + NSCollectionViewItem 适配

## Pattern

在 macOS AppKit 中使用动态 NSColor（如 `controlBackgroundColor`、`labelColor`）设置 CALayer 属性时，`.cgColor` 仅快照当前 effectiveAppearance 的固定值。系统 light/dark 切换后 CALayer 不会自动刷新。

**正确做法**：重写 `viewDidChangeEffectiveAppearance()` 刷新 layer 属性：

```swift
override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
}
```

**NSCollectionViewItem 适配**：`viewDidChangeEffectiveAppearance()` 是 NSView 方法，NSCollectionViewItem（NSViewController 子类）**无法直接 override**。解决方法是创建嵌套 NSView 子类，在 view 层拦截外观变化并通过 weak owner 转发：

```swift
class SkinCardItem: NSCollectionViewItem {
    private final class SkinCardItemView: NSView {
        weak var owner: SkinCardItem?
        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            owner?.updateSelectionAppearance()
        }
    }
    override func loadView() {
        let container = SkinCardItemView(frame: ...)
        container.owner = self
        self.view = container
    }
}
```

## Context

- 同项目 `SageSwitch`、`HotkeyRecorderView` 已正确实现此模式
- `SettingsGroupView` 缺少此 override 导致 light 模式下 cell 黑色背景、黑色文字不可读
- NSCollectionViewItem 层级需要额外适配（NSView 子类嵌套）

## Lesson

1. **CGColor 快照陷阱**：所有在 `setupView()`/`init` 中用动态 NSColor.cgColor 设置 CALayer 属性的地方，都必须配套 `viewDidChangeEffectiveAppearance` 刷新
2. **快照测试依赖外观一致性**：修复此类问题后快照基线需要全部重录（因 now correctly resolved colors）
3. **NSViewController vs NSView**：外观刷新只能在 NSView 层做；若 ViewController 的 view 创建时直接用了裸 NSView，需改为自定义子类

## How to Apply

- 新增 CALayer 颜色属性时，始终问："这个 color 来源是动态 NSColor 吗？" → 是 → 必须加 `viewDidChangeEffectiveAppearance` 刷新
- Review 现有代码中所有 `layer?.backgroundColor = xxx.cgColor` 是否有对应的 appearance 刷新
- NSCollectionViewItem / NSViewController 场景下，外观刷新逻辑放在 NSView 子类中
