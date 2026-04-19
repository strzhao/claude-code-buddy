import AppKit

// MARK: - SkinCardItem

class SkinCardItem: NSCollectionViewItem {

    static let identifier = NSUserInterfaceItemIdentifier("SkinCardItem")

    private let previewImageView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let authorLabel = NSTextField(labelWithString: "")
    private let checkmarkBadge = NSTextField(labelWithString: "\u{2713}")
    private let downloadButton = NSButton(title: "Download", target: nil, action: nil)
    private let progressIndicator = NSProgressIndicator()
    private let variantControl = NSSegmentedControl()
    private let variantBadge = NSTextField(labelWithString: "")

    private var variants: [SkinVariant] = []
    private var skinId: String = ""

    var onSelect: (() -> Void)?
    var onDownload: (() -> Void)?

    var isSelectedSkin: Bool = false {
        didSet {
            updateSelectionAppearance()
            updateVariantControl()
        }
    }

    var isDownloading: Bool = false {
        didSet {
            downloadButton.isHidden = isDownloading || isInstalled
            progressIndicator.isHidden = !isDownloading
            if isDownloading {
                progressIndicator.startAnimation(nil)
            } else {
                progressIndicator.stopAnimation(nil)
            }
        }
    }

    var isInstalled: Bool = true {
        didSet {
            downloadButton.isHidden = isInstalled || isDownloading
        }
    }

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 170, height: 224))
        container.wantsLayer = true
        container.layer?.cornerRadius = 10
        container.layer?.borderColor = NSColor.controlAccentColor.cgColor

        // Preview image (120x120, pixel art nearest filtering)
        previewImageView.imageScaling = .scaleProportionallyUpOrDown
        previewImageView.wantsLayer = true
        previewImageView.layer?.magnificationFilter = .nearest
        previewImageView.layer?.minificationFilter = .nearest
        previewImageView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(previewImageView)

        // Name label
        nameLabel.font = .boldSystemFont(ofSize: 13)
        nameLabel.alignment = .center
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.maximumNumberOfLines = 1
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(nameLabel)

        // Author label
        authorLabel.font = .systemFont(ofSize: 11)
        authorLabel.textColor = .secondaryLabelColor
        authorLabel.alignment = .center
        authorLabel.lineBreakMode = .byTruncatingTail
        authorLabel.maximumNumberOfLines = 1
        authorLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(authorLabel)

        // Variant badge (e.g., "12 colors") — shown for non-selected cards with variants
        variantBadge.font = .systemFont(ofSize: 10)
        variantBadge.textColor = .tertiaryLabelColor
        variantBadge.alignment = .center
        variantBadge.isBezeled = false
        variantBadge.isEditable = false
        variantBadge.translatesAutoresizingMaskIntoConstraints = false
        variantBadge.isHidden = true
        container.addSubview(variantBadge)

        // Variant segmented control — shown only for selected card with variants
        variantControl.segmentStyle = .capsule
        variantControl.controlSize = .small
        variantControl.target = self
        variantControl.action = #selector(variantChanged(_:))
        variantControl.translatesAutoresizingMaskIntoConstraints = false
        variantControl.isHidden = true
        container.addSubview(variantControl)

        // Checkmark badge
        checkmarkBadge.font = .boldSystemFont(ofSize: 16)
        checkmarkBadge.textColor = .white
        checkmarkBadge.backgroundColor = .controlAccentColor
        checkmarkBadge.drawsBackground = true
        checkmarkBadge.alignment = .center
        checkmarkBadge.isBezeled = false
        checkmarkBadge.isEditable = false
        checkmarkBadge.wantsLayer = true
        checkmarkBadge.layer?.cornerRadius = 10
        checkmarkBadge.translatesAutoresizingMaskIntoConstraints = false
        checkmarkBadge.isHidden = true
        container.addSubview(checkmarkBadge)

        // Download button
        downloadButton.bezelStyle = .rounded
        downloadButton.target = self
        downloadButton.action = #selector(handleDownload)
        downloadButton.translatesAutoresizingMaskIntoConstraints = false
        downloadButton.isHidden = true
        container.addSubview(downloadButton)

        // Progress indicator
        progressIndicator.style = .spinning
        progressIndicator.controlSize = .small
        progressIndicator.isIndeterminate = true
        progressIndicator.translatesAutoresizingMaskIntoConstraints = false
        progressIndicator.isHidden = true
        container.addSubview(progressIndicator)

        NSLayoutConstraint.activate([
            // Preview image: centered at top
            previewImageView.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
            previewImageView.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            previewImageView.widthAnchor.constraint(equalToConstant: 120),
            previewImageView.heightAnchor.constraint(equalToConstant: 120),

            // Name: below preview
            nameLabel.topAnchor.constraint(equalTo: previewImageView.bottomAnchor, constant: 8),
            nameLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            nameLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),

            // Author: below name
            authorLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 2),
            authorLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            authorLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),

            // Variant badge: below author
            variantBadge.topAnchor.constraint(equalTo: authorLabel.bottomAnchor, constant: 2),
            variantBadge.centerXAnchor.constraint(equalTo: container.centerXAnchor),

            // Variant control: below author (same position as badge, mutually exclusive)
            variantControl.topAnchor.constraint(equalTo: authorLabel.bottomAnchor, constant: 4),
            variantControl.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 4),
            variantControl.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -4),
            variantControl.heightAnchor.constraint(equalToConstant: 20),

            // Checkmark badge: top-right corner
            checkmarkBadge.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            checkmarkBadge.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            checkmarkBadge.widthAnchor.constraint(equalToConstant: 20),
            checkmarkBadge.heightAnchor.constraint(equalToConstant: 20),

            // Download button: center of preview area
            downloadButton.centerXAnchor.constraint(equalTo: previewImageView.centerXAnchor),
            downloadButton.centerYAnchor.constraint(equalTo: previewImageView.centerYAnchor),

            // Progress indicator: same position as download button
            progressIndicator.centerXAnchor.constraint(equalTo: previewImageView.centerXAnchor),
            progressIndicator.centerYAnchor.constraint(equalTo: previewImageView.centerYAnchor),
        ])

        self.view = container
    }

    func configure(manifest: SkinPackManifest, skin: SkinPack?) {
        nameLabel.stringValue = manifest.name
        authorLabel.stringValue = manifest.author
        self.variants = manifest.variants ?? []
        self.skinId = manifest.id
        loadPreviewImage(manifest: manifest, skin: skin)
        updateVariantControl()
    }

    private func loadPreviewImage(manifest: SkinPackManifest, skin: SkinPack?) {
        let pack = skin ?? SkinPackManager.shared.activeSkin

        // Use effective preview image (variant-aware)
        let previewFile = skin?.effectivePreviewImage ?? manifest.previewImage
        if let preview = previewFile {
            let nameWithoutExt = (preview as NSString).deletingPathExtension
            let ext = (preview as NSString).pathExtension.isEmpty ? "png" : (preview as NSString).pathExtension
            if let url = pack.url(forResource: nameWithoutExt, withExtension: ext,
                                  subdirectory: manifest.spriteDirectory),
               let image = NSImage(contentsOf: url) {
                previewImageView.image = image
                return
            }
        }

        // Fallback: first idle frame
        let prefix = skin?.effectiveSpritePrefix ?? manifest.spritePrefix
        let fallbackName = "\(prefix)-idle-a-1"
        if let url = pack.url(forResource: fallbackName, withExtension: "png",
                              subdirectory: manifest.spriteDirectory) {
            previewImageView.image = NSImage(contentsOf: url)
        }
    }

    private func updateVariantControl() {
        let hasVariants = !variants.isEmpty

        if hasVariants && isSelectedSkin && isInstalled {
            // Show segmented control for selected card with variants
            variantControl.isHidden = false
            variantBadge.isHidden = true
            variantControl.segmentCount = variants.count + 1
            variantControl.setLabel("\u{1F3B2}", forSegment: 0) // dice emoji for random
            variantControl.setWidth(28, forSegment: 0)
            for (i, variant) in variants.enumerated() {
                variantControl.setLabel(variant.name, forSegment: i + 1)
                variantControl.setWidth(0, forSegment: i + 1) // auto-size
            }
            // Select the current preference
            let pref = SkinPackManager.shared.variantPreference(for: skinId)
            if pref == nil || pref == SkinPackManager.randomVariantSentinel {
                variantControl.selectedSegment = 0
            } else if let idx = variants.firstIndex(where: { $0.id == pref }) {
                variantControl.selectedSegment = idx + 1
            }
        } else if hasVariants && !isSelectedSkin {
            // Show variant count badge for non-selected cards
            variantControl.isHidden = true
            variantBadge.isHidden = false
            variantBadge.stringValue = "\(variants.count) colors"
        } else {
            variantControl.isHidden = true
            variantBadge.isHidden = true
        }
    }

    @objc private func variantChanged(_ sender: NSSegmentedControl) {
        let segment = sender.selectedSegment
        if segment == 0 {
            SkinPackManager.shared.selectVariant(nil, for: skinId)
        } else {
            let variant = variants[segment - 1]
            SkinPackManager.shared.selectVariant(variant.id, for: skinId)
        }
    }

    private func updateSelectionAppearance() {
        view.layer?.borderWidth = isSelectedSkin ? 2.5 : 0
        view.layer?.backgroundColor = isSelectedSkin
            ? NSColor.controlAccentColor.withAlphaComponent(0.08).cgColor
            : NSColor.controlBackgroundColor.cgColor
        checkmarkBadge.isHidden = !isSelectedSkin
    }

    @objc private func handleDownload() {
        onDownload?()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        previewImageView.image = nil
        nameLabel.stringValue = ""
        authorLabel.stringValue = ""
        isSelectedSkin = false
        isInstalled = true
        isDownloading = false
        onSelect = nil
        onDownload = nil
        variants = []
        skinId = ""
        variantControl.isHidden = true
        variantBadge.isHidden = true
    }
}
