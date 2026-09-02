import SwiftUI

/// 锁定插件 chip（D5，C-TAB-LOCK 参数态视觉反馈）。
///
/// 参数输入态（`lockedCommand != nil`）下显示：sage 强调色 + 锁图标 +
/// 「已锁定: name」文案，让用户清楚当前 Enter 会以 locked 插件执行（C-LOCK-STICKY 视觉锚）。
/// AX id `locked-command-chip` 不变（契约冻结）。输入框右上角唯一 chip（watermark chip 已退役）。
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
