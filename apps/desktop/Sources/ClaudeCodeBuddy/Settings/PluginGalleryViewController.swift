import AppKit

// MARK: - PluginGalleryViewController
//
// Buddy Store 的"插件" tab。四态状态机：
//   - .loading：初次进入 / refresh 进行中
//   - .normal：marketplace + sideloaded 合并后非空
//   - .empty：两者都空
//   - .error：inspect 抛错 → 显示 reseed 按钮
//
// 关键修复（plan 第 1 轮 PASS 后落地）：
// - B1: PluginEntry 用 `isSideloaded: Bool` 替代 description
// - B2: inspect() 是 throws（无 await）；reseed() 是 async throws
// - B3: init(marketplace:plugins:) 注入；MarketplaceInspecting + PluginToggling 协议
// - M1: PluginCardItem NSButton target/action 直绑 toggleButtonClicked，handleClickAt 仅 no-op
// - M2: state 是 internal private(set)（@testable import 可断言）
final class PluginGalleryViewController: NSViewController, SettingsTabClickReceiver {

    // MARK: - State

    struct PluginEntry: Equatable {
        let name: String
        let version: String
        /// true = `~/.buddy/launcher-plugins/` 下未出现在 marketplace cache 中的目录（手动 add）
        let isSideloaded: Bool
        let enabled: Bool
    }

    enum State: Equatable {
        case loading
        case normal(plugins: [PluginEntry])
        case empty
        case error(message: String)
    }

    /// M2 修复：internal private(set) 暴露给测试 target，外部不可写。
    internal private(set) var state: State = .loading

    // MARK: - DI（B3 修复）

    private let marketplace: MarketplaceInspecting
    private let plugins: PluginToggling

    // MARK: - UI

    private var collectionView: NSCollectionView!
    private let scrollView = NSScrollView()
    private let placeholderLabel = NSTextField(labelWithString: "")
    private let reseedButton = NSButton(title: "重新初始化", target: nil, action: nil)

    // MARK: - Init

    init(
        marketplace: MarketplaceInspecting = MarketplaceManager.shared,
        plugins: PluginToggling = PluginManager.shared
    ) {
        self.marketplace = marketplace
        self.plugins = plugins
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not used")
    }

