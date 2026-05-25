import AppKit
import Combine

class SkinGalleryViewController: NSViewController {

    private var collectionView: NSCollectionView!
    private let scrollView = NSScrollView()
    private var cancellables = Set<AnyCancellable>()

    // Data source: installed skins + store skins (mixed)
    private var installedSkins: [SkinPack] = []
    private var remoteSkins: [RemoteSkinEntry] = []
    private var downloadingIds = Set<String>()

    // Sound toggle
    private let soundSwitch = NSSwitch()
    private let soundLabel = NSTextField(labelWithString: "Sound Effects")

    // Always Show Label toggle
    private let alwaysShowLabelSwitch = NSSwitch()
    private let alwaysShowLabelLabel = NSTextField(labelWithString: "Always Show Label")

    // Catalog URL — can be overridden for testing
    // swiftlint:disable:next force_unwrapping
    var catalogURL: URL = URL(string: "https://buddy.stringzhao.life/api/skins")!

    // MARK: - Computed data

    /// Store entries not yet installed
    private var availableRemoteSkins: [RemoteSkinEntry] {
        let installedIds = Set(installedSkins.map { $0.manifest.id })
        return remoteSkins.filter { !installedIds.contains($0.id) }
    }

    /// Total items: installed + available remote
    private var totalItemCount: Int {
        installedSkins.count + availableRemoteSkins.count
    }

