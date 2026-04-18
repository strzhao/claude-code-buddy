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

    /// Fires whenever the available skins list changes (skin added or removed).
    let availableSkinsChanged = PassthroughSubject<Void, Never>()

    /// Reference to the remote skin store.
    let store = SkinPackStore.shared

    // MARK: - Constants

    private static let selectedSkinIdKey = "selectedSkinId"

    /// Sentinel value stored in UserDefaults to indicate "random variant each launch".
    static let randomVariantSentinel = "__random__"

    static let localSkinsDirectory: URL = {
        // swiftlint:disable:next force_unwrapping
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("ClaudeCodeBuddy/Skins", isDirectory: true)
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

    // MARK: - Skin Selection

    /// Selects a skin by ID.
    ///
    /// If the ID is not found in `availableSkins`, the call is a no-op.
    /// On success the selection is persisted to `UserDefaults` and `skinChanged` fires.
    func selectSkin(_ skinId: String) {
        NSLog("[SkinPackManager] selectSkin called: \(skinId)")
        guard var skin = availableSkins.first(where: { $0.manifest.id == skinId }) else {
            NSLog("[SkinPackManager] skin not found in availableSkins!")
            return
        }
        let storedVariant = UserDefaults.standard.string(forKey: Self.variantKey(for: skinId))
        skin.selectedVariantId = resolveVariantId(storedVariant, for: skin.manifest)
        activeSkin = skin
        UserDefaults.standard.set(skinId, forKey: Self.selectedSkinIdKey)
        skinChanged.send(skin)
    }

    // MARK: - Variant Selection

    /// Returns the UserDefaults key for the variant preference of a given skin.
    private static func variantKey(for skinId: String) -> String {
        "selectedVariant:\(skinId)"
    }

    /// Select a specific variant for a skin. Pass `nil` for "random" behavior.
    func selectVariant(_ variantId: String?, for skinId: String) {
        let key = Self.variantKey(for: skinId)
        let valueToStore = variantId ?? Self.randomVariantSentinel
        UserDefaults.standard.set(valueToStore, forKey: key)

        // If this is the active skin, update it and notify
        if activeSkin.manifest.id == skinId {
            let resolved = resolveVariantId(valueToStore, for: activeSkin.manifest)
            activeSkin.selectedVariantId = resolved
            skinChanged.send(activeSkin)
        }
    }

    /// Returns the raw preference for a skin (may be `__random__` or a specific ID).
    func variantPreference(for skinId: String) -> String? {
        UserDefaults.standard.string(forKey: Self.variantKey(for: skinId))
    }

    /// Resolve the stored variant preference to a concrete variant ID.
    /// If stored value is `__random__` or nil, pick a random variant.
    private func resolveVariantId(_ stored: String?, for manifest: SkinPackManifest) -> String? {
        guard manifest.hasVariants, let variants = manifest.variants, !variants.isEmpty else {
            return nil
        }
        if stored == nil || stored == Self.randomVariantSentinel {
            return variants.randomElement()?.id
        }
        // Verify the stored ID still exists in the manifest
        if variants.contains(where: { $0.id == stored }) {
            return stored
        }
        // Fallback: random
        return variants.randomElement()?.id
    }

    // MARK: - Local Skin Loading

    /// Scans the local skins directory and appends any valid skin packs to `availableSkins`.
    ///
    /// Each subdirectory that contains a valid `manifest.json` is loaded as a skin pack.
    /// Packs whose `id` clashes with an already-known skin are silently skipped.
    func loadLocalSkins() {
        let skinsDir = Self.localSkinsDirectory

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

    /// Adds a newly downloaded skin pack to `availableSkins` if its ID does not conflict.
    ///
    /// Fires `availableSkinsChanged` after appending.
    func addDownloadedSkin(_ skin: SkinPack) {
        guard !availableSkins.contains(where: { $0.manifest.id == skin.manifest.id }) else { return }
        availableSkins.append(skin)
        availableSkinsChanged.send()
    }

    /// Fetches the remote catalog and triggers `availableSkinsChanged` so the gallery can refresh.
    ///
    /// Call this once on launch and when the user opens the store section.
    func refreshRemoteSkins() async {
        // No-op if no catalog URL is configured; the gallery drives the URL.
        // This method exists as a hook for future preloading or refresh triggers.
        availableSkinsChanged.send()
    }

    // MARK: - Private Helpers

    private func restoreSelection() {
        guard let savedId = UserDefaults.standard.string(forKey: Self.selectedSkinIdKey),
              var skin = availableSkins.first(where: { $0.manifest.id == savedId }) else {
            return
        }
        let storedVariant = UserDefaults.standard.string(forKey: Self.variantKey(for: savedId))
        skin.selectedVariantId = resolveVariantId(storedVariant, for: skin.manifest)
        activeSkin = skin
    }
}
