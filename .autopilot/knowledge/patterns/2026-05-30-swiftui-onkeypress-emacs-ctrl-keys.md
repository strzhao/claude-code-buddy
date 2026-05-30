<!-- tags: swiftui, onkeypress, keypress, emacs, ctrl-n, ctrl-p, keyboard-navigation, modifiers, keyequivalent, textfield, passthrough, launcher, candidate-list -->

# SwiftUI 加 emacs 键位（Ctrl-N/Ctrl-P）：onKeyPress(phases:.down) catch-all 读 modifiers，非目标键 .ignored 透传

## 场景
launcher 输入框（TextField）上要支持 Ctrl-N 下移 / Ctrl-P 上移候选，且不能影响普通打字。

## 坑
`.onKeyPress(_ key: KeyEquivalent, action:)` 这个重载的 action 是 `() -> KeyPress.Result`，**拿不到 modifiers**，无法区分 `n` 和 `Ctrl-N`。用它会把普通 `n` 也拦截。

## 解法
用 catch-all 的 `.onKeyPress(phases: .down) { press in ... }`，它给到完整 `KeyPress`（含 `.modifiers` 和 `.key`）。先判 control，再按 `press.key` 分发；其余一律 `.ignored` 让普通输入透传到 TextField：

```swift
.onKeyPress(.upArrow) { navigateUp() }      // 方向键用简单重载即可（无 modifier 无歧义）
.onKeyPress(.downArrow) { navigateDown() }
.onKeyPress(phases: .down) { press in
    guard press.modifiers.contains(.control) else { return .ignored }  // 普通输入透传
    switch press.key {
    case KeyEquivalent("n"): return navigateDown()
    case KeyEquivalent("p"): return navigateUp()
    default: return .ignored
    }
}
```

## 要点
- `press.key` 是物理键的 KeyEquivalent（"n"），与 modifier 无关 → 不要用 `press.characters`（Ctrl 按下时可能是控制字符 `\u{0E}` 而非 "n"）。
- catch-all 返回 `.ignored` 才会把事件继续传给焦点内的 TextField；只对命中的 Ctrl-N/P 返回 `.handled`。
- 多个 `.onKeyPress` 可共存：箭头键无 control → catch-all 先 `.ignored` → 落到 `.upArrow`/`.downArrow` 专用 handler。
- 导航逻辑抽成 `navigateUp()/navigateDown()` helper，箭头与 emacs 键复用，避免重复。
