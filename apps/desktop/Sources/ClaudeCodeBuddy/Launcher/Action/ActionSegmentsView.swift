import SwiftUI

/// Renders a `[ActionSegment]` array:
/// - `.text` segments → attributed `Text` via `MarkdownRenderer.render()`
/// - `.action` segments → inline `ActionButton`
///
/// Layout strategy: segments are laid out in a `VStack` (line-per-segment).
/// This avoids the complexity of a full inline flow layout while still giving
/// a readable result. Text blocks keep Markdown rendering; action buttons are
/// rendered between them.
struct ActionSegmentsView: View {
    let segments: [ActionSegment]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, seg in
                segmentView(for: seg)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func segmentView(for seg: ActionSegment) -> some View {
        switch seg {
        case .text(let raw):
            Text(MarkdownRenderer.render(raw))
                .font(LauncherTheme.outputBody)
                .foregroundStyle(LauncherTheme.ink)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        case .action(let handler, let text, let label):
            ActionButton(handler: handler, text: text, label: label)
        }
    }
}
