import AppKit

class SkinCardItem: NSCollectionViewItem {

    static let identifier = NSUserInterfaceItemIdentifier("SkinCardItem")

    private let previewImageView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let authorLabel = NSTextField(labelWithString: "")
    private let checkmarkBadge = NSTextField(labelWithString: "\u{2713}")
    private let downloadButton = NSButton(title: "Download", target: nil, action: nil)
    private let progressIndicator = NSProgressIndicator()

    var onSelect: (() -> Void)?
    var onDownload: (() -> Void)?

    var isSelectedSkin: Bool = false { didSet { updateSelectionAppearance() } }

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
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 170, height: 200))
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

        // Click gesture for selecting installed skins
        let click = NSClickGestureRecognizer(target: self, action: #selector(handleClick))
        container.addGestureRecognizer(click)

        self.view = container
    }

    func configure(manifest: SkinPackManifest, skin: SkinPack?) {
        nameLabel.stringValue = manifest.name
        authorLabel.stringValue = manifest.author
        loadPreviewImage(manifest: manifest, skin: skin)
    }

    private func loadPreviewImage(manifest: SkinPackManifest, skin: SkinPack?) {
        let pack = skin ?? SkinPackManager.shared.activeSkin

        if let preview = manifest.previewImage {
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
        let fallbackName = "\(manifest.spritePrefix)-idle-a-1"
        if let url = pack.url(forResource: fallbackName, withExtension: "png",
                              subdirectory: manifest.spriteDirectory) {
            previewImageView.image = NSImage(contentsOf: url)
        }
    }

    private func updateSelectionAppearance() {
        view.layer?.borderWidth = isSelectedSkin ? 2.5 : 0
        view.layer?.backgroundColor = isSelectedSkin
            ? NSColor.controlAccentColor.withAlphaComponent(0.08).cgColor
            : NSColor.controlBackgroundColor.cgColor
        checkmarkBadge.isHidden = !isSelectedSkin
    }

    @objc private func handleClick() {
        guard isInstalled, !isDownloading else { return }
        onSelect?()
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
    }
}
