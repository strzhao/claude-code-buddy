# 精灵图 alpha 帧检测被粒子/特效残留误导

<!-- tags: skin, sprite, slicing, alpha, frame-detection -->
**Scenario**: 用 alpha 扫描（任意像素 alpha>10 即为有内容）自动检测精灵图每行帧数时，死亡/消散动画行的粒子残留被误判为有效帧
**Lesson**: 纯 alpha 检测适合角色动画行，但对含 VFX（粒子、爆炸、光效）的行会过度计数。切片精灵图时，对已知有特效的行应设置 `max_frames` 上限，并在切片后目视验证末尾帧。另一方案是改用最小像素数阈值（如非透明像素 >50 才算有效帧），但手动 max_frames 更精准。
**Evidence**: Satyr 精灵图 row 6（死亡动画）alpha 扫描检测到 10 帧，但帧 5+ 只有零星粒子点（jump-9.png/jump-10.png 几乎全透明）。添加 `"max_frames": 4` 后修复。
