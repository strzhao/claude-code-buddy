---
id: "006-refactor-menubar"
depends_on: ["002-skin-manager"]
---

# 006: 重构 MenuBarAnimator

## 目标
菜单栏精灵加载改为通过 SkinPack 驱动。

## 要修改的文件
- `Sources/ClaudeCodeBuddy/MenuBar/MenuBarAnimator.swift`

## 变更详情

### MenuBarAnimator.swift
- `loadSprites()`: 
  - walk 帧: `manifest.menuBar.walkPrefix` + `manifest.menuBar.walkFrameCount`
  - run 帧: `manifest.menuBar.runPrefix` + `manifest.menuBar.runFrameCount`
  - idle: `manifest.menuBar.idleFrame`
  - 目录: `manifest.menuBar.directory`
  - 全部通过 `SkinPackManager.shared.activeSkin.url(...)` 加载
- `loadFrameSequence(prefix:count:size:)`: 接收额外 `skin: SkinPack` 参数
- 新增 `func reloadSprites()`: 调用 `loadSprites()` + 重新应用当前状态（idle/walk/run）

## 验收标准
- [ ] `make build` 编译通过
- [ ] `make test` 全部通过
- [ ] 菜单栏图标正常显示和动画
- [ ] MenuBarAnimator 不再有 `ResourceBundle.bundle` 直接引用
- [ ] 新增 `reloadSprites()` 公开方法供热替换调用
