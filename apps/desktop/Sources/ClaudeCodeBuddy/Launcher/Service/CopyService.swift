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
}
