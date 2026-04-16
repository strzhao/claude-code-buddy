---
id: "005-refactor-food"
depends_on: ["002-skin-manager"]
---

# 005: 重构 FoodSprite

## 目标
FoodSprite 的食物名列表和纹理加载改为通过 SkinPack 驱动。

## 要修改的文件
- `Sources/ClaudeCodeBuddy/Scene/FoodSprite.swift`

## 变更详情

### FoodSprite.swift
- `static let allFoodNames: [String]`（102 个硬编码名）→ `static var allFoodNames: [String] { SkinPackManager.shared.activeSkin.manifest.foodNames }`
- `init(textureName:)`: `ResourceBundle.bundle.url(forResource: textureName, withExtension: "png", subdirectory: "Assets/Food")` → `SkinPackManager.shared.activeSkin.url(forResource: textureName, withExtension: "png", subdirectory: manifest.foodDirectory)`
- fallback 名 `"81_pizza"` 保留（内置皮肤的 manifest 包含此名）

## 验收标准
- [ ] `make build` 编译通过
- [ ] `make test` 全部通过
- [ ] 食物正常生成和显示
- [ ] FoodSprite 不再有 `ResourceBundle.bundle` 直接引用
- [ ] FoodSprite 不再有硬编码食物名数组