    // MARK: - Lifecycle

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 580, height: 480))

        setupCollectionView(in: container)
        setupSoundToggle(in: container)
        setupAlwaysShowLabelToggle(in: container)

        self.view = container

        reloadData()
        subscribeToChanges()
        fetchRemoteCatalog()
    }

    // MARK: - Setup

    private func setupCollectionView(in container: NSView) {
        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = NSSize(width: 170, height: 224)
        layout.minimumInteritemSpacing = 12
        layout.minimumLineSpacing = 12
        layout.sectionInset = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)

        collectionView = NSCollectionView(frame: NSRect(x: 0, y: 0, width: 580, height: 440))
        collectionView.collectionViewLayout = layout
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.backgroundColors = [.clear]
        collectionView.isSelectable = false
        collectionView.register(SkinCardItem.self, forItemWithIdentifier: SkinCardItem.identifier)

        scrollView.documentView = collectionView
        scrollView.hasVerticalScroller = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        container.addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -56),
        ])
    }

    private func setupSoundToggle(in container: NSView) {
        soundLabel.font = .systemFont(ofSize: 13)
        soundLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(soundLabel)

        soundSwitch.target = self
        soundSwitch.action = #selector(soundToggleChanged)
        soundSwitch.state = SoundManager.shared.isEnabled ? .on : .off
        soundSwitch.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(soundSwitch)

        NSLayoutConstraint.activate([
            soundLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            soundLabel.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -32),

            soundSwitch.leadingAnchor.constraint(equalTo: soundLabel.trailingAnchor, constant: 8),
            soundSwitch.centerYAnchor.constraint(equalTo: soundLabel.centerYAnchor),
        ])
    }

    private func setupAlwaysShowLabelToggle(in container: NSView) {
        alwaysShowLabelLabel.font = .systemFont(ofSize: 13)
        alwaysShowLabelLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(alwaysShowLabelLabel)

        alwaysShowLabelSwitch.target = self
        alwaysShowLabelSwitch.action = #selector(alwaysShowLabelToggleChanged)
        alwaysShowLabelSwitch.state = UserDefaults.standard.bool(forKey: "alwaysShowLabel") ? .on : .off
        alwaysShowLabelSwitch.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(alwaysShowLabelSwitch)

        NSLayoutConstraint.activate([
            alwaysShowLabelLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            alwaysShowLabelLabel.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -10),

            alwaysShowLabelSwitch.leadingAnchor.constraint(equalTo: alwaysShowLabelLabel.trailingAnchor, constant: 8),
            alwaysShowLabelSwitch.centerYAnchor.constraint(equalTo: alwaysShowLabelLabel.centerYAnchor),
        ])
    }

    private func subscribeToChanges() {
        SkinPackManager.shared.skinChanged
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.collectionView.reloadData()
            }
            .store(in: &cancellables)

        SkinPackManager.shared.availableSkinsChanged
            .receive(on: RunLoop.main)
            .sink { [weak self] in
                self?.reloadData()
            }
            .store(in: &cancellables)
    }

    // MARK: - Data

    private func reloadData() {
        installedSkins = SkinPackManager.shared.availableSkins
        collectionView.reloadData()
    }

    private func fetchRemoteCatalog() {
        Task { [weak self] in
            guard let self else { return }
            do {
                let entries = try await SkinPackManager.shared.store.fetchCatalog(from: self.catalogURL)
                await MainActor.run {
                    self.remoteSkins = entries
                    self.collectionView.reloadData()
                }
            } catch {
                // Silently ignore catalog fetch failures
            }
        }
    }

    // MARK: - Click Handling (called from SettingsPanel.sendEvent)

    func handleClickAt(windowPoint: NSPoint) {
        let cvPoint = collectionView.convert(windowPoint, from: nil)
        guard let indexPath = collectionView.indexPathForItem(at: cvPoint) else { return }

        let index = indexPath.item

        // Check if click landed on an interactive control inside the card
        if let item = collectionView.item(at: indexPath) {
            let viewPoint = item.view.convert(windowPoint, from: nil)
            if let hitView = item.view.hitTest(viewPoint),
               hitView is NSButton || hitView is NSSegmentedControl {
                return // Let the control handle it via its own target/action
            }
        }

        if index < installedSkins.count {
            let skin = installedSkins[index]
            // Immediately update card highlights
            for i in 0..<installedSkins.count {
                let ip = IndexPath(item: i, section: 0)
                (collectionView.item(at: ip) as? SkinCardItem)?.isSelectedSkin = (i == index)
            }
            SkinPackManager.shared.selectSkin(skin.manifest.id)
        } else {
            let remoteIndex = index - installedSkins.count
            let available = availableRemoteSkins
            guard remoteIndex < available.count else { return }
            let entry = available[remoteIndex]
            if !downloadingIds.contains(entry.id) {
                downloadSkin(entry: entry, at: indexPath)
            }
        }
    }

    @objc private func soundToggleChanged(_ sender: NSSwitch) {
        SoundManager.shared.isEnabled = sender.state == .on
    }

    @objc private func alwaysShowLabelToggleChanged(_ sender: NSSwitch) {
        UserDefaults.standard.set(sender.state == .on, forKey: "alwaysShowLabel")
    }

    private func downloadSkin(entry: RemoteSkinEntry, at indexPath: IndexPath) {
        guard !downloadingIds.contains(entry.id) else { return }
        downloadingIds.insert(entry.id)

        // Update the specific cell
        if let item = collectionView.item(at: indexPath) as? SkinCardItem {
            item.isDownloading = true
        }

        Task { [weak self] in
            guard let self else { return }
            do {
                let skin = try await SkinPackManager.shared.store.downloadSkin(
                    entry: entry,
                    progress: { _ in }
                )
                await MainActor.run {
                    self.downloadingIds.remove(entry.id)
                    SkinPackManager.shared.addDownloadedSkin(skin)
                }
            } catch {
                await MainActor.run {
                    self.downloadingIds.remove(entry.id)
                    self.collectionView.reloadData()
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

// MARK: - NSCollectionViewDataSource

extension SkinGalleryViewController: NSCollectionViewDataSource {
    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        totalItemCount
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        itemForRepresentedObjectAt indexPath: IndexPath
    ) -> NSCollectionViewItem {
        let item = collectionView.makeItem(
            withIdentifier: SkinCardItem.identifier,
            for: indexPath
        )
        guard let cardItem = item as? SkinCardItem else { return item }

        let activeSkinId = SkinPackManager.shared.activeSkin.manifest.id
        let index = indexPath.item

        if index < installedSkins.count {
            // Installed skin
            let skin = installedSkins[index]
            cardItem.configure(manifest: skin.manifest, skin: skin)
            cardItem.isInstalled = true
            cardItem.isSelectedSkin = skin.manifest.id == activeSkinId
            cardItem.isDownloading = false
        } else {
            // Remote skin (not yet installed)
            let remoteIndex = index - installedSkins.count
            let available = availableRemoteSkins
            guard remoteIndex < available.count else { return cardItem }
            let entry = available[remoteIndex]

            let manifest = SkinPackManifest(
                id: entry.id,
                name: entry.name,
                author: entry.author,
                version: entry.version,
                previewImage: nil,
                spritePrefix: "cat",
                animationNames: [],
                canvasSize: [48, 48],
                bedNames: [],
                boundarySprite: "",
                foodNames: [],
                foodDirectory: "",
                spriteDirectory: "",
                menuBar: MenuBarConfig(
                    walkPrefix: "", walkFrameCount: 0,
                    runPrefix: "", runFrameCount: 0,
                    idleFrame: "", directory: ""
                ),
                sounds: nil,
                variants: nil,
                spriteFacesRight: nil
            )
            cardItem.configure(manifest: manifest, skin: nil)
            cardItem.isInstalled = false
            cardItem.isSelectedSkin = false
            cardItem.isDownloading = downloadingIds.contains(entry.id)
            cardItem.onDownload = { [weak self] in
                self?.downloadSkin(entry: entry, at: indexPath)
            }
        }

        return cardItem
    }
}

// MARK: - NSCollectionViewDelegateFlowLayout

extension SkinGalleryViewController: NSCollectionViewDelegateFlowLayout {}
