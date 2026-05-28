import XCTest
import SwiftUI
import SnapshotTesting
@testable import BuddyCore

@MainActor
final class LauncherWindowSnapshotTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // isRecording = true  // 重录基线时取消注释
    }

    func test_LauncherInputView_emptyState() {
        let manager = LauncherManager.shared
        let view = LauncherInputView(manager: manager)
        let hostingController = NSHostingController(rootView: view)
        hostingController.view.frame = NSRect(x: 0, y: 0, width: 720, height: 90)
        assertSnapshot(of: hostingController, as: .image(size: CGSize(width: 720, height: 90)))
    }

    func test_LauncherInputView_withQuery() {
        let manager = LauncherManager.shared
        // We create a view with a pre-set query via a wrapper
        let view = LauncherInputViewPreview(manager: manager, initialQuery: "hello", previewHeight: 90)
        let hostingController = NSHostingController(rootView: view)
        hostingController.view.frame = NSRect(x: 0, y: 0, width: 720, height: 90)
        assertSnapshot(of: hostingController, as: .image(size: CGSize(width: 720, height: 90)))
    }

    func test_LauncherInputView_withOutput() {
        let manager = LauncherManager.shared
        let output = AttributedString("echo: test")
        let view = LauncherInputViewPreview(manager: manager, initialRendered: output, previewHeight: 200)
        let hostingController = NSHostingController(rootView: view)
        hostingController.view.frame = NSRect(x: 0, y: 0, width: 720, height: 200)
        assertSnapshot(of: hostingController, as: .image(size: CGSize(width: 720, height: 200)))
    }
}

/// 用于快照测试的 preview 包装 view，可注入初始状态
private struct LauncherInputViewPreview: View {
    let manager: LauncherManager
    var initialQuery: String = ""
    var initialRendered: AttributedString?
    var initialIsRunning: Bool = false
    var previewHeight: CGFloat = 90

    @State private var query: String
    @State private var outputBuffer: String
    @State private var rendered: AttributedString?
    @State private var isRunning: Bool

    init(
        manager: LauncherManager,
        initialQuery: String = "",
        initialRendered: AttributedString? = nil,
        initialIsRunning: Bool = false,
        previewHeight: CGFloat = 90
    ) {
        self.manager = manager
        self._query = State(initialValue: initialQuery)
        self._outputBuffer = State(initialValue: "")
        self._rendered = State(initialValue: initialRendered)
        self._isRunning = State(initialValue: initialIsRunning)
        self.previewHeight = previewHeight
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField("Ask anything...", text: $query)
                .textFieldStyle(.plain)
                .font(LauncherTheme.bodyText)
                .foregroundStyle(LauncherTheme.ink)
                .padding(.horizontal, LauncherConstants.inputPaddingH)
                .padding(.vertical, LauncherConstants.inputPaddingV)
                .frame(maxWidth: .infinity, alignment: .leading)
                .disabled(isRunning)
            if query.count >= LauncherConstants.maxQueryLength - 1000 {
                Text("\(query.count) / \(LauncherConstants.maxQueryLength)")
                    .font(LauncherTheme.footerMono)
                    .foregroundStyle(query.count >= LauncherConstants.maxQueryLength
                        ? Color.red : LauncherTheme.smoke)
                    .padding(.horizontal, LauncherConstants.inputPaddingH)
                    .padding(.bottom, 4)
            }
            if let out = rendered {
                LauncherTheme.borderPixel.opacity(0.4)
                    .frame(height: 1)
                ScrollView {
                    Text(out)
                        .font(LauncherTheme.outputBody)
                        .foregroundStyle(LauncherTheme.ink)
                        .textSelection(.enabled)
                        .padding(.horizontal, LauncherConstants.inputPaddingH)
                        .padding(.vertical, 12)
                }
                .frame(maxHeight: LauncherConstants.outputMaxHeight)
                .background(LauncherTheme.surface)
            }
        }
        .frame(
            width: LauncherConstants.windowWidth,
            height: previewHeight,
            alignment: .top
        )
        .background(
            RoundedRectangle(cornerRadius: LauncherTheme.panelCornerRadius)
                .fill(LauncherTheme.canvas)
                .overlay(
                    RoundedRectangle(cornerRadius: LauncherTheme.panelCornerRadius)
                        .strokeBorder(LauncherTheme.borderPixel,
                                      lineWidth: LauncherTheme.pixelBorderWidth)
                )
        )
        .shadow(color: LauncherTheme.shadowPixel, radius: 0,
                x: LauncherTheme.pixelShadowOffset.width,
                y: LauncherTheme.pixelShadowOffset.height)
    }
}
