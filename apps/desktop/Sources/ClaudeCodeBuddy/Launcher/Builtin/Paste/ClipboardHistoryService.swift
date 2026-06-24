import AppKit
import CryptoKit
import Foundation

/// 剪贴板历史服务（契约规约 ## 接口签名 SSOT）。
///
/// 职责：
/// 1. 常驻 Timer 0.5s 轮询 `NSPasteboard.general.changeCount`（NSPasteboard 无可靠 change 通知，
///    轮询是行业标准，Alfred/Maccy 同款）
/// 2. 多类型读取优先级（file > image > html > text）+ Concealed/Transient 排除
/// 3. sha256 前 8 字符去重（连续重复更新 ts；非连续重复提至队首）
/// 4. JSON 持久化 `~/.buddy/clipboard-history.json` + 图片 `~/.buddy/clipboard-images/<sha8>.png`
/// 5. 限制裁剪（text ≤500 / image ≤50 / 30 天过期）
///
/// @MainActor：NSPasteboard 仅主线程安全 + NSWorkspace.frontmostApplication 主线程访问。
/// 参考 pattern 2026-05-26 / 2026-05-30 / 2026-06-19。
@MainActor
final class ClipboardHistoryService {

    // MARK: - 单例（生产用 .shared，测试用 init(pasteboard:storageDir:) 注入）

    /// 生产单例。参考 pattern 2026-06-19：`.shared` 不能作 nonisolated 默认参数。
    static let shared = ClipboardHistoryService()

    // MARK: - 配置常量（契约边界值）

    /// 监听间隔：`pollingInterval == 0.5s`（契约边界值 invariant）
    static let pollingInterval: TimeInterval = 0.5
    /// 文本上限：`textItems.count <= 500`
    static let textLimit = 500
    /// 图片上限：`imageItems.count <= 50`
    static let imageLimit = 50
    /// 过期阈值：30 天（`item.ts > now - 30*86400`）
    static let expirationSeconds: Int = 30 * 24 * 60 * 60
    /// JSON schema 版本（持久化兼容性出口）
    static let schemaVersion = 1
    /// hash 长度（sha256 前 8 字符）
    static let hashLength = 8

    // MARK: - 依赖（测试 seam）

    private let pasteboard: NSPasteboard
    private let storageDir: URL
    private let imagesDir: URL
    private let historyFile: URL

    /// 内存历史数组（队首=最新）。读取由 PastePlugin 通过 snapshot 访问。
    private(set) var items: [ClipboardHistoryItem] = []

    /// 上次观测到的 changeCount（变化才解析）
    private var lastChangeCount: Int = 0

    /// Timer（幂等 startMonitoring 保证只有一个）
    private var timer: Timer?

    // MARK: - init（生产 / 测试 seam）

    /// 生产 init：使用 `.general` pasteboard + `~/.buddy/` 存储目录。
    /// 参考 pattern 2026-05-27：home 用 NSHomeDirectory()（忽略 $HOME env，生产稳定）。
    private init() {
        // 参考 CopyService.shared 用 .general
        let home = NSHomeDirectory()
        let dir = URL(fileURLWithPath: home)
            .appendingPathComponent(".buddy", isDirectory: true)
        self.pasteboard = .general
        self.storageDir = dir
        self.imagesDir = dir.appendingPathComponent("clipboard-images", isDirectory: true)
        self.historyFile = dir.appendingPathComponent("clipboard-history.json", isDirectory: false)
    }

    /// 测试 init：注入隔离 pasteboard + 临时存储目录（参考 CopyService.init(pasteboard:) +
    /// pattern 2026-05-29-nspasteboard-test-isolation）。
    init(pasteboard: NSPasteboard, storageDir: URL) {
        self.pasteboard = pasteboard
        self.storageDir = storageDir
        self.imagesDir = storageDir.appendingPathComponent("clipboard-images", isDirectory: true)
        self.historyFile = storageDir.appendingPathComponent("clipboard-history.json", isDirectory: false)
    }

    // MARK: - 监听（契约：startMonitoring 幂等）

    /// 启动 Timer 0.5s 轮询。幂等（重复调用不叠加 Timer）。
    func startMonitoring() {
        guard timer == nil else { return }

        // 启动：加载持久化 + 清理过期 + 记录当前 changeCount（避免启动时回灌旧内容）
        load()
        purgeExpired()
        lastChangeCount = pasteboard.changeCount

        let t = Timer.scheduledTimer(
            withTimeInterval: Self.pollingInterval,
            repeats: true
        ) { [weak self] _ in
            // Timer 闭包在主线程；self 是 @MainActor，需 assumeIsolated 进入（参考 pattern 2026-05-26）
            MainActor.assumeIsolated {
                self?.tick()
            }
        }
        timer = t
    }

