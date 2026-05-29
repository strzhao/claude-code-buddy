# Swift enum 多形态 JSON Codable：先 try String 再 try keyed container

<!-- tags: swift, codable, jsondecoder, enum, polymorphic, associated-values, marketplace, schema -->

**Scenario**: task 001 设计 `PluginSourceConfig` enum 表达插件 source，参考 Anthropic claude-plugins-official 的 marketplace.json 设计，需要支持两种 JSON 形态：

```json
// 短形式：本地子目录简写
"source": "./plugins/translate"

// 长形式：git/file 等带额外字段
"source": {"source": "git-subdir", "url": "...", "path": "...", "ref": "...", "sha": "..."}
"source": {"source": "url", "url": "...", "sha": "..."}
"source": {"source": "file", "path": "..."}
```

Swift enum 自带 Codable 合成不支持"裸字符串 ⇄ keyed container"双形态。需要自定义 init(from:) / encode(to:)。

**Lesson**: 实现模式 — **decode 先 try `singleValueContainer().decode(String.self)`，失败再 try keyed container 按判别字段分发**。encode 反之：对"短形式" case 走 singleValueContainer 输出裸字符串，"长形式" case 走 keyed container。关键：try? 顺序不能颠倒，否则对象形态会被 String decode 尝试匹配 → 报 typeMismatch 而非 dataCorrupted，错误处理更难。

```swift
enum PluginSourceConfig: Equatable {
    case localSubdir(path: String)                                    // 短形式
    case gitSubdir(url: String, path: String, ref: String, sha: String)
    case gitURL(url: String, sha: String?)
    case file(path: String)
}

extension PluginSourceConfig: Codable {
    init(from decoder: Decoder) throws {
        // 1. 先 try String（短形式）
        if let s = try? decoder.singleValueContainer().decode(String.self) {
            self = .localSubdir(path: s)
            return
        }
        // 2. 失败 → try keyed container（长形式）
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(String.self, forKey: .source)
        switch kind {
        case "git-subdir":
            self = .gitSubdir(
                url: try c.decode(String.self, forKey: .url),
                path: try c.decode(String.self, forKey: .path),
                ref: try c.decode(String.self, forKey: .ref),
                sha: try c.decode(String.self, forKey: .sha)
            )
        case "url":
            self = .gitURL(
                url: try c.decode(String.self, forKey: .url),
                sha: try c.decodeIfPresent(String.self, forKey: .sha)
            )
        case "file":
            self = .file(path: try c.decode(String.self, forKey: .path))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .source, in: c,
                debugDescription: "unknown source kind: \(kind)"
            )
        }
    }
    
    func encode(to encoder: Encoder) throws {
        switch self {
        case .localSubdir(let path):
            var single = encoder.singleValueContainer()
            try single.encode(path)                                   // 输出裸字符串
        case .gitSubdir(let url, let path, let ref, let sha):
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode("git-subdir", forKey: .source)
            try c.encode(url, forKey: .url)
            try c.encode(path, forKey: .path)
            try c.encode(ref, forKey: .ref)
            try c.encode(sha, forKey: .sha)
        // ... 其他 case
        }
    }
    
    private enum CodingKeys: String, CodingKey {
        case source, url, path, ref, sha
    }
}
```

**关键陷阱**：

1. **try 顺序不可颠倒**：先 try String 是因为对象形态对 String decode 会立即报 typeMismatch，被外层 try? 吞掉，安全；反过来对象 → keyed 报 typeMismatch 是 "expected dictionary got string"，错误层次混乱
2. **CodingKeys 的 `source` 字段名冲突**：JSON 顶层 `source` 既是字段名又是判别值——但因为长形式才进入 keyed container，且短形式直接 String，无 CodingKeys 名歧义
3. **encode 对称性**：encode/decode 必须可 round-trip。测试用 `JSONEncoder().encode(x) → JSONDecoder().decode(...) → ==` 验证 4 种 case 各 1 次
4. **未知 kind 用 `dataCorruptedError`**：明确语义"JSON 合法但值不是 enum 期望的"，便于上层错误处理区分 vs typeMismatch

**Evidence**: task 001 红队 15 个 AT（AT01-AT15）全绿，包括 AT08 故意构造 `{"source": "unknown-xyz"}` 验证抛 dataCorrupted；蓝队 10 个单测覆盖 4 case round-trip + AT15 验证裸字符串 `/abs/path` 不混淆为 `.file`（短形式只对应 `.localSubdir`）。

**关联**：
- 与 Anthropic [claude-plugins-official](https://github.com/anthropics/claude-plugins-official) 的 marketplace.json 设计对齐
- 与 PluginManifest 的 mode discriminated union（`stdin` vs `prompt`）思想一致（参见 `2026-05-28-pluginmanifest-discriminated-union.md` 如存在），但本场景多了"裸字符串短形式"维度
- Foundation `JSONEncoder` 默认会把 `/` 转义为 `\/`：测试断言用解码值比对，**不要**用字符串字面量比对 encode 输出
