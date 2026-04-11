---
id: "003-visual-layer"
depends_on: ["002-session-manager"]
---

## 目标

为 CatSprite 添加文字标签和颜色着色，使每只猫在视觉上可区分。

## 架构上下文

CatSprite 当前只有 SKSpriteNode 和动画逻辑，没有标签或颜色区分。BuddyScene.addCat 已被 002 改为接受 SessionInfo。

## 关键实现细节

### CatSprite 变更

**新属性：**
```swift
static let hitboxSize = CGSize(width: 48, height: 64) // 包含标签区域
private var labelNode: SKLabelNode?
private(set) var sessionColor: SessionColor?
private var sessionTintFactor: CGFloat = 0.3
```

**标签 SKLabelNode：**
- 作为 `node` 的子节点
- 位置：node 上方约 28px（`CGPoint(x: 0, y: 28)`）
- 字体：systemFont, 11px, bold
- 颜色：sessionColor.nsColor
- 阴影：`SKLabelNode` 不直接支持 shadow，用第二个 `SKLabelNode` 作为阴影层（offset 1px, alpha 0.4, blur 通过 `addGlowEffect` 实现）

**颜色着色：**
- 所有动画分支中的 `node.colorBlendFactor = 0` 替换为 `node.colorBlendFactor = sessionTintFactor`
- `node.color` 设置为 `sessionColor?.nsColor ?? .white`
- 影响的方法：`switchState(to:)`, `playIdleAnimation`, `runIdleSubState` 的所有分支, `enterScene`, `exitScene`

**新公开方法：**
```swift
func configure(color: SessionColor, label: String) // 初始化时调用
func updateLabel(_ label: String) // set_label 时调用
```

### BuddyScene 变更

**addCat(info:) 实现更新：**
```swift
func addCat(info: SessionInfo) {
    guard cats[info.sessionId] == nil else { return }
    if cats.count >= maxCats { evictIdleCat() }
    let cat = CatSprite(sessionId: info.sessionId)
    cat.configure(color: info.color, label: info.label)
    // ... 其余逻辑同现有
}
```

**新方法：**
```swift
func updateCatLabel(sessionId: String, label: String)
func updateCatColor(sessionId: String, color: SessionColor)
```

## 输入/输出契约

**输入来自 002：** SessionInfo（包含 color 和 label）通过 addCat(info:) 传入

**输出给 005：** CatSprite.hitboxSize 常量供 MouseTracker 使用，cat.node.position 供碰撞检测

## 验收标准

- [ ] `swift build` 编译通过
- [ ] 每只猫上方显示正确的标签文字
- [ ] 标签颜色与猫的 SessionColor 一致
- [ ] 猫精灵在所有动画状态下保持颜色着色（idle→thinking→coding→idle）
- [ ] updateLabel 能实时更新标签文字
- [ ] 无纹理模式下（placeholder）颜色直接设置为 sessionColor
