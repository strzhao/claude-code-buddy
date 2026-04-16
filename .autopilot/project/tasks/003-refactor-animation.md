---
id: "003-refactor-animation"
depends_on: ["002-skin-manager"]
---

# 003: 重构 AnimationComponent + CatSprite

## 目标
将 AnimationComponent 的纹理加载从硬编码改为通过 SkinPack 驱动。

## 要修改的文件
- `Sources/ClaudeCodeBuddy/Entity/Components/AnimationComponent.swift`
- `Sources/ClaudeCodeBuddy/Entity/Cat/CatSprite.swift`

## 变更详情

### AnimationComponent.swift
- `loadTextures(prefix: String, bundle: Bundle)` → `loadTextures(from skin: SkinPack)`
- 动画名从硬编码 `["idle-a",...]` → `skin.manifest.animationNames`
- 精灵前缀从硬编码 `"cat"` → `skin.manifest.spritePrefix`
- 资源目录从硬编码 `"Assets/Sprites"` → `skin.manifest.spriteDirectory`（SkinPack.url() 内部处理 Assets/ 前缀）
- 帧发现循环逻辑不变（loop until file not found）

### CatSprite.swift
- `init(sessionId:)` 第 135 行: `animationComponent.loadTextures(prefix: "cat", bundle: ResourceBundle.bundle)` → `animationComponent.loadTextures(from: SkinPackManager.shared.activeSkin)`

## 验收标准
- [ ] `make build` 编译通过
- [ ] `make test` 全部通过（无回归）
- [ ] `buddy test --delay 2` 所有状态动画正常
- [ ] AnimationComponent 不再有任何 `ResourceBundle.bundle` 直接引用
- [ ] AnimationComponent 不再有硬编码动画名或前缀
