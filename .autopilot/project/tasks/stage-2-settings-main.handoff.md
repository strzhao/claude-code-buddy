# stage-2 Handoff

## 实现摘要
设置主体套地基（plan Task 3-6 + 6.5）：组件间距收口（GroupView/ToggleRow/FormRow → spacing scale + minRowHeight 44）+ 单栏页（General/About/Hotkey/Provider）包 ContentColumnView 限宽居中 + EmptyPluginStateVC 响应式 + sidebar 固定 200 + 重录快照（8 张）+ **blocker 2 AX 唯一性修订**（4 处 :75/:170/:121/:160 + 2 硬断言测试适配）。

## 文件变更（5 commits + merge）
- `0c9cef5` 组件间距收口（GroupView/ToggleRow/FormRow）
- `12f9b28` 单栏页包 ContentColumnView（General/About/Hotkey）
- `ffc2830` Provider 去 scroll 改 ContentColumnView + Empty 响应式
- `68d9646` sidebar 固定 200 + 重录快照（8 张）
- `88e98aa` AX 4 处修订 + 2 测试适配 + SettingsLayoutAcceptanceTests
- merge commit（红队 SettingsFrameAcceptanceTests）

## 下游须知（stage-3 插件面板）
- **ContentColumnView 范式**：双栏面板（PluginGallery）只包**右栏**（左栏占满高固定宽）；stage-3 插件左栏固定 240。
- **frame 谓词 in-process 模式已建立**（SettingsFrameAcceptanceTests + SettingsLayoutAcceptanceTests）：用 SettingsWindowController 建真实 window + `splitViewItems[0]` public API 读 sidebar + 递归找 AX id / ContentColumnView。stage-3 验证 AC-SPLIT-02（列表栏 240）可复用此模式。
- **AX 唯一性已修订**（settings.detail 只在 :161 child；容器 :75/:171 → settings.detail.container；空态 :123 → settings.plugin.empty）。stage-3 插件 cell 加 AX id 不冲突。
- **栅格 token 全程用**（stage-0/1/2 已收口，后续禁硬编码）。

## 偏差说明
- 蓝队临时修红队测试 optional unwrap（`window.contentView?.bounds.height ?? 600`，defensive 不改逻辑，运行时 contentView 非 nil 不触发）。
- plan-reviewer 2 轮拦 blocker（B1 AX 修订破坏 2 硬断言测试 / B2 漏 :75 共 4 处 AX id）已修，frame 谓词首次真实验证全 PASS。无功能偏差。