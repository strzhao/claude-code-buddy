<!-- tags: appkit, nsviewcontroller, nspanel, contentview, translatesautoresizingmask, frame, fitting-size, autoresize, settings-panel, layout, multi-tab -->
# NSViewController 作 NSPanel contentViewController：root view translatesAutoresizingMaskIntoConstraints=false + 无尺寸约束会缩到 fittingSize

## 现象
设置面板新增「热键」tab 的 `KeyboardShortcutsViewController` 打开后 frame 过小、底部内容（冲突提示）展示不全。对比同面板的 `SkinGalleryViewController`（skins tab）正常撑满 panel。

## 根因（对比 working tab 定位）
loadView 写成 `let container = NSView()` + `container.translatesAutoresizingMaskIntoConstraints = false` + `view = container`：
- container 无 frame（zero）+ `translatesAutoresizingMaskIntoConstraints=false` + 无任何尺寸约束 → 作为 `NSPanel.contentViewController.view` 时 NSWindow 无法确定尺寸 → 缩到子视图 `fittingSize`（内容紧凑高度），底部子视图被截断。
- 对比 working 的 `SkinGalleryViewController.loadView`：`NSView(frame: NSRect(0,0,580,480))`（**固定初始 frame**）+ **默认 `translatesAutoresizingMaskIntoConstraints=true`**（autoresize 填 panel）→ 正常撑满。

## Choice（修复）
root view 给**固定初始 frame**（对齐 panel contentRect，如 580×480）+ **不要**设 `translatesAutoresizingMaskIntoConstraints=false`（用默认 autoresize 填 panel）。子视图才设 `translatesAutoresizingMaskIntoConstraints=false` + 约束到 root view 边缘。

## 陷阱
- `contentViewController` 的 **root view 不要** `translatesAutoresizingMaskIntoConstraints=false`，除非给完整的 top/leading/bottom/trailing 约束到 contentView。
- 多 tab 面板新增 VC 时，**对齐既有 working tab 的 root view 初始化模式**（固定 frame + 默认 autoresize），不要自创。

## 何时复用
任何 `NSViewController` 作为 `NSPanel`/`NSWindow` `contentViewController` 且手动 `loadView` 的场景；设置面板多 tab 新增 VC。相关：[[nshostingcontroller-sizingoptions-preferredcontentsize]]（SwiftUI 路径用 sizingOptions，AppKit 路径用固定 frame）。
