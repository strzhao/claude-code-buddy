# 皮肤颜色变体采用 manifest variants 数组而非独立皮肤包

<!-- tags: skin, variant, manifest, architecture -->

**决策**: 在 SkinPackManifest 中新增可选 `variants: [SkinVariant]?` 数组，每个变体有独立的 `sprite_prefix`，共享其他 manifest 字段（animation_names、canvas_size、food 等）。

**否决**: 每种颜色作为独立皮肤包上传（如 pixel-dog-red、pixel-dog-blue）。

**理由**:
- 12 种颜色 × 独立皮肤包 = 皮肤市场极度膨胀，用户体验差
- 变体间只有 spritePrefix 不同，其他配置完全相同，冗余度极高
- manifest 级变体让用户在选择皮肤后自然选择颜色，交互更直观
- 默认"随机"变体增加趣味性（每次启动随机选色）

**影响文件**: SkinPackManifest.swift, SkinPack.swift, SkinPackManager.swift, SkinCardItem.swift, SkinGalleryViewController.swift, web types.ts/validation.ts

**约束**: 变体只能覆盖 spritePrefix、previewImage、bedNames。animation_names 等结构性字段必须全变体共享。
