import Foundation

/// App 内存索引（C4 契约）。
/// 持有 [AppEntry] + lastScanAt，扫描三个目录（含一层子目录）。
/// 刷新策略：TTL（60s）到期时后台 Task.detached 扫盘，扫完 hop 回 MainActor 替换。
/// 冷启动扫描不阻塞 UI：首次 setup 触发，搜索在索引就绪前返回空。
@MainActor
final class AppIndex {

    /// 单例（供 AppLauncherPlugin 使用）
    static let shared = AppIndex()

    // 内存条目（扫完后整体替换）；internal 供测试注入使用（@testable import 可访问）
    var entries: [AppEntry] = []

    /// 上次扫描时间（Date.distantPast 表示从未扫描）
    private var lastScanAt: Date = .distantPast

    /// 正在后台扫描中的标志（防重复触发）
    private var isScanning = false

    /// 生产+测试均可用（内部可见性）
    init() {}

    /// 测试用：注入固定 entries（不扫盘）
    init(fixedEntries: [AppEntry]) {
        self.entries = fixedEntries
        self.lastScanAt = .distantFuture  // 永不触发 stale 刷新
    }

    // MARK: - 刷新

    /// TTL 检查 + 按需后台扫描（fire-and-forget，不阻塞本次 search）。
    /// C4 契约：刷新结果应用于下次 search，不阻塞本次。
    func refreshIfStale(ttl: TimeInterval = LauncherConstants.appIndexTTLSec) {
        let now = Date()
        guard !isScanning, now.timeIntervalSince(lastScanAt) > ttl else { return }
        isScanning = true

        Task.detached(priority: .background) {
            let scanned = AppIndexScanner.scan()
            await MainActor.run {
                self.entries = scanned
                self.lastScanAt = Date()
                self.isScanning = false
            }
        }
    }

    // MARK: - 搜索

    /// 纯内存搜索（C4 契约：按分数降序、同分按 name 字典序、过滤分>0、截断到 limit）。
    /// query 为空返回 []。
    func search(_ query: String, limit: Int) -> [AppEntry] {
        guard !query.isEmpty else { return [] }

        // 打分 + 过滤：对每个 entry 取所有别名（显示名 + bundle 英文名/标识符成分）的最高分
        var scored: [(entry: AppEntry, score: Int)] = []
        for entry in entries {
            var best = 0
            for alias in entry.aliases {
                let s = AppMatcher.score(query: query, name: alias)
                if s > best { best = s }
            }
            if best > 0 {
                scored.append((entry, best))
            }
        }

        // C3 tie-break：分数相同时按 name 字典序稳定排序（保证结果可重复）
        scored.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.entry.name < rhs.entry.name
        }

        return Array(scored.prefix(limit).map(\.entry))
    }
}

// MARK: - 扫描逻辑（Sendable，可在 Task.detached 中运行）

enum AppIndexScanner {
    /// 扫描目录列表（含一层子目录识别 .app bundle）。
    static func scan() -> [AppEntry] {
        let dirs = LauncherConstants.appScanDirs
        var seen = Set<String>()
        var result: [AppEntry] = []

        let fm = FileManager.default
        for dirPath in dirs {
            let dirURL = URL(fileURLWithPath: dirPath)
            guard fm.fileExists(atPath: dirPath) else { continue }

            // 直接子条目
            let children = (try? fm.contentsOfDirectory(
                at: dirURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: .skipsHiddenFiles
            )) ?? []

            for item in children {
                if item.pathExtension == "app" {
                    addEntry(item, to: &result, seen: &seen)
                } else {
                    // 一层子目录：扫其中的 .app
                    var isDir: ObjCBool = false
                    if fm.fileExists(atPath: item.path, isDirectory: &isDir), isDir.boolValue {
                        let subs = (try? fm.contentsOfDirectory(
                            at: item,
                            includingPropertiesForKeys: nil,
                            options: .skipsHiddenFiles
                        )) ?? []
                        for sub in subs where sub.pathExtension == "app" {
                            addEntry(sub, to: &result, seen: &seen)
                        }
                    }
                }
            }
        }

        return result
    }

