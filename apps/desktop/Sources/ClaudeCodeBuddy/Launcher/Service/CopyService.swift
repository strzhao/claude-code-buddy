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
}
