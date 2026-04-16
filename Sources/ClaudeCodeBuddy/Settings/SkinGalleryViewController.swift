import AppKit
import Combine

class SkinGalleryViewController: NSViewController {
    private let scrollView = NSScrollView()
    private let stackView = NSStackView()
    private var cancellables = Set<AnyCancellable>()
    private var itemViews: [String: SkinGalleryItemView] = [:]

    // MARK: - Store section

    private let storeStackView = NSStackView()
    private var remoteSkins: [RemoteSkinEntry] = []
    private var downloadingIds = Set<String>()

    /// Maps NSButton pointer → RemoteSkinEntry.id for download action routing.
    private var buttonEntryMap: [ObjectIdentifier: String] = [:]

    // Catalog URL — can be overridden for testing
    // swiftlint:disable:next force_unwrapping
    var catalogURL: URL = URL(string: "https://raw.githubusercontent.com/stringzhao/claude-code-buddy-skins/main/catalog.json")!

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 480))

        // Gallery stack view (vertical list of skin cards)
        stackView.orientation = .vertical
        stackView.spacing = 8
        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.alignment = .leading

        // Store section header
        let storeHeaderLabel = NSTextField(labelWithString: "Skin Store")
        storeHeaderLabel.font = .boldSystemFont(ofSize: 11)
        storeHeaderLabel.textColor = .secondaryLabelColor
        storeHeaderLabel.translatesAutoresizingMaskIntoConstraints = false

        // Store inner stack (cards for remote skins)
        storeStackView.orientation = .vertical
        storeStackView.spacing = 8
        storeStackView.translatesAutoresizingMaskIntoConstraints = false
        storeStackView.alignment = .leading

        // Outer stack combining gallery + store header + store list
        let outerStack = NSStackView(views: [stackView, storeHeaderLabel, storeStackView])
        outerStack.orientation = .vertical
        outerStack.spacing = 8
        outerStack.alignment = .leading
        outerStack.translatesAutoresizingMaskIntoConstraints = false

        scrollView.documentView = outerStack
        scrollView.hasVerticalScroller = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        container.addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),

            outerStack.widthAnchor.constraint(equalTo: scrollView.widthAnchor, constant: -16),
            outerStack.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor, constant: 8),

            stackView.widthAnchor.constraint(equalTo: outerStack.widthAnchor),
            storeHeaderLabel.widthAnchor.constraint(equalTo: outerStack.widthAnchor),
            storeStackView.widthAnchor.constraint(equalTo: outerStack.widthAnchor),
        ])

        self.view = container

        reloadGallery()
        reloadStoreSection()

        // Subscribe to active skin changes to update selection highlight
        SkinPackManager.shared.skinChanged
            .receive(on: RunLoop.main)
            .sink { [weak self] skin in
                self?.updateSelection(skinId: skin.manifest.id)
            }
            .store(in: &cancellables)

        // Subscribe to available skins list changes (downloads complete, etc.)
        SkinPackManager.shared.availableSkinsChanged
            .receive(on: RunLoop.main)
            .sink { [weak self] in
                self?.reloadGallery()
                self?.reloadStoreSection()
            }
            .store(in: &cancellables)

        // Trigger refresh of remote skins in background
        Task { await SkinPackManager.shared.refreshRemoteSkins() }
        fetchRemoteCatalog()
    }

    // MARK: - Gallery

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

    // MARK: - Store Section

    private func fetchRemoteCatalog() {
        Task { [weak self] in
            guard let self else { return }
            do {
                let entries = try await SkinPackManager.shared.store.fetchCatalog(from: catalogURL)
                await MainActor.run {
                    self.remoteSkins = entries
                    self.reloadStoreSection()
                }
            } catch {
                // Silently ignore catalog fetch failures (network may be unavailable)
            }
        }
    }

    private func reloadStoreSection() {
        // Clear button map entries that belong to old rows
        storeStackView.arrangedSubviews.forEach { $0.removeFromSuperview() }
        buttonEntryMap.removeAll()

        // Filter out already-installed skins
        let installedIds = Set(SkinPackManager.shared.availableSkins.map { $0.manifest.id })
        let available = remoteSkins.filter { !installedIds.contains($0.id) }

        if available.isEmpty && remoteSkins.isEmpty {
            // Show loading placeholder while catalog is being fetched
            let loadingLabel = NSTextField(labelWithString: "Loading store…")
            loadingLabel.font = .systemFont(ofSize: 11)
            loadingLabel.textColor = .tertiaryLabelColor
            loadingLabel.translatesAutoresizingMaskIntoConstraints = false
            storeStackView.addArrangedSubview(loadingLabel)
        } else if available.isEmpty {
            let doneLabel = NSTextField(labelWithString: "All available skins are installed.")
            doneLabel.font = .systemFont(ofSize: 11)
            doneLabel.textColor = .tertiaryLabelColor
            doneLabel.translatesAutoresizingMaskIntoConstraints = false
            storeStackView.addArrangedSubview(doneLabel)
        } else {
            for entry in available {
                let row = makeStoreRow(for: entry)
                storeStackView.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: storeStackView.widthAnchor).isActive = true
            }
        }
    }

    private func makeStoreRow(for entry: RemoteSkinEntry) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.wantsLayer = true
        row.layer?.cornerRadius = 8
        row.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor

        let nameLabel = NSTextField(labelWithString: entry.name)
        nameLabel.font = .boldSystemFont(ofSize: 13)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.translatesAutoresizingMaskIntoConstraints = false

        let authorLabel = NSTextField(labelWithString: entry.author)
        authorLabel.font = .systemFont(ofSize: 11)
        authorLabel.textColor = .secondaryLabelColor
        authorLabel.lineBreakMode = .byTruncatingTail
        authorLabel.translatesAutoresizingMaskIntoConstraints = false

        let downloadButton = NSButton(title: "Download", target: self, action: #selector(handleDownload(_:)))
        downloadButton.bezelStyle = .rounded
        downloadButton.translatesAutoresizingMaskIntoConstraints = false

        let progressIndicator = NSProgressIndicator()
        progressIndicator.style = .spinning
        progressIndicator.controlSize = .small
        progressIndicator.isIndeterminate = true
        progressIndicator.translatesAutoresizingMaskIntoConstraints = false
        progressIndicator.isHidden = true

        row.addSubview(nameLabel)
        row.addSubview(authorLabel)
        row.addSubview(downloadButton)
        row.addSubview(progressIndicator)

        // Register button → entryId mapping for action routing
        buttonEntryMap[ObjectIdentifier(downloadButton)] = entry.id

        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(greaterThanOrEqualToConstant: 64),

            nameLabel.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 12),
            nameLabel.trailingAnchor.constraint(equalTo: downloadButton.leadingAnchor, constant: -8),
            nameLabel.bottomAnchor.constraint(equalTo: row.centerYAnchor, constant: -2),

            authorLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            authorLabel.trailingAnchor.constraint(equalTo: nameLabel.trailingAnchor),
            authorLabel.topAnchor.constraint(equalTo: row.centerYAnchor, constant: 2),

            downloadButton.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -12),
            downloadButton.centerYAnchor.constraint(equalTo: row.centerYAnchor),

            progressIndicator.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -12),
            progressIndicator.centerYAnchor.constraint(equalTo: row.centerYAnchor),
        ])

        // If already downloading, show spinner
        if downloadingIds.contains(entry.id) {
            downloadButton.isHidden = true
            progressIndicator.isHidden = false
            progressIndicator.startAnimation(nil)
        }

        return row
    }

    @objc private func handleDownload(_ sender: NSButton) {
        guard let entryId = buttonEntryMap[ObjectIdentifier(sender)],
              let entry = remoteSkins.first(where: { $0.id == entryId }) else { return }

        guard !downloadingIds.contains(entryId) else { return }
        downloadingIds.insert(entryId)

        // Update UI: hide button, show spinner for this row
        sender.isHidden = true
        if let row = sender.superview,
           let indicator = row.subviews.first(where: { $0 is NSProgressIndicator }) as? NSProgressIndicator {
            indicator.isHidden = false
            indicator.startAnimation(nil)
        }

        Task { [weak self] in
            guard let self else { return }
            do {
                let skin = try await SkinPackManager.shared.store.downloadSkin(
                    entry: entry,
                    progress: { _ in }
                )
                await MainActor.run {
                    self.downloadingIds.remove(entryId)
                    SkinPackManager.shared.addDownloadedSkin(skin)
                    // reloadGallery/reloadStoreSection are triggered via availableSkinsChanged
                }
            } catch {
                await MainActor.run {
                    self.downloadingIds.remove(entryId)
                    // Restore button state
                    sender.isHidden = false
                    if let row = sender.superview,
                       let indicator = row.subviews.first(where: { $0 is NSProgressIndicator }) as? NSProgressIndicator {
                        indicator.stopAnimation(nil)
                        indicator.isHidden = true
                    }
                    // Show error as alert
                    let alert = NSAlert()
                    alert.messageText = "Download Failed"
                    alert.informativeText = error.localizedDescription
                    alert.alertStyle = .warning
                    alert.runModal()
                }
            }
        }
    }
}
