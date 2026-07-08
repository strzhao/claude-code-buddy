import AppKit
import Foundation

// MARK: - SnippetsError
//
// 片段库操作错误（GUI 字段级错误提示用，契约 C4）。
enum SnippetsError: LocalizedError, Equatable {
    /// keyword 不合法：含非 `[A-Za-z0-9_-]` 字符 / 长度不在 [1,64]（防 shell 注入，对齐 snippets.sh C8）
    case invalidKeyword
    /// content 超长：> 10000 字符（C4）
    case contentTooLong
    /// add 时 keyword 已存在（C1）
    case keywordAlreadyExists
    /// edit 时 keyword 不存在（C1）
    case keywordNotFound

    var errorDescription: String? {
        switch self {
        case .invalidKeyword:
            return "keyword 仅允许字母、数字、下划线、连字符，长度 1-64"
        case .contentTooLong:
            return "content 长度不能超过 10000 字符"
        case .keywordAlreadyExists:
            return "该 keyword 已存在"
        case .keywordNotFound:
            return "该 keyword 不存在"
        }
    }
}

// MARK: - SnippetsService
//
// 片段库数据层（snip GUI 化用，参考 ClipboardHistoryService 范式）。
//
// 职责：
// 1. CRUD（add/edit/delete）+ 查询（search/list）片段库（keyword→content 映射）
// 2. JSON 持久化 `~/.buddy/snippets.json`（顶级数组，ISO8601 时间戳，对齐 snippets.sh）
// 3. 校验（keyword 白名单 + content 长度，C4）
// 4. 原子写 .atomic（C5）+ 容错 load（缺失/损坏→[]，不崩）
//
// 并发（C5）：@MainActor 串行化 GUI 写；launcher snip.sh 取用只读同一文件，无锁冲突。
// 当前一致性依赖「GUI 独占写 + shell 只读」前提（snip-mgr 删除后稳固，imp-83 注）。
//
// @MainActor：参考 ClipboardHistoryService :18（NSPasteboard 主线程安全 + 简单串行化）。
// 本服务无 NSPasteboard 依赖，但 GUI 直驱独占写时 @MainActor 串行化足够（无锁无并发问题）。
@MainActor
final class SnippetsService: ObservableObject {

    // MARK: - 单例（生产用 .shared，测试用 init(snippetsFile:) 注入）

    static let shared = SnippetsService()

    // MARK: - 配置常量（契约边界值）

    /// keyword 长度上限（C4，对齐 snippets.sh C8）。
    static let keywordMaxLength = 64
    /// content 字符上限（C4）。
    static let contentMaxLength = 10_000
    /// keyword 白名单字符集（C4，防 shell 注入）：`[A-Za-z0-9_-]`。
    static let keywordAllowedChars: CharacterSet = {
        var set = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-")
        return set
    }()

    // MARK: - 依赖（测试 seam）

    private let snippetsFile: URL

    /// 内存缓存（GUI 直驱读写，对齐 ClipboardHistoryService.items :48）。
    /// @Published：CRUD 后 SwiftUI 视图（SnipPanelView @ObservedObject）自动刷新列表
    /// （fix qa-reviewer High 2：@State 持 reference type 不观察内部 mutation）。
    @Published private(set) var items: [SnippetItem] = []

    // MARK: - init（生产 / 测试 seam）

    /// 生产 init：`~/.buddy/snippets.json`（NSHomeDirectory，与 ClipboardHistoryService :60 同目录）。
    private init() {
        let home = NSHomeDirectory()
        let dir = URL(fileURLWithPath: home).appendingPathComponent(".buddy", isDirectory: true)
        self.snippetsFile = dir.appendingPathComponent("snippets.json", isDirectory: false)
        // 启动加载（容错：缺失/损坏→空列表，不抛）
        load()
    }

    /// 测试 seam：注入隔离 snippetsFile URL（参考 ClipboardHistoryService.init(storageDir:) :73）。
    init(snippetsFile: URL) {
        self.snippetsFile = snippetsFile
        // 不在 init 调 load（测试需显式控制 load 时机）
    }

    // MARK: - 加载 / 持久化（C2 + C5）

    /// 加载片段库。容错：缺失/空/损坏→[]，不抛（对齐 ClipboardHistoryService.load :371-385）。
    /// 返回内存缓存 items（按 keyword 字典序，与 list() 同序）。
    @discardableResult
    func load() -> [SnippetItem] {
        guard FileManager.default.fileExists(atPath: snippetsFile.path) else {
            items = []
            return items
        }
        do {
            let data = try Data(contentsOf: snippetsFile)
            // 空文件视为空数组（防 .write("") 留下的空文件崩）
            if data.isEmpty {
                items = []
                return items
            }
            // C2：顶级 [SnippetItem] 数组（非 wrapper），decodeIfPresent 兼容旧版
            let decoded = try JSONDecoder().decode([SnippetItem].self, from: data)
            items = decoded.sorted { $0.keyword < $1.keyword }
            return items
        } catch {
            BuddyLogger.shared.warn(
                "snippets load failed, starting empty",
                subsystem: "snippets",
                meta: ["error": "\(error)"]
            )
            items = []
            return items
        }
    }

