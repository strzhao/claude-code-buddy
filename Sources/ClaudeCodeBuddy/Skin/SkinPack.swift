import Foundation

// MARK: - SkinPack

struct SkinPack {
    let manifest: SkinPackManifest
    let source: SkinSource

    // MARK: - SkinSource

    enum SkinSource {
        case builtIn(Bundle)
        case local(URL)
    }

    // MARK: - Resource URL

    /// Returns the URL for a resource within the skin pack.
    ///
    /// - For `builtIn`: looks up `"Assets/<subdirectory>/<name>.<ext>"` in the bundle.
    /// - For `local`: resolves `<baseURL>/<subdirectory>/<name>.<ext>` and confirms the file exists.
    func url(forResource name: String, withExtension ext: String, subdirectory: String) -> URL? {
        switch source {
        case .builtIn(let bundle):
            return bundle.url(
                forResource: name,
                withExtension: ext,
                subdirectory: "Assets/\(subdirectory)"
            )
        case .local(let baseURL):
            let fileURL = baseURL
                .appendingPathComponent(subdirectory)
                .appendingPathComponent("\(name).\(ext)")
            guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
            return fileURL
        }
    }
}

// MARK: - Equatable

extension SkinPack: Equatable {
    static func == (lhs: SkinPack, rhs: SkinPack) -> Bool {
        lhs.manifest.id == rhs.manifest.id
    }
}
