# Handoff: 001-skin-types → 002-skin-manager

## 完成的接口

### SkinPackManifest (Sources/ClaudeCodeBuddy/Skin/SkinPackManifest.swift)
- `struct SkinPackManifest: Codable, Equatable` — 14 字段，显式 CodingKeys snake_case 映射
- 注意: `MenuBarConfig` 是**顶层类型**（非嵌套），因 SwiftLint nesting 规则提升

### SkinPack (Sources/ClaudeCodeBuddy/Skin/SkinPack.swift)
- `struct SkinPack: Equatable` — manifest + SkinSource(builtIn/local)
- `url(forResource:withExtension:subdirectory:)` — builtIn 补 "Assets/" 前缀，local 走 FileManager
- Equatable 基于 `manifest.id`

## 002 需要做的
- 创建 `DefaultSkinManifest` 静态属性，用精确的当前硬编码值构造 SkinPackManifest
- 创建 `SkinPackManager` singleton，用 `SkinPack(manifest: DefaultSkinManifest.manifest, source: .builtIn(ResourceBundle.bundle))` 作为内置皮肤
- `foodNames` 需要从 `FoodSprite.allFoodNames` 精确复制 102 个值

## 版本
v0.7.0 (feat 升级)
