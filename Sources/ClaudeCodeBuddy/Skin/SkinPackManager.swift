import Foundation
import Combine

// MARK: - SkinPackManager

/// Manages available skin packs and the active selection.
///
/// - Singleton accessed via `SkinPackManager.shared`.
/// - Publishes `skinChanged` when the active skin switches.
/// - Persists selection in `UserDefaults` under key `"selectedSkinId"`.
/// - Scans `~/Library/Application Support/ClaudeCodeBuddy/Skins/` for local skin packs.
final class SkinPackManager {

    // MARK: - Shared Instance

    static let shared = SkinPackManager()

    // MARK: - Public Properties

    /// The currently active skin pack.
    private(set) var activeSkin: SkinPack

    /// All available skin packs (built-in first, then local).
    private(set) var availableSkins: [SkinPack]

    /// Fires whenever the active skin changes via `selectSkin(_:)`.
    let skinChanged = PassthroughSubject<SkinPack, Never>()

    // MARK: - Private

    private static let selectedSkinIdKey = "selectedSkinId"

    private static let localSkinsDirectory: URL? = {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("ClaudeCodeBuddy/Skins", isDirectory: true)
    }()

    // MARK: - Init

    private init() {
        let builtIn = SkinPack(
            manifest: DefaultSkinManifest.manifest,
            source: .builtIn(ResourceBundle.bundle)
        )
        activeSkin = builtIn
        availableSkins = [builtIn]
        loadLocalSkins()
        restoreSelection()
    }

    // MARK: - Public API

    /// Selects a skin by ID.
    ///
    /// If the ID is not found in `availableSkins`, the call is a no-op.
    /// On success the selection is persisted to `UserDefaults` and `skinChanged` fires.
    func selectSkin(_ skinId: String) {
        guard let skin = availableSkins.first(where: { $0.manifest.id == skinId }) else { return }
        activeSkin = skin
        UserDefaults.standard.set(skinId, forKey: Self.selectedSkinIdKey)
        skinChanged.send(skin)
    }

    /// Scans the local skins directory and appends any valid skin packs to `availableSkins`.
    ///
    /// Each subdirectory that contains a valid `manifest.json` is loaded as a skin pack.
    /// Packs whose `id` clashes with an already-known skin are silently skipped.
    func loadLocalSkins() {
        guard let skinsDir = Self.localSkinsDirectory else { return }

        let fm = FileManager.default
        guard fm.fileExists(atPath: skinsDir.path) else { return }

        let subdirs: [URL]
        do {
            subdirs = try fm.contentsOfDirectory(
                at: skinsDir,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            return
        }

        for dir in subdirs {
            // Only process directories
            guard (try? dir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else {
                continue
            }

            let manifestURL = dir.appendingPathComponent("manifest.json")
            guard fm.fileExists(atPath: manifestURL.path),
                  let data = try? Data(contentsOf: manifestURL),
                  let manifest = try? JSONDecoder().decode(SkinPackManifest.self, from: data) else {
                continue
            }

            // Skip if we already have a skin with this ID
            guard !availableSkins.contains(where: { $0.manifest.id == manifest.id }) else { continue }

            let pack = SkinPack(manifest: manifest, source: .local(dir))
            availableSkins.append(pack)
        }
    }

    // MARK: - Private Helpers

    private func restoreSelection() {
        guard let savedId = UserDefaults.standard.string(forKey: Self.selectedSkinIdKey),
              let skin = availableSkins.first(where: { $0.manifest.id == savedId }) else {
            return
        }
        activeSkin = skin
    }
}
