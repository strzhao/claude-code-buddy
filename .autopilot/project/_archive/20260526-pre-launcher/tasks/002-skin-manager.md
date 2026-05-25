---
id: "002-skin-manager"
depends_on: ["001-skin-types"]
---

# 002: DefaultSkinManifest + SkinPackManager

## 目标
创建中央管理器：加载内置皮肤、扫描本地皮肤、持久化选择、通知变更。

## 架构上下文
- SkinPackManager 是 singleton (`shared`)，所有消费方通过它获取当前皮肤
- 首次引入 UserDefaults 到项目（之前零使用）

## 要创建的文件
- `Sources/ClaudeCodeBuddy/Skin/DefaultSkinManifest.swift` — 静态属性返回当前硬编码值的 manifest
- `Sources/ClaudeCodeBuddy/Skin/SkinPackManager.swift` — singleton + Combine
- `Tests/BuddyCoreTests/SkinPackManagerTests.swift`

## 输入/输出契约

### DefaultSkinManifest
需要精确复制当前所有硬编码值：
- `spritePrefix: "cat"`
- `animationNames: ["idle-a","idle-b","clean","sleep","scared","paw","walk-a","walk-b","jump"]`
- `canvasSize: [48, 48]`
- `bedNames: ["bed-blue","bed-gray","bed-pink","bed-green"]`
- `boundarySprite: "boundary-bush"`
- `foodNames: [102 个食物名]` — 从 FoodSprite.allFoodNames 精确复制
- `menuBar: walkPrefix "menubar-walk", count 6, runPrefix "menubar-run", count 5, idle "menubar-idle-1", dir "Sprites/Menubar"`

### SkinPackManager
- `static let shared`
- `private(set) var activeSkin: SkinPack`
- `private(set) var availableSkins: [SkinPack]`
- `let skinChanged = PassthroughSubject<SkinPack, Never>()` (import Combine)
- `func loadBuiltInSkin()` — 用 DefaultSkinManifest + ResourceBundle.bundle
- `func loadLocalSkins()` — 扫描 `~/Library/Application Support/ClaudeCodeBuddy/Skins/`
- `func selectSkin(_ skinId: String)` — 更新 activeSkin + UserDefaults + send()
- UserDefaults key: `"selectedSkinId"`
- 初始化时: loadBuiltInSkin() + loadLocalSkins() + 从 UserDefaults 恢复选择（找不到则 fallback default）

## 验收标准
- [ ] `swift build` 编译通过
- [ ] `swift test --filter SkinPackManagerTests` 通过
- [ ] 内置皮肤加载后 activeSkin 可解析所有默认资源
- [ ] selectSkin round-trip: 选择 → UserDefaults → 重新加载 → activeSkin 一致
- [ ] skinChanged subject 在选择变化时触发
- [ ] 缺失 skinId fallback 到 "default"
