import SwiftUI

/// Inline watermark chip shown in the input field's top-right area when a plugin is active.
/// Displays the plugin name in small grey monospaced text with a 1px border.
struct PluginWatermarkChip: View {
    let name: String

    var body: some View {
        Text(name)
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(LauncherTheme.chipText)
            .padding(.vertical, 2)
            .padding(.horizontal, 7)
            .background(Color.clear)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(LauncherTheme.chipBorder, lineWidth: 1)
            )
            .accessibilityIdentifier("plugin-watermark-chip")
    }
}