    /// 原子写到 snippetsFile（C5）。失败：log + 不崩（对齐 ClipboardHistoryService.save :357-368）。
    func save() {
        do {
            try ensureDir()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(items)
            try data.write(to: snippetsFile, options: .atomic)
        } catch {
            BuddyLogger.shared.error(
                "snippets save failed",
                subsystem: "snippets",
                meta: ["error": "\(error)"]
            )
        }
    }

    // MARK: - CRUD（C1）

    /// 新增片段。校验 keyword + content（C4）；重复 keyword → throw .keywordAlreadyExists。
    /// 时间戳：created_at == updated_at == 当前 ISO8601（UTC）。
    func add(keyword: String, content: String) throws {
        try validate(keyword: keyword, content: content)
        if items.contains(where: { $0.keyword == keyword }) {
            throw SnippetsError.keywordAlreadyExists
        }
        let now = Self.nowISO8601()
        let item = SnippetItem(keyword: keyword, content: content, created_at: now, updated_at: now)
        items.append(item)
        items.sort { $0.keyword < $1.keyword }
        save()
    }

    /// 编辑已有片段的 content（不改 keyword，保留 created_at，更新 updated_at）。
    /// 不存在 → throw .keywordNotFound；content 校验失败 → throw 对应错误（C4）。
    func edit(keyword: String, content: String) throws {
        try validate(keyword: keyword, content: content)
        guard let idx = items.firstIndex(where: { $0.keyword == keyword }) else {
            throw SnippetsError.keywordNotFound
        }
        let existing = items[idx]
        // created_at 不变；updated_at 更新为当前 ISO8601
        items[idx] = SnippetItem(
            keyword: keyword,
            content: content,
            created_at: existing.created_at,
            updated_at: Self.nowISO8601()
        )
        save()
    }

    /// 删除片段。幂等（不存在不报错，对齐 C1）。
    func delete(keyword: String) {
        guard let idx = items.firstIndex(where: { $0.keyword == keyword }) else { return }
        items.remove(at: idx)
        save()
    }

    // MARK: - 查询（C1）

    /// 模糊匹配 keyword（大小写不敏感 contains）。空 query → 全部（按 keyword 字典序）。
    func search(_ query: String) -> [SnippetItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return list() }
        let lower = trimmed.lowercased()
        return items.filter { $0.keyword.lowercased().contains(lower) }
    }

    /// 全部片段，按 keyword 字典序（与 load 排序一致）。
    func list() -> [SnippetItem] {
        items.sorted { $0.keyword < $1.keyword }
    }

    // MARK: - 校验（C4）

    /// keyword 白名单 `[A-Za-z0-9_-]` 长 1-64 + content ≤ 10000（对齐 snippets.sh C8）。
    /// 违反 → throw SnippetsError（GUI 字段级错误提示，AC-SNIPGUI-17/18）。
    private func validate(keyword: String, content: String) throws {
        let trimmedKw = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        // 长度边界（1-64）
        guard !trimmedKw.isEmpty, trimmedKw.count <= Self.keywordMaxLength else {
            throw SnippetsError.invalidKeyword
        }
        // 字符白名单（防 shell 注入）
        guard trimmedKw.unicodeScalars.allSatisfy({ Self.keywordAllowedChars.contains($0) }) else {
            throw SnippetsError.invalidKeyword
        }
        // content 长度上限（按字符数计，对齐 snippets.sh C8 `wc -m`）
        guard content.count <= Self.contentMaxLength else {
            throw SnippetsError.contentTooLong
        }
    }

    // MARK: - 工具方法

    /// 当前 ISO8601 UTC 字符串（对齐 snippets.sh `date -u +%Y-%m-%dT%H:%M:%SZ`）。
    static func nowISO8601() -> String {
        // 手工格式化（不依赖 ISO8601DateFormatter 各 OS 兼容性差异）
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone(identifier: "UTC")
        fmt.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        return fmt.string(from: Date())
    }

    /// 占位符展开（AC-SNIPGUI-23，对齐 snippets.sh expand_placeholders，契约同步入口）。
    ///
    /// 支持 {date}/{time}/{clipboard}，未定义占位符原样保留。
    /// 与 SnipPanelView.expandPlaceholders(_:) 同语义；service 层暴露便于 test + GUI 复用。
    /// GUI 预览 + shell 取用读同一展开逻辑（C6 一致性）。
    func expandPlaceholders(in text: String) -> String {
        Self.expandPlaceholders(text)
    }

    /// 占位符展开静态方法（对齐 snippets.sh expand_placeholders，无 service 实例依赖）。
    static func expandPlaceholders(_ text: String) -> String {
        var result = text

        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone.current

        // {date} → YYYY-MM-DD
        fmt.dateFormat = "yyyy-MM-dd"
        result = result.replacingOccurrences(of: "{date}", with: fmt.string(from: Date()))

        // {time} → HH:MM
        fmt.dateFormat = "HH:mm"
        result = result.replacingOccurrences(of: "{time}", with: fmt.string(from: Date()))

        // {clipboard} → 当前剪贴板
        if result.contains("{clipboard}") {
            let pb = NSPasteboard.general.string(forType: .string) ?? ""
            result = result.replacingOccurrences(of: "{clipboard}", with: pb)
        }
        return result
    }

    /// 确保 snippetsFile 所在目录存在（幂等，C5）。
    private func ensureDir() throws {
        let dir = snippetsFile.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
}
