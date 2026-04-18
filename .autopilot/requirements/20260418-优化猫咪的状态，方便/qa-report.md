### Wave 1 — 静态验证
- ✅ `make build`: 编译成功
- ✅ `make lint`: 0 violations, 0 serious in 58 files
- ✅ `make test`: 342 tests, 0 failures (8 新增 + 334 原有)

### Wave 1.5 — 代码质量审查
- ✅ 新增代码与现有模式对称（addPersistentBadge ↔ addAlertOverlay）
- ✅ 常量引用统一，无硬编码魔法数字
- ✅ applyFacingDirection counter-scale 符合既有模式

### Wave 2 — 验收场景（CLI 驱动）
- ✅ T1-T5 全部事件流无错误
- ⚠️ 视觉效果需人工确认（无截屏能力）
