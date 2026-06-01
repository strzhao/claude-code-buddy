# SpriteKit 标签阴影常量命名与用法不一致导致阴影错位

<!-- tags: spritekit, labels, shadow, constants, position -->
**Scenario**: `labelShadowOffset` 命名暗示相对偏移量，但代码中作为 `shadow.position` 的绝对坐标使用。值 `(1.5, 1.5)` 将阴影放到了精灵脚部而非主标签附近，在 permissionRequest 状态同时显示时导致文字重复。
**Lesson**: 当 SpriteKit 常量名含 "offset" 时，确认是相对偏移还是绝对位置。Tab name shadow 使用独立的 `tabLabelShadowYOffset` 绝对坐标是正确模式。阴影节点应与主节点的 Y 坐标保持 1px 差距（如 main Y=28, shadow Y=27）。检查方法：grep 所有 `.position = .*Offset` 确认语义一致。
**Evidence**: `labelShadowOffset = (1.5, 1.5)` → shadow 在 Y=1.5，main label 在 Y=28，肉眼可见两行重复文字。改为 `(1.5, 27)` 后视觉正确。
