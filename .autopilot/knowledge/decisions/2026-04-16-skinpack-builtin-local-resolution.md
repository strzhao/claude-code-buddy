# SkinPack 资源解析采用 builtIn/local 分支而非统一 Bundle

<!-- tags: skin, resource, bundle, assets -->

**决策**: `SkinPack` 通过 `SkinSource` enum 区分两种资源解析路径：`builtIn(Bundle)` 走 `Bundle.url(forResource:withExtension:subdirectory:)` 且自动补 `"Assets/"` 前缀；`local(URL)` 走 `FileManager` 直接拼接 `baseURL + subdirectory + name.ext`。

**否决**: 让所有皮肤（含下载的）都创建 `Bundle(url:)` 实例。创建 Bundle 需要 `Info.plist` 且初始化可能失败，对用户下载的 .zip 解压目录不友好。

**理由**:
- SPM 内置资源通过 `.copy("Assets")` 放入 bundle，路径带 `Assets/` 前缀；下载皮肤的目录结构是 `Sprites/`、`Food/` 直接在根目录
- `SkinPack.url()` 方法签名与 `Bundle.url()` 一致，消费方调用方式不变，只需把 `ResourceBundle.bundle` 替换为 `skinPack`
- builtIn 路径覆盖了现有所有 `ResourceBundle.bundle.url(...)` 调用点（AnimationComponent、CatTaskCompleteState、BuddyScene、FoodSprite、MenuBarAnimator）

**影响文件**: Sources/ClaudeCodeBuddy/Skin/SkinPack.swift（新建），以及所有纹理加载调用点

**约束**: 新增纹理加载点时，必须通过 `SkinPackManager.shared.activeSkin.url(...)` 而非 `ResourceBundle.bundle.url(...)`。内置皮肤的 subdirectory 不要手动加 `"Assets/"` 前缀——SkinPack.url() 内部处理。
