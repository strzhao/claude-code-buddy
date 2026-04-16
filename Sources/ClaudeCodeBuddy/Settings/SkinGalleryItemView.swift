import AppKit

class SkinGalleryItemView: NSView {
    private let manifest: SkinPackManifest
    private let previewImageView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let authorLabel = NSTextField(labelWithString: "")
    var onClick: (() -> Void)?

    var isSelectedSkin: Bool = false { didSet { updateSelectionAppearance() } }

    init(manifest: SkinPackManifest) {
        self.manifest = manifest
        super.init(frame: NSRect(x: 0, y: 0, width: 300, height: 80))
        setupView()
        loadPreviewImage()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func setupView() {
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderColor = NSColor.controlAccentColor.cgColor

        // Preview image (60x60)
        previewImageView.imageScaling = .scaleProportionallyUpOrDown
        previewImageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(previewImageView)

        // Name label
        nameLabel.font = .boldSystemFont(ofSize: 13)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(nameLabel)

        // Author label
        authorLabel.font = .systemFont(ofSize: 11)
        authorLabel.textColor = .secondaryLabelColor
        authorLabel.lineBreakMode = .byTruncatingTail
        authorLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(authorLabel)

        NSLayoutConstraint.activate([
            // Card height
            heightAnchor.constraint(greaterThanOrEqualToConstant: 80),

            // Preview image: left side, centered vertically
            previewImageView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            previewImageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            previewImageView.widthAnchor.constraint(equalToConstant: 60),
            previewImageView.heightAnchor.constraint(equalToConstant: 60),

            // Name label: right of image
            nameLabel.leadingAnchor.constraint(equalTo: previewImageView.trailingAnchor, constant: 12),
            nameLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            nameLabel.bottomAnchor.constraint(equalTo: centerYAnchor, constant: -2),

            // Author label: below name
            authorLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            authorLabel.trailingAnchor.constraint(equalTo: nameLabel.trailingAnchor),
            authorLabel.topAnchor.constraint(equalTo: centerYAnchor, constant: 2),
        ])

        nameLabel.stringValue = manifest.name
        authorLabel.stringValue = manifest.author

        // Click gesture
        let click = NSClickGestureRecognizer(target: self, action: #selector(handleClick))
        addGestureRecognizer(click)

        updateSelectionAppearance()
    }

    private func loadPreviewImage() {
        let activeSkin = SkinPackManager.shared.activeSkin

        // Try previewImage from active skin first, then from the matching skin pack
        if let preview = manifest.previewImage {
            // Find the matching skin pack to load image from correct source
            if let pack = SkinPackManager.shared.availableSkins.first(where: { $0.manifest.id == manifest.id }) {
                let nameWithoutExt = (preview as NSString).deletingPathExtension
                let ext = (preview as NSString).pathExtension.isEmpty ? "png" : (preview as NSString).pathExtension
                if let url = pack.url(forResource: nameWithoutExt, withExtension: ext,
                                      subdirectory: manifest.spriteDirectory) {
                    if let image = NSImage(contentsOf: url) {
                        previewImageView.image = image
                        return
                    }
                }
            }
        }

        // Fallback: first idle frame (spritePrefix-idle-a-1.png)
        let fallbackName = "\(manifest.spritePrefix)-idle-a-1"
        if let pack = SkinPackManager.shared.availableSkins.first(where: { $0.manifest.id == manifest.id }),
           let url = pack.url(forResource: fallbackName, withExtension: "png",
                              subdirectory: manifest.spriteDirectory) {
            previewImageView.image = NSImage(contentsOf: url)
        } else {
            // Last resort: use active skin's idle frame
            if let url = activeSkin.url(forResource: "\(activeSkin.manifest.spritePrefix)-idle-a-1",
                                        withExtension: "png",
                                        subdirectory: activeSkin.manifest.spriteDirectory) {
                previewImageView.image = NSImage(contentsOf: url)
            }
        }
    }

    private func updateSelectionAppearance() {
        layer?.borderWidth = isSelectedSkin ? 2 : 0
        layer?.backgroundColor = isSelectedSkin
            ? NSColor.controlAccentColor.withAlphaComponent(0.08).cgColor
            : NSColor.clear.cgColor
    }

    @objc private func handleClick() {
        onClick?()
    }
}
