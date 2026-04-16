---
id: "004-refactor-scene"
depends_on: ["002-skin-manager"]
---

# 004: 重构 BuddyScene（边界+床）

## 目标
BuddyScene 的边界装饰和床精灵加载改为通过 SkinPack 驱动。

## 要修改的文件
- `Sources/ClaudeCodeBuddy/Scene/BuddyScene.swift`
- `Sources/ClaudeCodeBuddy/Entity/Cat/States/CatTaskCompleteState.swift`
- `Sources/ClaudeCodeBuddy/Entity/Cat/CatConstants.swift`

## 变更详情

### BuddyScene.swift
- `loadBoundaryTexture()`: 硬编码 `"boundary-bush"` → `SkinPackManager.shared.activeSkin.manifest.boundarySprite`
- 资源解析: `ResourceBundle.bundle.url(...)` → `SkinPackManager.shared.activeSkin.url(...)`
- `bedColorName(for:)` 或类似方法: `CatConstants.TaskComplete.bedNames` → `SkinPackManager.shared.activeSkin.manifest.bedNames`

### CatTaskCompleteState.swift
- `loadBedTexture(named:)`: `ResourceBundle.bundle.url(...)` → `SkinPackManager.shared.activeSkin.url(..., subdirectory: manifest.spriteDirectory)`
- 新增 `reloadBedTexture(from skin: SkinPack)` 方法（供热替换使用）

### CatConstants.swift
- 移除 `TaskComplete.bedNames`（迁移到 manifest）
- 保留 `TaskComplete.maxSlots`、`bedRenderSize`（布局常量，非皮肤配置）

## 验收标准
- [ ] `make build` 编译通过
- [ ] `make test` 全部通过
- [ ] 边界装饰和床正常渲染
- [ ] BuddyScene 和 CatTaskCompleteState 不再有 `ResourceBundle.bundle` 直接引用
- [ ] CatConstants 不再有 bedNames
