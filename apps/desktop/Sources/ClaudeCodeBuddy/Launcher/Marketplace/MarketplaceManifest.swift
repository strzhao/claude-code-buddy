import Foundation

/// Marketplace 顶层 manifest。
///
/// schema 严格独立于 runtime（PluginManager/TrustStore 等），仅用作 Codable 数据载体。
struct MarketplaceManifest: Codable, Equatable {
    let schemaVersion: Int
    let name: String
    let description: String?
    let owner: MarketplaceOwner
    let plugins: [MarketplacePlugin]
}

struct MarketplaceOwner: Codable, Equatable {
    let name: String
    let email: String?
    let homepage: String?
}

struct MarketplacePlugin: Codable, Equatable {
    let name: String
    let description: String
    let version: String
    let category: String?
    let author: MarketplaceAuthor
    let source: PluginSourceConfig
    let homepage: String?
    let editable: Bool?
}

struct MarketplaceAuthor: Codable, Equatable {
    let name: String
    let email: String?
}

/// 插件 source 配置的多态枚举。
///
/// JSON 表示有两种形态：
/// - 字符串简写 → `.localSubdir`，例如 `"./plugins/translate"`
/// - 对象形态，按 `source` 字段判别 → `.gitSubdir` / `.gitURL` / `.file`
enum PluginSourceConfig: Equatable {
    case localSubdir(path: String)
    case gitSubdir(url: String, path: String, ref: String, sha: String)
    case gitURL(url: String, sha: String?)
    case file(path: String)
}

extension PluginSourceConfig: Codable {
    private enum CodingKeys: String, CodingKey {
        case source
        case url
        case path
        case ref
        case sha
    }

    init(from decoder: Decoder) throws {
        // 先尝试 decode 为 String（local-subdir 简写）
        if let single = try? decoder.singleValueContainer(),
           let value = try? single.decode(String.self) {
            self = .localSubdir(path: value)
            return
        }
        // 否则按 keyed container + source 字段判别
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .source)
        switch kind {
        case "git-subdir":
            self = .gitSubdir(
                url: try container.decode(String.self, forKey: .url),
                path: try container.decode(String.self, forKey: .path),
                ref: try container.decode(String.self, forKey: .ref),
                sha: try container.decode(String.self, forKey: .sha)
            )
        case "url":
            self = .gitURL(
                url: try container.decode(String.self, forKey: .url),
                sha: try container.decodeIfPresent(String.self, forKey: .sha)
            )
        case "file":
            self = .file(path: try container.decode(String.self, forKey: .path))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .source,
                in: container,
                debugDescription: "unknown source kind: \(kind)"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .localSubdir(let path):
            var single = encoder.singleValueContainer()
            try single.encode(path)
        case .gitSubdir(let url, let path, let ref, let sha):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("git-subdir", forKey: .source)
            try container.encode(url, forKey: .url)
            try container.encode(path, forKey: .path)
            try container.encode(ref, forKey: .ref)
            try container.encode(sha, forKey: .sha)
        case .gitURL(let url, let sha):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("url", forKey: .source)
            try container.encode(url, forKey: .url)
            try container.encodeIfPresent(sha, forKey: .sha)
        case .file(let path):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("file", forKey: .source)
            try container.encode(path, forKey: .path)
        }
    }
}
