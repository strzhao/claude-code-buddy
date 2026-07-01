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

/// 锁定 command chip（方案 B 两阶段，参数态视觉反馈）。
///
/// 参数输入态（`lockedCommand != nil`）下替代 watermark chip：sage 强调色 + 锁图标 +
/// 「已锁定: name」文案，让用户清楚当前 Enter 会以 locked 插件执行（C-LOCK-STICKY 视觉锚）。
struct LockedCommandChip: View {
    let name: String

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "lock.fill")
                .font(.system(size: 9))
            Text("已锁定: \(name)")
                .font(.system(size: 11, design: .monospaced))
        }
        .foregroundStyle(LauncherTheme.selectionTint)
        .padding(.vertical, 2)
        .padding(.horizontal, 7)
        .background(LauncherTheme.selectionTint.opacity(0.10))
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(LauncherTheme.selectionTint.opacity(0.45), lineWidth: 1)
        )
        .accessibilityIdentifier("locked-command-chip")
        .accessibilityLabel("已锁定插件 \(name)，回车执行")
    }
}
