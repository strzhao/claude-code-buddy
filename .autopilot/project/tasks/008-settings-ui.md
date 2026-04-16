---
id: "008-settings-ui"
depends_on: ["007-hotswap"]
---

# 008: 设置窗口 + 皮肤画廊 + popover 按钮

## 目标
从菜单栏弹窗打开独立设置窗口，展示皮肤画廊，单击即时切换。

## 要创建的文件
- `Sources/ClaudeCodeBuddy/Settings/SettingsWindowController.swift` — NSWindowController + NSPanel
- `Sources/ClaudeCodeBuddy/Settings/SkinGalleryViewController.swift` — NSScrollView + NSStackView 画廊
- `Sources/ClaudeCodeBuddy/Settings/SkinGalleryItemView.swift` — 单个皮肤卡片 NSView

## 要修改的文件
- `Sources/ClaudeCodeBuddy/MenuBar/SessionPopoverController.swift` — 底栏加齿轮按钮
- `Sources/ClaudeCodeBuddy/App/AppDelegate.swift` — 管理设置窗口生命周期

## 变更详情

### SessionPopoverController
- 底栏新增齿轮按钮（NSButton with SF Symbol "gear"），放在 footerLabel 和 Quit 按钮之间
- 新增 `var onSettings: (() -> Void)?` 回调

### SettingsWindowController
- NSWindowController 创建 NSPanel (styleMask: [.titled, .closable, .resizable])
- 非模态，浮动，可与主窗口共存
- 标题 "Claude Code Buddy — Settings"
- 内容: SkinGalleryViewController

### SkinGalleryViewController（NSStackView 方案，非 NSCollectionView）
- 用 NSScrollView 包裹垂直 NSStackView
- 从 `SkinPackManager.shared.availableSkins` 获取皮肤列表
- 每个皮肤渲染为 SkinGalleryItemView
- 点击选中 → 调用 `SkinPackManager.shared.selectSkin(id:)` → 热替换自动生效
- 订阅 `SkinPackManager.shared.skinChanged` 更新选中态
- 底部预留 "Get More Skins" 占位区域（009 任务填充）

### SkinGalleryItemView（单个卡片）
- 预览图 (NSImageView, 80x60pt) — 从 manifest.previewImage 加载，无则显示首帧精灵
- 皮肤名 (NSTextField, bold 13pt)
- 作者 (NSTextField, secondary 11pt)
- 选中态: 蓝色边框 + checkmark overlay

### AppDelegate
- 持有 `private var settingsWindowController: SettingsWindowController?`
- popoverController.onSettings 回调中: 关闭 popover → 创建/显示设置窗口
- 设置窗口关闭不退出 app（NSPanel 默认行为）

## 验收标准
- [ ] `make build` 编译通过
- [ ] popover 底栏齿轮按钮可见
- [ ] 点击齿轮 → 设置窗口弹出
- [ ] 画廊显示所有可用皮肤（至少 default）
- [ ] 当前皮肤有选中态标识
- [ ] 点击其他皮肤 → 立即切换 + 猫咪更新
- [ ] 设置窗口与猫咪场景不互相阻塞
