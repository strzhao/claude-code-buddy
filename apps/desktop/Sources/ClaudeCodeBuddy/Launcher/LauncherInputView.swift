import SwiftUI

struct LauncherInputView: View {
    @ObservedObject var manager: LauncherManager
    @State private var query: String = ""
    @State private var output: AttributedString?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Ask anything...", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 18))
                .padding(.horizontal, 12).padding(.vertical, 8)
                .focused($focused)
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
            if let out = output {
                Divider()
                ScrollView { Text(out).padding(.horizontal, 12) }
                    .frame(maxHeight: 400)
            }
        }
        .padding(.vertical, 4)
        .background(.regularMaterial)
        .onAppear { focused = true; query = ""; output = nil }
        .onExitCommand { manager.hide() }   // Esc → hide
    }

    private func submit() async {
        let q = query
        let result = await manager.submit(q)
        await MainActor.run { output = result; query = "" }
    }
}