    // MARK: - Lifecycle

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 500))
        setupCollectionView(in: container)
        setupPlaceholder(in: container)
        setupReseedButton(in: container)
        self.view = container
        renderState()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        Task { @MainActor in
            await refresh()
        }
    }

    // MARK: - Setup

    private func setupCollectionView(in container: NSView) {
        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = NSSize(width: 560, height: 56)
        layout.minimumLineSpacing = 8
        layout.sectionInset = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)

        collectionView = NSCollectionView(frame: .zero)
        collectionView.collectionViewLayout = layout
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.backgroundColors = [.clear]
        collectionView.isSelectable = false
        collectionView.register(PluginCardItem.self, forItemWithIdentifier: PluginCardItem.identifier)

        scrollView.documentView = collectionView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }

    private func setupPlaceholder(in container: NSView) {
        placeholderLabel.font = .systemFont(ofSize: 13)
        placeholderLabel.textColor = .secondaryLabelColor
        placeholderLabel.alignment = .center
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(placeholderLabel)

        NSLayoutConstraint.activate([
            placeholderLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            placeholderLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor, constant: -16),
            placeholderLabel.leadingAnchor.constraint(
                greaterThanOrEqualTo: container.leadingAnchor, constant: 24),
            placeholderLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: container.trailingAnchor, constant: -24),
        ])
    }

    private func setupReseedButton(in container: NSView) {
        reseedButton.bezelStyle = .rounded
        reseedButton.target = self
        reseedButton.action = #selector(handleReseedButton)
        reseedButton.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(reseedButton)

        NSLayoutConstraint.activate([
            reseedButton.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            reseedButton.topAnchor.constraint(equalTo: placeholderLabel.bottomAnchor, constant: 12),
        ])
    }

    // MARK: - State machine

    @MainActor
    func refresh() async {
        state = .loading
        renderState()
        do {
            // B2 修复：inspect() 是 throws 非 async
            let inspection = try marketplace.inspect()
            let entries: [PluginEntry] = inspection.plugins.map { p in
                PluginEntry(
                    name: p.name,
                    version: p.version,
                    isSideloaded: false,
                    enabled: p.enabled
                )
            }
            let sideloaded: [PluginEntry] = inspection.sideloadedPlugins.map { s in
                PluginEntry(
                    name: s.name,
                    version: "—",
                    isSideloaded: true,
                    enabled: s.enabled
                )
            }
            let all = entries + sideloaded
            state = all.isEmpty ? .empty : .normal(plugins: all)
        } catch {
            state = .error(message: error.localizedDescription)
        }
        renderState()
    }

    private func renderState() {
        // collectionView 可能在 loadView 前未初始化（测试场景）
        guard isViewLoaded else { return }
        switch state {
        case .normal:
            collectionView.reloadData()
            scrollView.isHidden = false
            placeholderLabel.isHidden = true
            reseedButton.isHidden = true
        case .loading:
            placeholderLabel.stringValue = "正在加载插件市场..."
            scrollView.isHidden = true
            placeholderLabel.isHidden = false
            reseedButton.isHidden = true
        case .empty:
            placeholderLabel.stringValue = "尚无插件可用"
            scrollView.isHidden = true
            placeholderLabel.isHidden = false
            reseedButton.isHidden = true
        case .error(let message):
            placeholderLabel.stringValue = "插件初始化失败：\(message)"
            scrollView.isHidden = true
            placeholderLabel.isHidden = false
            reseedButton.isHidden = false
        }
    }

    // MARK: - SettingsTabClickReceiver

    /// M1 修复：PluginCardItem.toggleButton 走 NSButton target/action 直绑，
    /// 此方法不需要 hit-test 转发，留 no-op 兼容 SettingsPanel.sendEvent。
    func handleClickAt(windowPoint: NSPoint) {
        // no-op
    }

    // MARK: - Actions

    /// PluginCardItem 内 NSButton 直绑此方法（M1 路径）。
    @objc func toggleButtonClicked(_ sender: NSButton) {
        let raw = sender.identifier?.rawValue ?? ""
        guard let name = sanitize(raw) else {
            NSLog("[PluginGallery] toggle: invalid name '\(raw)'")
            return
        }
        // sender.tag: 0 = currently enabled → disable; 1 = currently disabled → enable
        let shouldDisable = sender.tag == 0
        Task { @MainActor in
            do {
                if shouldDisable {
                    try plugins.disable(name: name)
                } else {
                    try plugins.enable(name: name)
                }
                await refresh()
            } catch {
                NSLog("[PluginGallery] toggle '\(name)' failed: \(error)")
            }
        }
    }

    @objc func handleReseedButton() {
        Task { @MainActor in
            do {
                // B2 修复：reseed 是 async throws
                try await marketplace.reseed()
                await refresh()
            } catch {
                state = .error(message: "重新初始化失败：\(error.localizedDescription)")
                renderState()
            }
        }
    }

    // MARK: - Helpers

    /// 路径白名单（深度防御，task 004 follow-up）。
    /// 仅接受 `[a-z0-9-]+`，否则静默 ignore + NSLog 警告。
    private func sanitize(_ name: String) -> String? {
        guard !name.isEmpty,
              name.range(of: "^[a-z0-9-]+$", options: .regularExpression) != nil else {
            return nil
        }
        return name
    }

    // MARK: - Test hooks
    //
    // 测试只读 state（M2）；不直接暴露内部按钮，按钮 target/action 路径由 toggleButtonClicked 验证。
}

// MARK: - NSCollectionViewDataSource

extension PluginGalleryViewController: NSCollectionViewDataSource {
    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        if case .normal(let plugins) = state { return plugins.count }
        return 0
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        itemForRepresentedObjectAt indexPath: IndexPath
    ) -> NSCollectionViewItem {
        let item = collectionView.makeItem(
            withIdentifier: PluginCardItem.identifier,
            for: indexPath
        )
        guard let card = item as? PluginCardItem,
              case .normal(let plugins) = state,
              indexPath.item < plugins.count else { return item }
        card.configure(entry: plugins[indexPath.item], controller: self)
        return card
    }
}

// MARK: - NSCollectionViewDelegateFlowLayout

extension PluginGalleryViewController: NSCollectionViewDelegateFlowLayout {}
