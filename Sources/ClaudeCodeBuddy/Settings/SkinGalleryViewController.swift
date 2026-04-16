import AppKit
import Combine

class SkinGalleryViewController: NSViewController {
    private let scrollView = NSScrollView()
    private let stackView = NSStackView()
    private var cancellables = Set<AnyCancellable>()
    private var itemViews: [String: SkinGalleryItemView] = [:]

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 360))

        // Stack view (vertical list of skin cards)
        stackView.orientation = .vertical
        stackView.spacing = 8
        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.alignment = .leading

        scrollView.documentView = stackView
        scrollView.hasVerticalScroller = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        container.addSubview(scrollView)

        // "Get More Skins" footer placeholder
        let footerLabel = NSTextField(labelWithString: "Get More Skins")
        footerLabel.font = .systemFont(ofSize: 11)
        footerLabel.textColor = .tertiaryLabelColor
        footerLabel.alignment = .center
        footerLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(footerLabel)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: footerLabel.topAnchor, constant: -8),

            stackView.widthAnchor.constraint(equalTo: scrollView.widthAnchor, constant: -16),
            stackView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor, constant: 8),

            footerLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            footerLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            footerLabel.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
            footerLabel.heightAnchor.constraint(equalToConstant: 20),
        ])

        self.view = container

        reloadGallery()

        // Subscribe to skin changes to update selection highlight
        SkinPackManager.shared.skinChanged
            .receive(on: RunLoop.main)
            .sink { [weak self] skin in
                self?.updateSelection(skinId: skin.manifest.id)
            }
            .store(in: &cancellables)
    }

    private func reloadGallery() {
        // Clear old views
        stackView.arrangedSubviews.forEach { $0.removeFromSuperview() }
        itemViews.removeAll()

        let activeSkinId = SkinPackManager.shared.activeSkin.manifest.id

        for skin in SkinPackManager.shared.availableSkins {
            let manifest = skin.manifest
            let itemView = SkinGalleryItemView(manifest: manifest)
            itemView.isSelectedSkin = manifest.id == activeSkinId
            itemView.translatesAutoresizingMaskIntoConstraints = false
            itemView.onClick = { [weak self] in
                SkinPackManager.shared.selectSkin(manifest.id)
                self?.updateSelection(skinId: manifest.id)
            }
            stackView.addArrangedSubview(itemView)
            itemView.widthAnchor.constraint(equalTo: stackView.widthAnchor).isActive = true
            itemViews[manifest.id] = itemView
        }
    }

    private func updateSelection(skinId: String) {
        for (id, view) in itemViews {
            view.isSelectedSkin = id == skinId
        }
    }
}
