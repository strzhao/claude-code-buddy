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

    // Entity mode segmented control (placed under Sound Effects; changing it
    // triggers a full app relaunch via EventBus.relaunchRequested — this is
    // deliberate: rapid in-process hot-switches between cat / rocket modes
    // surfaced subtle state-machine races, so we play the exit animation
    // and restart the process instead).
    private let modeLabel = NSTextField(labelWithString: "Entity")
    private let modeSegment = NSSegmentedControl(
        labels: ["🐱 Cat", "🚀 Rocket"],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )

    // Reset button — relaunches the app without touching the persisted mode.
    // Handy escape hatch if a UI animation / scene state gets wedged.
    private let resetButton = NSButton(title: "Reset", target: nil, action: nil)

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
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 580, height: 520))

        setupCollectionView(in: container)
        setupBottomBar(in: container)

        self.view = container

        reloadData()
        subscribeToChanges()
        fetchRemoteCatalog()
    }

    // MARK: - Setup

    private func setupCollectionView(in container: NSView) {
        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = NSSize(width: 170, height: 200)
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
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -80),
        ])
    }

    private func setupBottomBar(in container: NSView) {
        // Row 1 — Sound Effects (top of bottom bar)
        soundLabel.font = .systemFont(ofSize: 13)
        soundLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(soundLabel)

        soundSwitch.target = self
        soundSwitch.action = #selector(soundToggleChanged)
        soundSwitch.state = SoundManager.shared.isEnabled ? .on : .off
        soundSwitch.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(soundSwitch)

        // Row 2 — Entity mode segment + Reset (sits under Sound Effects)
        modeLabel.font = .systemFont(ofSize: 13)
        modeLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(modeLabel)

        modeSegment.target = self
        modeSegment.action = #selector(modeSegmentChanged(_:))
        modeSegment.selectedSegment = EntityModeStore.shared.current == .cat ? 0 : 1
        modeSegment.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(modeSegment)

        // Keep the segment visually in sync with the persisted mode (e.g.
        // the app's first boot writes a default value).
        EntityModeStore.shared.publisher
            .receive(on: RunLoop.main)
            .sink { [weak self] mode in
                self?.modeSegment.selectedSegment = mode == .cat ? 0 : 1
            }
            .store(in: &cancellables)

        resetButton.target = self
        resetButton.action = #selector(resetClicked)
        resetButton.bezelStyle = .rounded
        resetButton.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(resetButton)

        NSLayoutConstraint.activate([
            // Row 1 — Sound
            soundLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            soundLabel.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -50),

            soundSwitch.leadingAnchor.constraint(equalTo: soundLabel.trailingAnchor, constant: 8),
            soundSwitch.centerYAnchor.constraint(equalTo: soundLabel.centerYAnchor),

            // Row 2 — Mode + Reset
            modeLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            modeLabel.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -14),

            modeSegment.leadingAnchor.constraint(equalTo: modeLabel.trailingAnchor, constant: 8),
            modeSegment.centerYAnchor.constraint(equalTo: modeLabel.centerYAnchor),

            resetButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            resetButton.centerYAnchor.constraint(equalTo: modeLabel.centerYAnchor),
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

    // MARK: - Actions

    @objc private func soundToggleChanged(_ sender: NSSwitch) {
        SoundManager.shared.isEnabled = sender.state == .on
    }

    @objc private func modeSegmentChanged(_ sender: NSSegmentedControl) {
        let newMode: EntityMode = sender.selectedSegment == 0 ? .cat : .rocket
        guard EntityModeStore.shared.current != newMode else { return }
        EventBus.shared.relaunchRequested.send(newMode)
    }

    @objc private func resetClicked() {
        EventBus.shared.relaunchRequested.send(nil)
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
            cardItem.onSelect = {
                SkinPackManager.shared.selectSkin(skin.manifest.id)
            }
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
                sounds: nil
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
