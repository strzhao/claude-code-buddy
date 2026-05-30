import AppKit

// MARK: - PluginCardItem
//
// 每行展示一个 plugin：[名字 + 版本 + (侧载 badge) + 禁用/启用按钮]。
//
// 设计要点（M1 修复）：
// - toggleButton.target/action 直绑 PluginGalleryViewController.toggleButtonClicked(_:)
//   不依赖 SettingsPanel.sendEvent 转发 → 行为可被 XCTest performClick 触发。
// - sender.tag: 0 = currently enabled（点击 → disable）；1 = currently disabled（点击 → enable）
// - sender.identifier: plugin name（控制器侧 sanitize 白名单校验）
final class PluginCardItem: NSCollectionViewItem {

    static let identifier = NSUserInterfaceItemIdentifier("PluginCardItem")

    let nameLabel = NSTextField(labelWithString: "")
    let versionLabel = NSTextField(labelWithString: "")
    let badgeLabel = NSTextField(labelWithString: "")
    let toggleButton = NSButton(title: "", target: nil, action: nil)

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 56))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        container.layer?.cornerRadius = 6

        nameLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(nameLabel)

        versionLabel.font = .systemFont(ofSize: 11)
        versionLabel.textColor = .secondaryLabelColor
        versionLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(versionLabel)

        badgeLabel.font = .systemFont(ofSize: 10, weight: .medium)
        badgeLabel.textColor = .systemOrange
        badgeLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(badgeLabel)

        toggleButton.bezelStyle = .rounded
        toggleButton.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(toggleButton)

        NSLayoutConstraint.activate([
            nameLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            nameLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),

            versionLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            versionLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 2),

            badgeLabel.leadingAnchor.constraint(equalTo: versionLabel.trailingAnchor, constant: 8),
            badgeLabel.centerYAnchor.constraint(equalTo: versionLabel.centerYAnchor),

            toggleButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            toggleButton.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])

        self.view = container
    }

    func configure(
        entry: PluginGalleryViewController.PluginEntry,
        controller: PluginGalleryViewController
    ) {
        nameLabel.stringValue = entry.name
        versionLabel.stringValue = "v\(entry.version)"
        badgeLabel.stringValue = entry.isSideloaded ? "侧载" : ""
        toggleButton.title = entry.enabled ? "禁用" : "启用"
        toggleButton.tag = entry.enabled ? 0 : 1
        toggleButton.identifier = NSUserInterfaceItemIdentifier(entry.name)
        toggleButton.target = controller
        toggleButton.action = #selector(PluginGalleryViewController.toggleButtonClicked(_:))
    }
}
