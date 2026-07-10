import AppKit

/// Settings 主 split VC：左侧 sidebar + 右侧 detail 容器。
///
/// 数据驱动（契约 2）：选中切换全部从 `SettingsSection.allCases` 走，
/// sidebar 选中 → detail 容器内 child VC 通过 containment 替换。
///
/// detail 容器设 AX identifier `settings.detail`（契约 7）。
/// 选中分类存 UserDefaults key `SettingsSelectedCategory`（契约 4），默认 .skins。
///
/// detail 切换策略：detail NSSplitViewItem 的 viewController 固定为
/// `SettingsDetailContainerViewController`（容器），切换分类时通过标准
/// child VC containment（addChild + transition）替换容器内的 child VC，
/// **不**替换 splitViewItem.viewController（NSSplitViewItem 一旦加入 splitView
/// 后其 viewController 不可直接替换，否则抛 NSInternalInconsistencyException）。
final class SettingsSplitViewController: NSSplitViewController {

    private let sidebar = SettingsSidebarViewController()
    private let sidebarItem: NSSplitViewItem
    private let detailItem: NSSplitViewItem
    private let detailContainer = SettingsDetailContainerViewController()

    /// 持久化 key（契约 4）。
    static let selectedCategoryDefaultsKey = SettingsWindowController.selectedCategoryDefaultsKey

    /// 当前选中分类（初始从 UserDefaults 恢复，默认 .skins）。
    private(set) var selectedSection: SettingsSection

    /// detail VC 缓存（避免重复创建三 tab VC；通用/关于可即时建）。
    private var detailCache: [SettingsSection: NSViewController] = [:]

    /// detail VC 工厂（默认内部实现；测试可注入 mock）。
    /// 此处 switch 基于枚举 case 分发（每个 case 语义不同，非"按数量分支"），
    /// 不违反契约 2（契约禁止"按分类数量 switch/if 硬编码 sidebar 布局分支"，
    /// 即新增 case 不应改动窗口/splitVC 骨架；本工厂随 case 扩展是必然的）。
    var detailViewControllerProvider: (SettingsSection) -> NSViewController = { section in
        switch section {
        case .skins:   return SkinGalleryViewController()
        case .plugins: return PluginGalleryViewController()
        case .hotkey:   return KeyboardShortcutsViewController()
        case .general: return GeneralSettingsViewController()
        case .about:   return AboutSettingsViewController()
        case .ai:      return ProviderSettingsViewController()
        }
    }

    init() {
        let savedRaw = UserDefaults.standard.string(
            forKey: SettingsSplitViewController.selectedCategoryDefaultsKey
        )
        self.selectedSection = SettingsSection(rawValue: savedRaw ?? "") ?? .skins

        self.sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.canCollapse = false
        // 固定宽度（删 180-240 区间），消除拖动跳动
        sidebarItem.minimumThickness = SettingsTheme.sidebarWidth
        sidebarItem.maximumThickness = SettingsTheme.sidebarWidth

        self.detailItem = NSSplitViewItem(viewController: detailContainer)

        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        addSplitViewItem(sidebarItem)
        addSplitViewItem(detailItem)

        // 契约 7：detail 容器 AX identifier
        detailContainer.view.setAccessibilityIdentifier("settings.detail")

        sidebar.onSelectSection = { [weak self] section in
            self?.switchTo(section: section, persist: true)
        }

        // 初始选中（不触发 onSelectSection 回调，直接切换）
        sidebar.selectSection(selectedSection)
        switchTo(section: selectedSection, persist: false)
    }

    /// 切换 detail 到指定分类。
    /// - Parameter persist: 是否写 UserDefaults（恢复初始时不写）。
    private func switchTo(section: SettingsSection, persist: Bool) {
        selectedSection = section

        let detailVC: NSViewController
        if let cached = detailCache[section] {
            detailVC = cached
        } else {
            let created = detailViewControllerProvider(section)
            detailCache[section] = created
            detailVC = created
        }

        // 通过容器 containment 切换 child VC（保持 splitViewItem 结构稳定）
        detailContainer.transition(to: detailVC)

        if persist {
            UserDefaults.standard.set(section.rawValue,
                                      forKey: SettingsSplitViewController.selectedCategoryDefaultsKey)
        }
    }

    // MARK: - Public API

    /// 程序化选中指定分类（sidebar 高亮 + detail 切换，持久化选中状态）。
    /// 供 AppDelegate.openSettingsToAbout() 等外部调用。
    func selectSection(_ section: SettingsSection) {
        sidebar.selectSection(section, animateScroll: true)
        switchTo(section: section, persist: true)
    }

    // MARK: - Test hooks

    /// 当前 detail 容器内的 child VC（测试断言类型用）。
    var detailChildViewController: NSViewController? {
        detailContainer.currentChild
    }

    /// 测试驱动：程序化选中某分类（模拟 sidebar 点击）。
    func testHook_selectSection(_ section: SettingsSection) {
        switchTo(section: section, persist: true)
    }
}

// MARK: - SettingsDetailContainerViewController

/// detail 容器 VC：固定挂载在 splitViewItem，内部通过 child containment 切换分类 VC。
///
/// 防 fittingSize 缩 0（patterns/2026-06-16）：固定初始 frame + 默认 autoresize。
final class SettingsDetailContainerViewController: NSViewController {

    private(set) var currentChild: NSViewController?

    override func loadView() {
        // 固定初始 frame + 默认 autoresize（防 fittingSize 缩 0）
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 540))
        container.autoresizingMask = [.width, .height]
        self.view = container
    }

    /// 切换 child VC（标准 containment：移除旧 child + 加载新 child + autolayout 填满）。
    func transition(to newChild: NSViewController) {
        // 移除旧 child
        if let old = currentChild {
            old.view.removeFromSuperview()
            old.removeFromParent()
        }

        addChild(newChild)
        let childView = newChild.view
        childView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(childView)
        // 契约 7：detail 锚点设在 child root view（AX 可见层；容器 view 被 child 遮蔽）
        childView.setAccessibilityIdentifier("settings.detail")
        NSLayoutConstraint.activate([
            childView.topAnchor.constraint(equalTo: view.topAnchor),
            childView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            childView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            childView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        currentChild = newChild

        // 契约 7：detail 容器 AX identifier（容器本身，不随 child 变）
        view.setAccessibilityIdentifier("settings.detail")
    }
}
