# 外部 sprite sheet → 皮肤包的处理流水线

<!-- tags: skin, sprite-sheet, pillow, upload, manifest, skin-pack -->
**Scenario**: 从外部像素艺术素材（横向 sprite sheet）制作皮肤包并上传到皮肤商店
**Lesson**: 处理流水线为：(1) 按帧宽切割 sprite sheet 为单帧 (2) 对每帧 auto-trim 透明边距（`Image.getbbox()` + `crop()`）(3) 等比缩放适配目标画布（高度优先，`Image.NEAREST` 保持像素锐利）(4) 粘贴到目标画布上底部居中对齐（角色脚在底边，匹配 app 的 groundY 定位）。Manifest 校验要求：`food_names` 和 `bed_names` 必须是非空数组（空数组会被 CLI 和服务端拒绝）；CLI 本地检查 key sprite `<prefix>-idle-a-1.png` 存在；`canvas_size` 必须与实际 PNG 尺寸匹配。9 个必需动画名：idle-a/idle-b/clean/sleep/scared/paw/walk-a/walk-b/jump。Menubar 精灵需单独缩放到 ~50×34。
**Evidence**: pixel-knight 皮肤包制作——96×84 Knight sprite sheet → 48×48 画布，Python Pillow 处理 55 帧 + 12 menubar 帧，CLI 上传成功