    /// 停止监听（测试清理用）。
    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
    }

    /// Timer 回调：检测 changeCount 变化，变化才解析。
    private func tick() {
        let current = pasteboard.changeCount
        guard current != lastChangeCount else { return }
        lastChangeCount = current
        readPasteboard()
    }

    // MARK: - 读取 NSPasteboard（契约：多类型优先级 + Concealed/Transient 排除）

    /// 解析当前 pasteboard 内容并 append。
    /// 优先级：file > image > html > text（与 perform 回填对称，file 最强以免复制文件时只拿到文件名）。
    /// 排除：`org.nspasteboard.ConcealedType`（密码）/ `org.nspasteboard.TransientType`（临时）一律不记录。
    func readPasteboard() {
        // 安全排除（契约核心决策 #7）
        if isConcealedOrTransient() { return }

        // 1. 文件 URL（public.file-url）
        if let item = readFileURL() {
            append(item)
            return
        }
        // 2. 图片（public.png / TIFF）
        if let item = readImage() {
            append(item)
            return
        }
        // 3. 富文本（public.html + 纯文本 fallback）
        if let item = readHTML() {
            append(item)
            return
        }
        // 4. 纯文本
        if let item = readText() {
            append(item)
            return
        }
    }

    /// 检测 ConcealedType / TransientType 标记。
    private func isConcealedOrTransient() -> Bool {
        let concealed = pasteboard.types?.contains(.init(rawValue: "org.nspasteboard.ConcealedType")) == true
        let transient = pasteboard.types?.contains(.init(rawValue: "org.nspasteboard.TransientType")) == true
        return concealed || transient
    }

    private func readFileURL() -> ClipboardHistoryItem? {
        guard let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
              let url = urls.first,
              url.isFileURL
        else { return nil }

        let path = url.path
        let hash = Self.sha8(path)
        return ClipboardHistoryItem(
            id: UUID().uuidString,
            type: .file,
            content: path,
            html: nil,
            imagePath: nil,
            sourceApp: Self.frontmostBundleID(),
            ts: Self.now(),
            hash: hash
        )
    }

    private func readImage() -> ClipboardHistoryItem? {
        // 优先 PNG（最完整无损），失败回退 TIFF（系统截图默认）
        let pngType = NSPasteboard.PasteboardType.png
        let tiffType = NSPasteboard.PasteboardType.tiff

        let rawData: Data?
        if let png = pasteboard.data(forType: pngType), !png.isEmpty {
            rawData = png
        } else if let tiff = pasteboard.data(forType: tiffType), !tiff.isEmpty,
                  let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) {
            rawData = png
        } else {
            rawData = nil
        }
        guard let pngData = rawData else { return nil }

        let hash = Self.sha8(pngData)
        let imagePath = imagesDir.appendingPathComponent("\(hash).png").path

        // 落盘（失败则丢弃该条目，契约错误处理：不阻塞监听）
        do {
            try ensureDir(imagesDir)
            try pngData.write(to: URL(fileURLWithPath: imagePath), options: .atomic)
        } catch {
            BuddyLogger.shared.error("clipboard image persist failed", subsystem: "clipboard", meta: ["error": "\(error)"])
            return nil
        }

        return ClipboardHistoryItem(
            id: UUID().uuidString,
            type: .image,
            content: "",
            html: nil,
            imagePath: imagePath,
            sourceApp: Self.frontmostBundleID(),
            ts: Self.now(),
            hash: hash
        )
    }

    private func readHTML() -> ClipboardHistoryItem? {
        let htmlType = NSPasteboard.PasteboardType.html
        guard let html = pasteboard.string(forType: htmlType), !html.isEmpty else { return nil }
        // 纯文本 fallback：优先 .string，HTML 剥标签兜底
        var plain = pasteboard.string(forType: .string) ?? ""
        if plain.isEmpty {
            plain = html.strippingHTMLTags()
        }
        guard !plain.isEmpty else { return nil }

        let hash = Self.sha8(plain)
        return ClipboardHistoryItem(
            id: UUID().uuidString,
            type: .html,
            content: plain,
            html: html,
            imagePath: nil,
            sourceApp: Self.frontmostBundleID(),
            ts: Self.now(),
            hash: hash
        )
    }

    private func readText() -> ClipboardHistoryItem? {
        guard let text = pasteboard.string(forType: .string), !text.isEmpty else { return nil }
        let hash = Self.sha8(text)
        return ClipboardHistoryItem(
            id: UUID().uuidString,
            type: .text,
            content: text,
            html: nil,
            imagePath: nil,
            sourceApp: Self.frontmostBundleID(),
            ts: Self.now(),
            hash: hash
        )
    }

    // MARK: - append（去重 + 裁剪 + 落盘）

    /// 追加条目：去重（连续更新 ts；非连续提至队首）+ 类型上限裁剪 + 增量落盘。
    func append(_ newItem: ClipboardHistoryItem) {
        // 去重：查找同 hash 的既有条目
        if let existingIdx = items.firstIndex(where: { $0.hash == newItem.hash }) {
            if existingIdx == 0 {
                // 连续重复：只更新 ts（契约决策 #8）
                let existing = items[0]
                items[0] = ClipboardHistoryItem(
                    id: existing.id,
                    type: existing.type,
                    content: existing.content,
                    html: existing.html,
                    imagePath: existing.imagePath,
                    sourceApp: newItem.sourceApp ?? existing.sourceApp,
                    ts: newItem.ts,
                    hash: existing.hash
                )
            } else {
                // 非连续重复：提至队首 + 更新 ts（契约决策 #8）
                items.remove(at: existingIdx)
                items.insert(newItem, at: 0)
            }
        } else {
            // 新增到队首
            items.insert(newItem, at: 0)
        }

        // 类型上限裁剪
        trimByType()

        // 增量落盘（失败：log + 内存数据继续，不 crash）
        save()
    }

    /// 按类型裁剪：text ≤500 / image ≤50（契约边界值）。
    /// 策略：从队尾移除（队首=最新，队尾=最旧）。
    private func trimByType() {
        var textCount = 0
        var imageCount = 0
        for item in items {
            switch item.type {
            case .text, .file, .html:  // 文本类（含 file 路径、html fallback）合并计入 text 上限
                textCount += 1
            case .image:
                imageCount += 1
            }
        }

        // 仅当超限时从队尾移除对应类型条目
        while textCount > Self.textLimit || imageCount > Self.imageLimit {
            // 从队尾找第一个需移除的
            guard let removeIdx = items.indices.reversed().first(where: { idx in
                switch items[idx].type {
                case .text, .file, .html:
                    return textCount > Self.textLimit
                case .image:
                    return imageCount > Self.imageLimit
                }
            }) else { break }

            switch items[removeIdx].type {
            case .text, .file, .html:
                textCount -= 1
            case .image:
                imageCount -= 1
            }
            items.remove(at: removeIdx)
        }
    }

    /// 启动清理过期条目（契约决策 #9）。
    private func purgeExpired() {
        let cutoff = Self.now() - Self.expirationSeconds
        items.removeAll { $0.ts < cutoff }
    }

    // MARK: - snapshot（PastePlugin 调用）

    /// 返回历史（按 ts 倒序，队首最新）。filter 非空时按 content/html/imagePath 包含过滤。
    func snapshot(filter: String? = nil) -> [ClipboardHistoryItem] {
        guard let f = filter?.trimmingCharacters(in: .whitespaces), !f.isEmpty else {
            return items
        }
        let lower = f.lowercased()
        return items.filter { item in
            if item.content.lowercased().contains(lower) { return true }
            if let html = item.html?.lowercased(), html.contains(lower) { return true }
            if let path = item.imagePath?.lowercased(), path.contains(lower) { return true }
            return false
        }
    }

    // MARK: - 持久化

    /// 持久化 JSON wrapper schema。
    private struct HistoryStore: Codable {
        let schemaVersion: Int
        let items: [ClipboardHistoryItem]
    }

    /// 保存到 `~/.buddy/clipboard-history.json`。失败：log + 内存继续（契约错误处理）。
    func save() {
        do {
            try ensureDir(storageDir)
            let store = HistoryStore(schemaVersion: Self.schemaVersion, items: items)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(store)
            try data.write(to: historyFile, options: .atomic)
        } catch {
            BuddyLogger.shared.error("clipboard save failed", subsystem: "clipboard", meta: ["error": "\(error)"])
        }
    }

    /// 从 `~/.buddy/clipboard-history.json` 加载。失败：log + 空列表（契约错误处理）。
    func load() {
        guard FileManager.default.fileExists(atPath: historyFile.path) else {
            items = []
            return
        }
        do {
            let data = try Data(contentsOf: historyFile)
            let store = try JSONDecoder().decode(HistoryStore.self, from: data)
            // schemaVersion 未来演进出口；当前 v1 直接用
            items = store.items
        } catch {
            BuddyLogger.shared.warn("clipboard load failed, starting empty", subsystem: "clipboard", meta: ["error": "\(error)"])
            items = []
        }
    }

    // MARK: - 工具方法

    /// sha256 前 8 字符（契约决策 #8）。
    static func sha8(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined().prefix(hashLength).description
    }

    /// sha256 前 8 字符（字符串便捷重载）。
    static func sha8(_ string: String) -> String {
        sha8(Data(string.utf8))
    }

    /// 当前 Unix 秒。
    static func now() -> Int {
        Int(Date().timeIntervalSince1970)
    }

    /// 前台 app bundle id（可为 nil）。
    static func frontmostBundleID() -> String? {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }

    /// 确保目录存在（幂等）。
    private func ensureDir(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
}

// MARK: - String HTML 剥离工具（富文本 fallback）

private extension String {
    /// 粗糙剥 HTML 标签（fallback 用，非安全过滤）。
    func strippingHTMLTags() -> String {
        // 移除 <...>，解码常见实体
        var result = self
        while let range = result.range(of: "<[^>]+>", options: .regularExpression) {
            result.removeSubrange(range)
        }
        result = result.replacingOccurrences(of: "&nbsp;", with: " ")
        result = result.replacingOccurrences(of: "&amp;", with: "&")
        result = result.replacingOccurrences(of: "&lt;", with: "<")
        result = result.replacingOccurrences(of: "&gt;", with: ">")
        result = result.replacingOccurrences(of: "&quot;", with: "\"")
        result = result.replacingOccurrences(of: "&#39;", with: "'")
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
