import AppKit

// MARK: - PluginGalleryViewController
//
// 「插件」设置分类。改用通用页同款 SettingsGroupView 分组卡片样式（替代旧 NSCollectionView 列表）。
//
// 四态状态机（保留）：
//   - .loading：初次进入 / refresh 进行中
//   - .normal：marketplace + sideloaded 合并后非空 → 每插件一行 SettingsToggleRow
//   - .empty：两者都空
//   - .error：inspect 抛错 → 显示 reseed 按钮
//
// DI（保留 B3）：MarketplaceInspecting + PluginToggling 协议注入。
// state internal private(set)（@testable import 可断言，保留 M2）。
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

    /// M2：internal private(set) 暴露给测试 target，外部不可写。
    internal private(set) var state: State = .loading

    // MARK: - DI（B3）

    private let marketplace: MarketplaceInspecting
    private let plugins: PluginToggling

    // MARK: - UI

    private let scrollView = NSScrollView()
    private let contentView = NSView()
    private let groupLabel = SettingsGroupLabel(title: "插件")
    private let group = SettingsGroupView()
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
        setupLayout(in: container)
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

    private func setupLayout(in container: NSView) {
        // scrollView 填满 container（承载可滚动的分组卡片）
        scrollView.documentView = contentView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scrollView)

        contentView.translatesAutoresizingMaskIntoConstraints = false

        groupLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(groupLabel)

        group.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(group)

        // placeholder / reseed overlay 在 container（固定居中，不随滚动）
        placeholderLabel.font = SettingsTheme.rowSubtitleFont()
        placeholderLabel.textColor = SettingsTheme.rowSubtitleColor()
        placeholderLabel.alignment = .center
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(placeholderLabel)

        reseedButton.bezelStyle = .rounded
        reseedButton.target = self
        reseedButton.action = #selector(handleReseedButton)
        reseedButton.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(reseedButton)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            // contentView 宽度 = clipView 宽；高度 ≥ clipView 高（内容少时撑满 viewport，顶部对齐，避免 cell 整体靠下）
            contentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            contentView.heightAnchor.constraint(greaterThanOrEqualTo: scrollView.contentView.heightAnchor),

            // groupLabel
            groupLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: SettingsTheme.groupTopInset),
            groupLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: SettingsTheme.contentPadding),
            groupLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -SettingsTheme.contentPadding),

            // group（分组卡片，内容自适应高度，参照 GeneralSettings 无 bottom 约束）
            group.topAnchor.constraint(equalTo: groupLabel.bottomAnchor, constant: 6),
            group.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: SettingsTheme.contentPadding),
            group.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -SettingsTheme.contentPadding),

            // contentView 高度跟随 group 内容，不拉伸 group
            contentView.bottomAnchor.constraint(greaterThanOrEqualTo: group.bottomAnchor, constant: SettingsTheme.groupTopInset),

            // placeholder（居中 container，不依赖 contentView 高度）
            placeholderLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            placeholderLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            placeholderLabel.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 24),
            placeholderLabel.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -24),

            // reseed
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
            // inspect() 是 throws（无 await，B2）
            let inspection = try marketplace.inspect()
            let entries: [PluginEntry] = inspection.plugins.map { p in
                PluginEntry(name: p.name, version: p.version, isSideloaded: false, enabled: p.enabled)
            }
            let sideloaded: [PluginEntry] = inspection.sideloadedPlugins.map { s in
                PluginEntry(name: s.name, version: "—", isSideloaded: true, enabled: s.enabled)
            }
            let all = entries + sideloaded
            state = all.isEmpty ? .empty : .normal(plugins: all)
        } catch {
            state = .error(message: error.localizedDescription)
        }
        renderState()
    }

    private func renderState() {
        guard isViewLoaded else { return }
        switch state {
        case .normal(let plugins):
            group.clearRows()
            for entry in plugins {
                let row = SettingsToggleRow(
                    title: entry.name,
                    subtitle: entry.isSideloaded ? "侧载" : "v\(entry.version)",
                    isOn: entry.enabled
                )
                row.onToggle = { [weak self] isOn in
                    self?.togglePlugin(name: entry.name, enable: isOn)
                }
                group.addRow(row)
            }
            groupLabel.isHidden = false
            group.isHidden = false
            scrollView.isHidden = false
            placeholderLabel.isHidden = true
            reseedButton.isHidden = true
        case .loading:
            group.clearRows()
            groupLabel.isHidden = true
            group.isHidden = true
            scrollView.isHidden = true
            placeholderLabel.stringValue = "正在加载插件市场..."
            placeholderLabel.isHidden = false
            reseedButton.isHidden = true
        case .empty:
            group.clearRows()
            groupLabel.isHidden = true
            group.isHidden = true
            scrollView.isHidden = true
            placeholderLabel.stringValue = "尚无插件可用"
            placeholderLabel.isHidden = false
            reseedButton.isHidden = true
        case .error(let message):
            group.clearRows()
            groupLabel.isHidden = true
            group.isHidden = true
            scrollView.isHidden = true
            placeholderLabel.stringValue = "插件初始化失败：\(message)"
            placeholderLabel.isHidden = false
            reseedButton.isHidden = false
        }
    }

    // MARK: - SettingsTabClickReceiver

    /// SettingsToggleRow 走自身 onToggle 闭包，不需要 hit-test 转发。
    /// 保留 no-op 兼容 SettingsWindow.sendEvent 的 forwardDetailClick（C3 点击兜底）。
    func handleClickAt(windowPoint: NSPoint) {
        // no-op
    }

    // MARK: - Actions

    /// 切换插件启用状态（SettingsToggleRow.onToggle 回调）。
    private func togglePlugin(name: String, enable: Bool) {
        guard let safeName = sanitize(name) else {
            BuddyLogger.shared.warn("pluginGallery toggle invalid name", subsystem: "settings", meta: ["name": name])
            return
        }
        Task { @MainActor in
            do {
                if enable {
                    try plugins.enable(name: safeName)
                } else {
                    try plugins.disable(name: safeName)
                }
                await refresh()
            } catch {
                BuddyLogger.shared.error("pluginGallery toggle failed", subsystem: "settings", meta: ["name": safeName, "error": "\(error)"])
            }
        }
    }

    /// Test hook（旧 NSButton 路径兼容）：sender.identifier=plugin name, sender.tag=0→disable / 1→enable。
    /// 生产路径改走 SettingsToggleRow.onToggle → togglePlugin；此方法仅供测试验证 sanitize + enable/disable 逻辑链。
    @objc func toggleButtonClicked(_ sender: NSButton) {
        let raw = sender.identifier?.rawValue ?? ""
        togglePlugin(name: raw, enable: sender.tag == 1)
    }

    @objc func handleReseedButton() {
        Task { @MainActor in
            do {
                // reseed 是 async throws（B2）
                try await marketplace.reseed()
                await refresh()
            } catch {
                state = .error(message: "重新初始化失败：\(error.localizedDescription)")
                renderState()
            }
        }
    }

    // MARK: - Helpers

    /// 路径白名单（深度防御，task 004 follow-up）。仅接受 `[a-z0-9-]+`。
    private func sanitize(_ name: String) -> String? {
        guard !name.isEmpty,
              name.range(of: "^[a-z0-9-]+$", options: .regularExpression) != nil else {
            return nil
        }
        return name
    }
}
