---
id: "005-buddy-store-ui"
depends_on: ["004"]
---

# Task 005 — Buddy Store UI 重构（segmentedControl + PluginGallery 四态）

## 目标（一句话）

SettingsWindowController title 改 "Buddy Store" + 加顶部 NSSegmentedControl(["皮肤","插件"])；上次选中 tab 持久化 UserDefaults；新建 PluginGalleryViewController（四态：normal / loading / empty / error）；列表项 [禁用]/[启用] 按钮调用 task 004 API。

## 架构上下文

- 依赖 004（disable/enable 接口）
- 与 task 006/007 并行（互不依赖）
- 不破坏 SkinGallerySnapshotTests（它只测 SkinGalleryViewController 单 VC，与 SettingsWindowController 解耦）

## 输入

- 现有 `SettingsWindowController.swift` (37 行)
- 现有 `SkinGalleryViewController.swift` (317 行)
- `PluginManager.list()` + `disable/enable` (task 004)
- `MarketplaceManager.reseed()` (task 003)

## 输出契约

### 修改 `Sources/ClaudeCodeBuddy/Settings/SettingsWindowController.swift`

```swift
class SettingsWindowController: NSWindowController {
    enum Tab: String { case skins, plugins }
    
    private var skinGallery: SkinGalleryViewController!
    private var pluginGallery: PluginGalleryViewController!
    private var segmentedControl: NSSegmentedControl!
    
    convenience init() {
        let panel = SettingsPanel(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 540),  // +40 for segmented control
            ...
        )
        panel.title = "Buddy Store"   // 原 "Skin Market"
        ...
        // 顶部加 segmented control，下面装 contentVC
        let savedTab = UserDefaults.standard.string(forKey: "BuddyStoreSelectedTab")
                       .flatMap(Tab.init) ?? .skins
        self.switchTo(tab: savedTab)
    }
    
    @objc func segmentChanged() {
        let tab: Tab = segmentedControl.selectedSegment == 0 ? .skins : .plugins
        UserDefaults.standard.set(tab.rawValue, forKey: "BuddyStoreSelectedTab")
        switchTo(tab: tab)
    }
    
    private func switchTo(tab: Tab) {
        // 替换 panel.contentViewController
    }
}
```

### 新建 `Sources/ClaudeCodeBuddy/Settings/PluginGalleryViewController.swift`

四态状态机：

```swift
final class PluginGalleryViewController: NSViewController {
    enum State {
        case normal(plugins: [MarketplacePlugin])
        case loading
        case empty
        case error(message: String, canReseed: Bool)
    }
    
    @Published var state: State = .loading
    
    override func loadView() {
        // 容器 + NSCollectionView + 底部状态条
    }
    
    override func viewDidAppear() {
        Task { @MainActor in
            await refresh()
        }
    }
    
    private func refresh() async {
        do {
            let plugins = try PluginManager.shared.list().compactMap { ... }
            let disabledSet = Set(try PluginManager.shared.disabledNames())
            // ... 
            state = plugins.isEmpty ? .empty : .normal(plugins: plugins)
        } catch {
            state = .error(message: error.localizedDescription, canReseed: true)
        }
    }
    
    func handleDisableButton(pluginName: String) {
        try? PluginManager.shared.disable(name: pluginName)
        Task { await refresh() }
    }
    
    func handleEnableButton(pluginName: String) {
        try? PluginManager.shared.enable(name: pluginName)
        Task { await refresh() }
    }
    
    func handleReseedButton() {
        Task { @MainActor in
            do {
                try MarketplaceManager.shared.reseed()
                await refresh()
            } catch {
                state = .error(message: "重新初始化失败：\(error)", canReseed: false)
            }
        }
    }
}
```

### UI 文案

| 态 | 文案 |
|----|-----|
| normal | 列表，每项: `[图标] [name] · v[version]    [禁用]/[启用]` |
| loading | 居中: "正在加载插件市场..." + 旋转 icon |
| empty | 居中: "尚无插件可用" + [查看日志] 按钮（打开 ~/.buddy/launcher-sync.log） |
| error | 居中: "插件初始化失败：\(msg)" + [重新初始化] (调 reseed) + [查看日志] |

### 点击交互

参考 `SkinGalleryViewController.handleClickAt(windowPoint:)` + `SettingsPanel.sendEvent`：
- PluginGalleryViewController 也实现 `handleClickAt(windowPoint:)`
- 区分点中哪一行的 [禁用]/[启用] 按钮 → 调对应 method
- SettingsPanel 转发 click 时按当前 tab 路由到对应 VC

## 验收标准

### 自动化测试（红队）

1. **状态机 normal → empty**：注入 mock PluginManager 返回 [] → state == .empty
2. **状态机 normal**：注入 mock 返回 [translate] → state == .normal([translate])
3. **状态机 error**：mock list() throw → state == .error
4. **disable 按钮触发**：调用 handleDisableButton("translate") → PluginManager.disable 被调
5. **reseed 按钮触发**：mock MarketplaceManager.reseed → handleReseedButton → reseed 被调
6. **segmented control 持久化**：切到 plugins → UserDefaults 写入 "plugins"
7. **加载持久化 tab**：UserDefaults 预设 "plugins" → init 后 segmentedControl.selectedSegment == 1

### 验证命令

```bash
cd apps/desktop && swift build && swift test --filter "BuddyStore|PluginGallery"
make lint
```

### Tier 1.5 真实场景

1. **手动 GUI**: open Settings → segmented control 显示 "皮肤" / "插件" → 切到插件 → 看到 translate 列表 + [禁用] 按钮 → 点 [禁用] → 列表更新为 [启用]
2. **持久化**: 关 panel → 重开 → 默认停留在 "插件" tab
3. **CLI 断言**: `defaults read com.stringzhao.claude-code-buddy BuddyStoreSelectedTab` 返回 "plugins"
4. **snapshot 不破**: `swift test --filter SkinGallery` 全绿（原有快照不影响）

## 下游须知（handoff 要点）

- PluginGalleryViewController 是新文件，建议加 snapshot test 覆盖 4 态
- segmentedControl 高度建议 28px，参考 macOS Settings 风格
- 若需要 segmented control 之外加搜索框 / 分类筛选，留 phase 2
