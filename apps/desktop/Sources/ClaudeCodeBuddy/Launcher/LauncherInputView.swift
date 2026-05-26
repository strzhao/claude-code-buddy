import SwiftUI

struct LauncherInputView: View {
    @ObservedObject var manager: LauncherManager
    @State private var query: String = ""
    @State private var outputBuffer: String = ""            // 流式累积 markdown 原文
    @State private var rendered: AttributedString?          // 渲染后 markdown
    @State private var isRunning: Bool = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Ask anything...", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 18))
                .padding(.horizontal, 12).padding(.vertical, 8)
                .focused($focused)
                .disabled(isRunning)
                .onSubmit { Task { await submit() } }
                .onChange(of: query) { _, new in
                    if new.count > LauncherConstants.maxQueryLength {
                        query = String(new.prefix(LauncherConstants.maxQueryLength))
                    }
                }
            // 接近上限时显示字数指示（warning UI，契约要求）
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
        .onAppear {
            focused = true
            query = ""
            outputBuffer = ""
            rendered = nil
            isRunning = false
        }
        .onDisappear {
            // 浮窗关闭时取消正在跑的 AsyncStream，避免后台流式继续 yield
            // 通过将 isRunning=false 反向通知（task 内 onTermination 监听）
            isRunning = false
        }
        .onExitCommand { manager.hide() }   // Esc → hide
    }

    private func submit() async {
        let q = query
        await MainActor.run {
            outputBuffer = ""
            rendered = nil
            isRunning = true
        }
        for await event in manager.submit(q) {
            switch event {
            case .text(let s):
                await MainActor.run {
                    outputBuffer += s
                    // 增量渲染：每次累积后用 MarkdownRenderer 渲染整个 buffer
                    rendered = MarkdownRenderer.render(outputBuffer)
                }
            case .toolCall(let name, _):
                await MainActor.run {
                    outputBuffer += "\n> 🔧 调用工具 `\(name)`...\n"
                    rendered = MarkdownRenderer.render(outputBuffer)
                }
            case .toolResult(let name, let output, let isError):
                await MainActor.run {
                    outputBuffer += isError
                        ? "\n> ❌ \(name): \(output)\n"
                        : "\n> ✅ \(name) →\n```\n\(output)\n```\n"
                    rendered = MarkdownRenderer.render(outputBuffer)
                }
            case .done:
                await MainActor.run { isRunning = false; query = "" }
            case .error(let err):
                await MainActor.run {
                    rendered = MarkdownRenderer.renderError(err)
                    isRunning = false
                }
            }
        }
    }
}
