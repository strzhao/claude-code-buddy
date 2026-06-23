import AppKit
import Foundation

/// NSPasteboard wrapper.  Singleton for production; inject a named pasteboard in tests.
final class CopyService {
    static let shared = CopyService(pasteboard: .general)

    private let pasteboard: NSPasteboard

    /// - Parameter pasteboard: injectable for tests.  Use
    ///   `NSPasteboard(name: NSPasteboard.Name("ccb-test-\(UUID())"))` for isolation.
    init(pasteboard: NSPasteboard) {
        self.pasteboard = pasteboard
    }

    /// Writes `text` to the pasteboard.  Silently ignores failures (C5 contract).
    func copy(_ text: String) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// Writes PNG `data` to the pasteboard（图片输出通道，T6 / 场景3.P1）。
    /// 契约：`clearContents()` + `setData(data, forType: .png)`，用户点击浮窗图片时调用。
    func copyImage(_ data: Data) {
        pasteboard.clearContents()
        pasteboard.setData(data, forType: .png)
    }

    /// Writes a file URL to the pasteboard（剪贴板历史文件路径回写，契约 ## 副作用清单）。
    ///
    /// 契约：必须 `writeObjects([url as NSURL])`，**禁用** `setString(forType:.fileURL)`
    /// （Finder 不认后者）。参考 plan-reviewer 重要问题 #1。
    func copyFileURL(_ url: URL) {
        pasteboard.clearContents()
        pasteboard.writeObjects([url as NSURL])
    }

    /// Writes rich text (HTML + plain fallback) to the pasteboard（剪贴板历史富文本回写）。
    ///
    /// 契约：`clearContents()` + 同时 `setString(html, forType:.html)` + `setString(plain, forType:.string)`
    /// （不转 RTF，YAGNI）。
    func copyRichText(html: String, plain: String) {
        pasteboard.clearContents()
        pasteboard.setString(html, forType: .html)
        pasteboard.setString(plain, forType: .string)
    }
}
