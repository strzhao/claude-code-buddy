# 皮肤包系统 — 项目设计文档

## 目标

为 Claude Code Buddy 引入皮肤包系统，使猫咪精灵、动画、装饰物（床、边界）、食物、菜单栏图标可按皮肤包切换。提供设置中心 UI 和远程皮肤商店。

## 系统架构

```
SkinPackManifest (Codable)          ← 皮肤包元数据 + 资产配置
        ↑
SkinPack (struct)                   ← manifest + 资源解析（Bundle 或 file URL）
        ↑
SkinPackManager (singleton)         ← 加载/选择/持久化/变更通知
   ↑           ↑            ↑
CatSprite  MenuBarAnimator  BuddyScene/FoodSprite
```

**数据流**: 用户选皮肤 → SkinPackManager.selectSkin() → UserDefaults 持久化 → Combine skinChanged → AppDelegate 接收 → 分发到 BuddyScene.reloadSkin() + MenuBarAnimator.reloadSprites()

## 关键技术决策

1. **SkinPack 统一资源解析**: `url(forResource:withExtension:subdirectory:)` 方法，内置皮肤走 `Bundle.url()` 带 "Assets/" 前缀，本地/下载皮肤走 `FileManager` 直接拼接
2. **Manifest 驱动**: `manifest.json` 声明所有资产名和配置
3. **UserDefaults 持久化**: `selectedSkinId` 单键
4. **NSPanel 设置窗口**: 独立于 popover 的浮动面板
5. **热替换**: removeAllActions() → loadTextures() → resume()。CatEatingState 跳过（吃完自然用新纹理）

## SkinPackManifest 结构

```swift
struct SkinPackManifest: Codable, Equatable {
    let id: String
    let name: String
    let author: String
    let version: String
    let previewImage: String?
    let spritePrefix: String
    let animationNames: [String]
    let canvasSize: [CGFloat]
    let bedNames: [String]
    let boundarySprite: String
    let foodNames: [String]
    let foodDirectory: String
    let spriteDirectory: String
    let menuBar: MenuBarConfig

    struct MenuBarConfig: Codable, Equatable {
        let walkPrefix: String
        let walkFrameCount: Int
        let runPrefix: String
        let runFrameCount: Int
        let idleFrame: String
        let directory: String
    }
}
```

## 跨任务约束

- 新类型前缀 `SkinPack`，目录 `Skin/` 和 `Settings/`
- `SkinPack.url()` 是纹理加载唯一入口
- `SkinPackManager.shared.activeSkin` 是当前皮肤唯一来源
- Combine `.receive(on: RunLoop.main)` 确保主线程
- 缺失纹理保持现有降级行为
