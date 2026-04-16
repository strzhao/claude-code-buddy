# Handoff: 002-skin-manager → 003/004/005/006

## 完成的接口

### DefaultSkinManifest (Sources/ClaudeCodeBuddy/Skin/DefaultSkinManifest.swift)
- `enum DefaultSkinManifest` — caseless enum (namespace)
- `static let manifest: SkinPackManifest` — 内置皮肤完整配置
- 包含精确的 102 食物名、9 动画名、4 床名、menuBar 配置

### SkinPackManager (Sources/ClaudeCodeBuddy/Skin/SkinPackManager.swift)
- `static let shared` — singleton
- `activeSkin: SkinPack` — 当前皮肤（默认 .builtIn(ResourceBundle.bundle)）
- `availableSkins: [SkinPack]` — 所有可用皮肤
- `skinChanged: PassthroughSubject<SkinPack, Never>` — Combine 通知
- `selectSkin(_ skinId: String)` — 切换 + UserDefaults 持久化 + send
- `loadLocalSkins()` — 扫描 ~/Library/Application Support/ClaudeCodeBuddy/Skins/

## 003-006 如何消费
各重构任务需要将硬编码的资源引用替换为:
- `SkinPackManager.shared.activeSkin` 获取当前皮肤
- `SkinPackManager.shared.activeSkin.manifest.xxx` 获取配置值（如 animationNames, bedNames 等）
- `SkinPackManager.shared.activeSkin.url(forResource:withExtension:subdirectory:)` 加载纹理

## 版本
v0.8.0
