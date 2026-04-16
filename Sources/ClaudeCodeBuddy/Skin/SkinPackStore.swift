import Foundation

// MARK: - RemoteSkinEntry

struct RemoteSkinEntry: Codable {
    let id: String
    let name: String
    let author: String
    let version: String
    let previewURL: String?
    let downloadURL: String
    let size: Int

    enum CodingKeys: String, CodingKey {
        case id, name, author, version, size
        case previewURL = "preview_url"
        case downloadURL = "download_url"
    }
}

// MARK: - SkinPackStore

class SkinPackStore {
    static let shared = SkinPackStore()

    enum StoreError: Error {
        case invalidURL
        case downloadFailed
        case extractionFailed
        case pathTraversal
        case invalidManifest
        case missingSprites
    }

    private static var cacheDirectory: URL {
        // ~/Library/Application Support/ClaudeCodeBuddy/StoreCache/
        // swiftlint:disable:next force_unwrapping
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("ClaudeCodeBuddy/StoreCache")
    }

    private static let catalogCacheTTL: TimeInterval = 3600 // 1 hour
    private static let catalogCacheKey = "skinStoreCatalogCacheDate"

    // MARK: - Fetch Catalog

    func fetchCatalog(from url: URL) async throws -> [RemoteSkinEntry] {
        // Check cache first
        if let cached = loadCachedCatalog() { return cached }

        let (data, _) = try await URLSession.shared.data(from: url)
        let entries = try JSONDecoder().decode([RemoteSkinEntry].self, from: data)

        // Cache to disk
        saveCatalogCache(data)
        return entries
    }

    // MARK: - Download Skin

    func downloadSkin(
        entry: RemoteSkinEntry,
        progress: @escaping (Double) -> Void
    ) async throws -> SkinPack {
        guard let downloadURL = URL(string: entry.downloadURL) else {
            throw StoreError.invalidURL
        }

        // Download .zip to temp
        let (tempURL, _) = try await URLSession.shared.download(from: downloadURL)

        // Extract to Skins/{id}/
        let skinsDir = SkinPackManager.localSkinsDirectory
        let targetDir = skinsDir.appendingPathComponent(entry.id)

        // Clean existing if any
        try? FileManager.default.removeItem(at: targetDir)
        try FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)

        // Use Process to run unzip (macOS built-in)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-o", tempURL.path, "-d", targetDir.path]
        process.standardOutput = nil
        process.standardError = nil
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            try? FileManager.default.removeItem(at: targetDir)
            throw StoreError.extractionFailed
        }

        // Path traversal check — verify no files escaped targetDir
        try validateNoPathTraversal(in: targetDir)

        // Validate manifest.json
        let manifestURL = targetDir.appendingPathComponent("manifest.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            try? FileManager.default.removeItem(at: targetDir)
            throw StoreError.invalidManifest
        }

        let manifestData = try Data(contentsOf: manifestURL)
        let manifest: SkinPackManifest
        do {
            manifest = try JSONDecoder().decode(SkinPackManifest.self, from: manifestData)
        } catch {
            try? FileManager.default.removeItem(at: targetDir)
            throw StoreError.invalidManifest
        }

        // Validate at least 1 sprite exists
        let firstSprite = targetDir
            .appendingPathComponent(manifest.spriteDirectory)
            .appendingPathComponent("\(manifest.spritePrefix)-idle-a-1.png")
        guard FileManager.default.fileExists(atPath: firstSprite.path) else {
            try? FileManager.default.removeItem(at: targetDir)
            throw StoreError.missingSprites
        }

        // Clean up temp zip
        try? FileManager.default.removeItem(at: tempURL)

        return SkinPack(manifest: manifest, source: .local(targetDir))
    }

    // MARK: - Delete Skin

    func deleteSkin(id: String) throws {
        let skinDir = SkinPackManager.localSkinsDirectory.appendingPathComponent(id)
        try FileManager.default.removeItem(at: skinDir)

        // If this was the active skin, revert to default
        if SkinPackManager.shared.activeSkin.manifest.id == id {
            SkinPackManager.shared.selectSkin("default")
        }
    }

    // MARK: - Cache Helpers

    private func loadCachedCatalog() -> [RemoteSkinEntry]? {
        guard
            let cacheDate = UserDefaults.standard.object(forKey: Self.catalogCacheKey) as? Date,
            Date().timeIntervalSince(cacheDate) < Self.catalogCacheTTL
        else { return nil }

        let cacheFile = Self.cacheDirectory.appendingPathComponent("catalog.json")
        guard let data = try? Data(contentsOf: cacheFile) else { return nil }
        return try? JSONDecoder().decode([RemoteSkinEntry].self, from: data)
    }

    private func saveCatalogCache(_ data: Data) {
        try? FileManager.default.createDirectory(
            at: Self.cacheDirectory,
            withIntermediateDirectories: true
        )
        let cacheFile = Self.cacheDirectory.appendingPathComponent("catalog.json")
        try? data.write(to: cacheFile)
        UserDefaults.standard.set(Date(), forKey: Self.catalogCacheKey)
    }

    // MARK: - Security Helpers

    private func validateNoPathTraversal(in directory: URL) throws {
        let fm = FileManager.default
        let canonicalBase = directory.resolvingSymlinksInPath().path

        guard let enumerator = fm.enumerator(at: directory, includingPropertiesForKeys: nil) else {
            return
        }

        for case let fileURL as URL in enumerator {
            let canonicalFile = fileURL.resolvingSymlinksInPath().path
            guard canonicalFile.hasPrefix(canonicalBase) else {
                try? fm.removeItem(at: directory)
                throw StoreError.pathTraversal
            }
        }
    }
}
