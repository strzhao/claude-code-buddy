import SwiftUI

/// Inline action button rendered for each `.action` segment in the output area.
/// Supports `speak` (calls SpeechService) and `copy` (calls CopyService).
struct ActionButton: View {
    let handler: ActionHandler
    let text: String
    let label: String

    /// accessibility identifier suffix used in tests
    private var identifier: String {
        switch handler {
        case .speak: return "speak-button"
        case .copy:  return "copy-button"
        }
    }

    var body: some View {
        Button(action: performAction) {
            Text(label)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color.secondary.opacity(0.15))
                )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
    }

    @MainActor
    private func performAction() {
        switch handler {
        case .speak:
            SpeechService.shared.speak(text)
        case .copy:
            CopyService.shared.copy(text)
        }
    }
}