    private static func addEntry(_ url: URL, to result: inout [AppEntry], seen: inout Set<String>) {
        let path = url.path
        guard !seen.contains(path) else { return }
        seen.insert(path)
        // 显示名 = 文件名去 .app（中文 app 即中文名，用户可辨识）
        let name = url.deletingPathExtension().lastPathComponent
        // 匹配别名 = Info.plist 英文名 + bundle id 成分 + 本地化中文名 + 拼音别名
        let rawAliases = bundleAliases(for: url) + localizedChineseNames(for: url)
        var aliases = rawAliases
        // 对所有含 CJK 的原始名（文件名 + bundle 别名 + 本地化名）生成拼音别名
        var seenPinyin = Set<String>()
        for raw in [name] + rawAliases {
            for py in pinyinAliases(for: raw) where seenPinyin.insert(py).inserted {
                aliases.append(py)
            }
        }
        result.append(AppEntry(url: url, name: name, aliases: aliases))
    }

    /// 从 .app/Contents/Info.plist 提取英文匹配别名。
    /// CFBundleDisplayName/CFBundleName/CFBundleExecutable（如 WeChat）+ CFBundleIdentifier
    /// 去掉常见前缀后的成分（如 com.bilibili.bilibiliPC → bilibili / bilibiliPC）。
    private static func bundleAliases(for url: URL) -> [String] {
        let infoURL = url.appendingPathComponent("Contents/Info.plist")
        guard let info = NSDictionary(contentsOf: infoURL) else { return [] }
        var aliases: [String] = []
        for key in ["CFBundleDisplayName", "CFBundleName", "CFBundleExecutable"] {
            if let v = info[key] as? String, !v.isEmpty { aliases.append(v) }
        }
        if let bid = info["CFBundleIdentifier"] as? String {
            // 跳过常见反域名前缀，保留品牌/产品成分作为别名
            let skip: Set<String> = ["com", "org", "net", "io", "co", "app", "www", "cn", "us", "tv", "me"]
            for comp in bid.split(separator: ".") {
                let c = String(comp)
                if !skip.contains(c.lowercased()) { aliases.append(c) }
            }
        }
        return aliases
    }

    /// 从 zh-Hans.lproj/InfoPlist.strings 等本地化资源读取中文名（如 WeChat.app → "微信"）。
    /// 解决 app 文件名和 Info.plist 为英文但系统本地化资源含中文名的情况。
    private static func localizedChineseNames(for url: URL) -> [String] {
        for lproj in ["zh-Hans", "zh-Hant", "zh-HK", "zh-TW"] {
            let stringsURL = url.appendingPathComponent("Contents/Resources/\(lproj).lproj/InfoPlist.strings")
            guard let dict = NSDictionary(contentsOf: stringsURL) else { continue }
            var result: [String] = []
            for key in ["CFBundleDisplayName", "CFBundleName"] {
                if let v = dict[key] as? String, !v.isEmpty { result.append(v) }
            }
            if !result.isEmpty { return result }
        }
        return []
    }

    /// 为含 CJK 字符的 app 显示名生成拼音别名（如 "微信" → ["weixin", "wx"]）。
    /// 使用系统 CFStringTransform 转 Latin + 去声调，无 CJK 时返回空。
    /// internal 以便单元测试覆盖 ü→v 归一（见 AppIndexTests）。
    static func pinyinAliases(for name: String) -> [String] {
        let mutable = NSMutableString(string: name)
        // 转 Latin（拼音带声调，如 "lǜ lián yún"）
        CFStringTransform(mutable, nil, kCFStringTransformToLatin, false)
        // ü → v 归一（必须在去声调之前）：中文拼音输入法用 v 代替 ü（键盘无 ü 键），
        // 而 CFStringTransformStripCombiningMarks 会把 ü 抹成 u（"绿"→lu 而非 lv），
        // 导致"绿联云"用 "lvlian" 搜不到。ü 系列只出现在 lü/nü，不误伤普通 u（lian/yun 等）。
        var latin = mutable as String
        for c in ["ü", "Ü", "ǖ", "ǘ", "ǚ", "ǜ"] {
            latin = latin.replacingOccurrences(of: c, with: "v")
        }
        // 去声调（→ "lv lian yun"）
        let stripped = NSMutableString(string: latin)
        CFStringTransform(stripped, nil, kCFStringTransformStripCombiningMarks, false)
        let pinyin = (stripped as String).lowercased()

        // 无 CJK 字符则跳过（转换后与原名相同）
        guard pinyin != name.lowercased() else { return [] }

        var result: [String] = []
        // 无空格全拼：weixin
        let noSpaces = pinyin.replacingOccurrences(of: " ", with: "")
        if !noSpaces.isEmpty { result.append(noSpaces) }
        // 首字母缩写：wx
        let initials = pinyin.split(separator: " ").compactMap(\.first).map(String.init).joined()
        if !initials.isEmpty, initials != noSpaces { result.append(initials) }
        return result
    }
}
