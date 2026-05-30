import Foundation

/// App 条目（纯值类型，Sendable，用于跨 actor 传递）。
struct AppEntry: Sendable {
    /// App bundle URL（.app 目录）
    let url: URL
    /// 显示名（文件名去 .app；中文 app 即中文名，用户可辨识）
    let name: String
    /// 小写显示名
    let nameLower: String
    /// 匹配别名（全小写，已含 nameLower）。
    /// 来源：文件名 + Info.plist 的 CFBundleDisplayName/CFBundleName/CFBundleExecutable
    /// + CFBundleIdentifier 成分。解决「微信.app 搜 wechat / 哔哩哔哩.app 搜 bilibili」搜不到。
    let aliases: [String]

    /// 主初始化（自动计算 nameLower，归一去重 aliases 并保证含 nameLower）
    init(url: URL, name: String, aliases: [String] = []) {
        self.url = url
        self.name = name
        let lower = name.lowercased()
        self.nameLower = lower
        var merged = [lower]
        for raw in aliases {
            let a = raw.lowercased()
            if !a.isEmpty, !merged.contains(a) { merged.append(a) }
        }
        self.aliases = merged
    }

    /// 显式指定 nameLower（供测试或预计算使用；aliases 退化为 [nameLower]）
    init(url: URL, name: String, nameLower: String) {
        self.url = url
        self.name = name
        self.nameLower = nameLower
        self.aliases = [nameLower]
    }
}
