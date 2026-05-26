import XCTest
import SwiftUI
import SnapshotTesting
@testable import BuddyCore

@MainActor
final class LauncherWindowSnapshotTests: XCTestCase {

    func test_LauncherInputView_emptyState() {
        let manager = LauncherManager.shared
        let view = LauncherInputView(manager: manager)
        let hostingController = NSHostingController(rootView: view)
        hostingController.view.frame = NSRect(x: 0, y: 0, width: 600, height: 80)
        assertSnapshot(of: hostingController, as: .image(size: CGSize(width: 600, height: 80)))
    }

    func test_LauncherInputView_withQuery() {
        let manager = LauncherManager.shared
        // We create a view with a pre-set query via a wrapper
        let view = LauncherInputViewPreview(manager: manager, initialQuery: "hello")
        let hostingController = NSHostingController(rootView: view)
        hostingController.view.frame = NSRect(x: 0, y: 0, width: 600, height: 80)
        assertSnapshot(of: hostingController, as: .image(size: CGSize(width: 600, height: 80)))
    }

    func test_LauncherInputView_withOutput() {
        let manager = LauncherManager.shared
        let output = AttributedString("echo: test")
        let view = LauncherInputViewPreview(manager: manager, initialRendered: output)
        let hostingController = NSHostingController(rootView: view)
        hostingController.view.frame = NSRect(x: 0, y: 0, width: 600, height: 200)
        assertSnapshot(of: hostingController, as: .image(size: CGSize(width: 600, height: 200)))
    }
}

/// 用于快照测试的 preview 包装 view，可注入初始状态
/// task 003 适配：新增 outputBuffer + rendered + isRunning 三状态字段
private struct LauncherInputViewPreview: View {
    let manager: LauncherManager
    var initialQuery: String = ""
    var initialRendered: AttributedString?
    var initialIsRunning: Bool = false

    @State private var query: String
    @State private var outputBuffer: String
    @State private var rendered: AttributedString?
    @State private var isRunning: Bool

    init(
        manager: LauncherManager,
        initialQuery: String = "",
        initialRendered: AttributedString? = nil,
        initialIsRunning: Bool = false
    ) {
        self.manager = manager
        self._query = State(initialValue: initialQuery)
        self._outputBuffer = State(initialValue: "")
        self._rendered = State(initialValue: initialRendered)
        self._isRunning = State(initialValue: initialIsRunning)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Ask anything...", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 18))
                .padding(.horizontal, 12).padding(.vertical, 8)
                .disabled(isRunning)
            if query.count >= LauncherConstants.maxQueryLength - 1000 {
                Text("\(query.count) / \(LauncherConstants.maxQueryLength)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(query.count >= LauncherConstants.maxQueryLength ? .red : .secondary)
                    .padding(.horizontal, 12)
            }
            if let out = rendered {
                Divider()
                ScrollView { Text(out).textSelection(.enabled).padding(.horizontal, 12) }
                    .frame(maxHeight: 400)
            }
        }
        .padding(.vertical, 4)
        .background(.regularMaterial)
    }
}
