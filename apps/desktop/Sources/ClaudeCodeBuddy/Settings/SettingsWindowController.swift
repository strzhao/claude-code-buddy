import AppKit

// MARK: - SettingsWindowController
//
// 重命名 "Buddy Store"。顶部 NSSegmentedControl 切 [皮肤/插件]。
// 持久化选中 tab 到 UserDefaults（key: `BuddyStoreSelectedTab`）。
// contentVC 按 tab 切换（同时只有 1 个 VC 持有 NSCollectionView + 数据）。
final class SettingsWindowController: NSWindowController {

    enum Tab: String {
        case skins
        case plugins
    }

    static let selectedTabDefaultsKey = "BuddyStoreSelectedTab"

    private let segmentedControl = NSSegmentedControl()
    private var skinGallery: SkinGalleryViewController?
    private var pluginGallery: PluginGalleryViewController?
    private weak var settingsPanel: SettingsPanel?

    convenience init() {
        let panel = SettingsPanel(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 540),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        panel.title = "Buddy Store"
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        self.init(window: panel)
        self.settingsPanel = panel

        setupSegmentedControl()

        let savedTab = UserDefaults.standard.string(forKey: Self.selectedTabDefaultsKey)
            .flatMap(Tab.init(rawValue:)) ?? .skins
        segmentedControl.selectedSegment = savedTab == .skins ? 0 : 1
        switchTo(tab: savedTab)
    }

    // MARK: - Segmented control

    private func setupSegmentedControl() {
        segmentedControl.segmentStyle = .texturedRounded
        segmentedControl.segmentCount = 2
        segmentedControl.setLabel("皮肤", forSegment: 0)
        segmentedControl.setLabel("插件", forSegment: 1)
        segmentedControl.target = self
        segmentedControl.action = #selector(segmentChanged)
        segmentedControl.translatesAutoresizingMaskIntoConstraints = false

        // 嵌入 titlebar accessory（macOS 11+ 原生支持）。
        let accessoryVC = NSTitlebarAccessoryViewController()
        let accessoryContainer = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 32))
        accessoryContainer.addSubview(segmentedControl)
        NSLayoutConstraint.activate([
            segmentedControl.centerXAnchor.constraint(equalTo: accessoryContainer.centerXAnchor),
            segmentedControl.centerYAnchor.constraint(equalTo: accessoryContainer.centerYAnchor),
        ])
        accessoryVC.view = accessoryContainer
        accessoryVC.layoutAttribute = .top
        settingsPanel?.addTitlebarAccessoryViewController(accessoryVC)
    }

    @objc private func segmentChanged() {
        let tab: Tab = segmentedControl.selectedSegment == 0 ? .skins : .plugins
        UserDefaults.standard.set(tab.rawValue, forKey: Self.selectedTabDefaultsKey)
        switchTo(tab: tab)
    }

    private func switchTo(tab: Tab) {
        let vc: NSViewController & SettingsTabClickReceiver
        switch tab {
        case .skins:
            let gallery = skinGallery ?? SkinGalleryViewController()
            skinGallery = gallery
            vc = gallery
        case .plugins:
            let gallery = pluginGallery ?? PluginGalleryViewController()
            pluginGallery = gallery
            vc = gallery
        }
        settingsPanel?.contentViewController = vc
        settingsPanel?.activeTab = vc
    }
}

// MARK: - SettingsPanel
//
// 拦截 leftMouseUp 转发到 activeTab.handleClickAt。
// LSUIElement apps 拿不到稳定的 key window，绕开 NSCollectionView 内建选中逻辑。
final class SettingsPanel: NSPanel {
    weak var activeTab: SettingsTabClickReceiver?

    override var canBecomeKey: Bool { true }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseUp, let activeTab {
            activeTab.handleClickAt(windowPoint: event.locationInWindow)
        }
        super.sendEvent(event)
    }
}
