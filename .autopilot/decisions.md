# 架构决策

## 2026-04-13: 猫咪朝向系统集中化

**决策**: 将散落在 MovementComponent/InteractionComponent 中的 5 处方向设置逻辑统一为 `CatSprite.face(towardX:)` / `face(right:)` API，并用 `didSet` 自动同步视觉。

**理由**: 原来每个调用点独立维护 if/else 阈值判断 + `facingRight` 赋值 + `applyFacingDirection()` 调用，导致 3 个 bug（静止转向、tabName 镜像、逻辑不一致）。

**影响文件**: CatSprite.swift, MovementComponent.swift, InteractionComponent.swift

**约束**: 新增移动行为时，必须通过 `face(towardX:)` 或 `face(right:)` 设置方向，禁止直接赋值 `facingRight`。
