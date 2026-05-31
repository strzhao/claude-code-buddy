import SwiftUI

/// 单个 action 按钮（底部工具条用）。Raycast/HIG 风格：圆角胶囊、毛玻璃上的轻填充、sage 文字。
/// 点击触发真实动作（朗读/复制）；copy 点击后短暂反馈「已复制」。
struct LauncherActionChip: View {
    let action: LauncherActionButton

    @State private var justCopied = false
    @State private var hovering = false

    private var displayLabel: String {
        if action.kind == .copy && justCopied { return "✓ 已复制" }
        return action.label
    }

    var body: some View {
        Button(action: perform) {
            Text(displayLabel)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(LauncherTheme.primary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    Capsule(style: .continuous)
                        .fill(LauncherTheme.primary.opacity(hovering ? 0.18 : 0.10))
                )
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(LauncherTheme.primary.opacity(0.22), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityIdentifier(action.kind == .speak ? "speak-button" : "copy-button")
    }

    @MainActor
    private func perform() {
        switch action.kind {
        case .speak:
            SpeechService.shared.speak(action.text)
        case .copy:
            CopyService.shared.copy(action.text)
            justCopied = true
            // 1.4s 后复位文案（纯视觉反馈，无副作用）
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                justCopied = false
            }
        }
    }
}

/// 底部统一工具条：把模型声明的所有 attach_action 按钮横向排成一行（可换行），
/// 与正文用 1px hairline 分隔。正文走干净 markdown 连续渲染，按钮全部收在这里——
/// 替代旧的「每个按钮单占一行」碎块布局。
struct LauncherActionBar: View {
    let actions: [LauncherActionButton]

    var body: some View {
        if !actions.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Color(nsColor: .separatorColor)
                    .frame(height: 1)
                ActionChipFlow(actions: actions)
                    .padding(.horizontal, LauncherConstants.inputPaddingH)
                    .padding(.vertical, 10)
            }
            .accessibilityIdentifier("launcher-action-bar")
        }
    }
}

/// 横向流式排列 chips，超宽自动换行（基于 SwiftUI Layout，避免固定列数）。
private struct ActionChipFlow: View {
    let actions: [LauncherActionButton]

    var body: some View {
        FlowLayout(spacing: 8) {
            ForEach(actions) { action in
                LauncherActionChip(action: action)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 极简 flow 布局：从左到右排，行满换行。用于按钮工具条这种数量少、不需要精细对齐的场景。
private struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rows: [[CGSize]] = [[]]
        var rowWidth: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if rowWidth + size.width > maxWidth && !rows[rows.count - 1].isEmpty {
                rows.append([])
                rowWidth = 0
            }
            rows[rows.count - 1].append(size)
            rowWidth += size.width + spacing
        }
        let height = rows.reduce(CGFloat(0)) { acc, row in
            acc + (row.map(\.height).max() ?? 0) + spacing
        } - (rows.isEmpty ? 0 : spacing)
        return CGSize(width: maxWidth == .infinity ? rowWidth : maxWidth, height: max(0, height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        let maxWidth = bounds.width
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > bounds.minX + maxWidth && x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            sub.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
