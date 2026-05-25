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
        let view = LauncherInputViewPreview(manager: manager, initialOutput: output)
        let hostingController = NSHostingController(rootView: view)
        hostingController.view.frame = NSRect(x: 0, y: 0, width: 600, height: 200)
        assertSnapshot(of: hostingController, as: .image(size: CGSize(width: 600, height: 200)))
    }
}

/// 用于快照测试的 preview 包装 view，可注入初始状态
private struct LauncherInputViewPreview: View {
    let manager: LauncherManager
    var initialQuery: String = ""
    var initialOutput: AttributedString?

    @State private var query: String
    @State private var output: AttributedString?

    init(manager: LauncherManager, initialQuery: String = "", initialOutput: AttributedString? = nil) {
        self.manager = manager
        self._query = State(initialValue: initialQuery)
        self._output = State(initialValue: initialOutput)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Ask anything...", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 18))
                .padding(.horizontal, 12).padding(.vertical, 8)
            if query.count >= LauncherConstants.maxQueryLength - 1000 {
                Text("\(query.count) / \(LauncherConstants.maxQueryLength)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(query.count >= LauncherConstants.maxQueryLength ? .red : .secondary)
                    .padding(.horizontal, 12)
            }
            if let out = output {
                Divider()
                ScrollView { Text(out).padding(.horizontal, 12) }
                    .frame(maxHeight: 400)
            }
        }
        .padding(.vertical, 4)
        .background(.regularMaterial)
    }
}
