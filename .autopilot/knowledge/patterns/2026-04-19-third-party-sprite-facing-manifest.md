# 第三方精灵图朝向需在 manifest 中声明

<!-- tags: skin, sprite, facing, manifest, third-party -->
**Scenario**: 上传像素狗皮肤包后，狗跑步方向反转——狗精灵面朝左，而 app 假设精灵面朝右
**Lesson**: SpriteKit 中通过 xScale 翻转实现角色转向，默认假设精灵面朝右 (xScale=1.0=面右)。第三方皮肤的精灵朝向不确定，需在 manifest 中声明 `sprite_faces_right: bool`。app 端 CatSprite.applyFacingDirection() 读取此字段，当 sprite 面朝左时反转 xScale 逻辑：`xScale = (facingRight == spriteFacesRight) ? 1.0 : -1.0`。CLI 上传工具通过 `--facing left|right` 参数自动写入 manifest。
**Evidence**: 用户验证像素狗走路方向反转。添加 sprite_faces_right=false 后方向正确。
