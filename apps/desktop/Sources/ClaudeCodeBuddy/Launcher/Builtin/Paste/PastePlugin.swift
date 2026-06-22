import AppKit

/// 剪贴板历史内置插件（契约 ## 接口签名 SSOT）。
///
/// 照搬 CalculatorPlugin 结构（@MainActor 单例 + actions(for:) 门控 + perform 调 CopyService）。
/// 触发词 `cb`/`clipboard`/`剪贴板`/`paste` hasPrefix 匹配 → 读 ClipboardHistoryService.snapshot()
/// → 按 query 剩余词过滤 → 构造 LauncherAction（图片用 icon 承载缩略图）。
/// perform 调 CopyService（文本 copy / 图片 copyImage / 文件 copyFileURL / 富文本 html+plain）。
///
/// @MainActor：ClipboardHistoryService 与 CopyService 均 @MainActor，规避 NSImage/闭包跨 actor 的 Sendable 问题。
@MainActor
final class PastePlugin: BuiltinPlugin {

    static let shared = PastePlugin()

    // MARK: - BuiltinPlugin 契约

    let id = "paste"
    let priority: Int = 150  // 介于 Calculator(200) 与 SystemCommand(100) 之间——确定性触发词匹配
    let sectionTitle = "剪贴板"

    // MARK: - 执行 seam（可注入，用于测试）

    private let copyService: CopyService
    internal let historyService: ClipboardHistoryService  // testable：红队验收测试预填历史数据需访问

    /// 测试注入用 init（不使用默认参数引用 @MainActor 属性，镜像 CalculatorPlugin 风格，
    /// 参考 pattern 2026-06-19-swift-mainactor-shared-default-param-nonisolated）。
    init(historyService: ClipboardHistoryService? = nil,
         copyService: CopyService = .shared) {
        self.copyService = copyService
        // historyService 可注入；nil 默认（生产 resolve 到 .shared）
        self.historyService = historyService ?? ClipboardHistoryService.shared
    }

    // MARK: - 触发词与过滤

    /// 触发词集合（契约边界值：query.lowercased().hasPrefix(trigger)）。
    static let triggers: [String] = ["cb", "clipboard", "剪贴板", "paste"]

    /// 候选预览上限（契约：title.count <= 50，超长截断 + "…"）。
    static let previewLimit = 50

    // MARK: - actions(for:)

    /// query 流程：
    /// - 空 / 不匹配触发词 → `[]`（让位其他插件）
    /// - 匹配但历史为空 → `[]`（边界，反例 query="cb"）
    /// - `cb <filter>` → 触发词 + 过滤词，snapshot(filter:) 过滤
    func actions(for query: String) async -> [LauncherAction] {
        let normalized = query.trimmingCharacters(in: .whitespaces)
        guard !normalized.isEmpty else { return [] }

        let lower = normalized.lowercased()

        // 触发词匹配（hasPrefix）
        guard let trigger = Self.triggers.first(where: { lower.hasPrefix($0) }) else { return [] }

        // 提取过滤词：触发词之后的剩余
        let filter: String?
        if normalized.count > trigger.count {
            // hasPrefix 命中后取剩余（注意 hasPrefix 对中文 "剪贴板" 三字符）
            let rest = String(normalized.dropFirst(trigger.count))
                .trimmingCharacters(in: .whitespaces)
            filter = rest.isEmpty ? nil : rest
        } else {
            filter = nil
        }

        // 读 snapshot（按 filter 过滤）
        let snapshot = historyService.snapshot(filter: filter)

        // 构造候选（每条历史一个 LauncherAction）
        return snapshot.prefix(LauncherConstants.builtinActionsLimit).enumerated().map { idx, item in
            action(for: item, index: idx)
        }
    }

    // MARK: - 候选构造

    private func action(for item: ClipboardHistoryItem, index: Int) -> LauncherAction {
        let title = previewTitle(for: item)
        let subtitle = previewSubtitle(for: item)
        let icon = previewIcon(for: item)

        let copyService = self.copyService
        let perform: () throws -> Void = {
            Self.performCopy(for: item, using: copyService)
        }

        return LauncherAction(
            id: "paste.\(item.id)",
            title: title,
            subtitle: subtitle,
            icon: icon,
            pluginId: self.id,
            // score 按 index 降序（snapshot 已按 ts 倒序，越前越新）
            score: max(1000 - index * 10, 0),
            perform: perform
        )
    }

    /// 候选标题（契约：title.count <= 50，超长截断 + "…"）。
    private func previewTitle(for item: ClipboardHistoryItem) -> String {
        let raw: String
        switch item.type {
        case .text:
            raw = item.content
        case .file:
            // 文件路径取 basename 显示
            raw = (item.content as NSString).lastPathComponent
        case .html:
            // 富文本显示纯文本 fallback
            raw = item.content
        case .image:
            // 图片显示路径 basename 或占位
            if let p = item.imagePath, !p.isEmpty {
                raw = (p as NSString).lastPathComponent
            } else {
                raw = "图片"
            }
        }

        let collapsed = raw.replacingOccurrences(of: "\n", with: " ⏎ ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if collapsed.count <= Self.previewLimit {
            return collapsed.isEmpty ? "(空)" : collapsed
        }
        let end = collapsed.index(collapsed.startIndex, offsetBy: Self.previewLimit - 1)
        return String(collapsed[..<end]) + "…"
    }

    /// 候选副标题（类型 + 来源 app 提示）。
    private func previewSubtitle(for item: ClipboardHistoryItem) -> String {
        let typeLabel: String
        switch item.type {
        case .text: typeLabel = "文本"
        case .file: typeLabel = "文件"
        case .html: typeLabel = "富文本"
        case .image: typeLabel = "图片"
        }
        let app = item.sourceApp ?? "未知"
        return "\(typeLabel) · \(app) · 回车粘贴"
    }

    /// 候选图标：图片类型用 NSImage 加载缩略图；其他用 SF Symbol。
    private func previewIcon(for item: ClipboardHistoryItem) -> NSImage? {
        switch item.type {
        case .image:
            if let path = item.imagePath {
                return NSImage(contentsOfFile: path)
            }
            return NSImage(systemSymbolName: "photo", accessibilityDescription: "图片")
        case .file:
            return NSImage(systemSymbolName: "doc", accessibilityDescription: "文件")
        case .html:
            return NSImage(systemSymbolName: "text.alignleft", accessibilityDescription: "富文本")
        case .text:
            return NSImage(systemSymbolName: "textformat", accessibilityDescription: "文本")
        }
    }

    // MARK: - perform 执行（契约副作用清单）

    /// 按类型回写 NSPasteboard（分类型，参考契约 ## 副作用清单）。
    private static func performCopy(for item: ClipboardHistoryItem, using copyService: CopyService) {
        switch item.type {
        case .text:
            copyService.copy(item.content)
        case .file:
            // 契约：必须 writeObjects([NSURL])，禁用 setString(forType:.fileURL)（Finder 不认）
            let url = URL(fileURLWithPath: item.content)
            copyService.copyFileURL(url)
        case .image:
            // 契约：从 imagePath 读回 PNG data，setData(.png)
            if let path = item.imagePath {
                if let data = try? Data(contentsOf: URL(fileURLWithPath: path)) {
                    copyService.copyImage(data)
                }
            }
        case .html:
            // 契约：clearContents + 同时写 html + 纯文本（不转 RTF，YAGNI）
            if let html = item.html {
                copyService.copyRichText(html: html, plain: item.content)
            } else {
                copyService.copy(item.content)
            }
        }
    }
}
