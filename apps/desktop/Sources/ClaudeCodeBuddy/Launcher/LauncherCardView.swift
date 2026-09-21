import SwiftUI

// MARK: - LauncherCardView

/// 限额卡片视图（W3 通用卡片通道 BUDDY_OUTPUT_CARD 的原生渲染，2026-09-21）。
///
/// 视觉规格 = mockup 方案 B（.autopilot/runtime/requirements/20260921-quota插件改名gcli与UI优化/
/// visual/.../ui-style.html，用户浏览器+终端双确认）：
/// - 标题行：smoke 色小字（card.title）
/// - 条目卡片：半透明底 + hairline 边框 + 10pt 圆角；头行 = 状态点(8pt 圆) + 名(bold) + badge(描边 chip)
/// - 窗口行：label(smoke, 定宽) + 进度条(track=mist / fill=状态色, 高 6 圆角 3) +
///   percent(badgeMono 等宽右对齐) + reset(smoke 色，"↻" 前缀)
/// - 状态色：ok=sage（LauncherTheme.primary）/ warn=#E5C15C / danger=红；未知/缺失 level 按 ok 兜底
///
/// 无逐帧动画（纯静态渲染，不涉测试冻结铁律）；所有颜色复用 LauncherTheme token，
/// light/dark 经 dynamic NSColor 自动适配。
struct LauncherCardView: View {
    let card: PluginCard

    /// warn 状态色（mockup #E5C15C，契约钉死字面量）
    static let warnColor = Color(red: 0xE5 / 255, green: 0xC1 / 255, blue: 0x5C / 255)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title = card.title, !title.isEmpty {
                Text(title)
                    .font(LauncherTheme.statusFooter)
                    .foregroundStyle(LauncherTheme.smoke)
            }
            ForEach(Array(card.entries.enumerated()), id: \.offset) { _, entry in
                entryCard(entry)
            }
        }
    }

    // MARK: - 条目卡片

    private func entryCard(_ entry: CardEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            // 头行：状态点 + 名 + badge（右对齐）
            HStack(spacing: 7) {
                Circle()
                    .fill(levelColor(entry.level))
                    .frame(width: 8, height: 8)
                Text(entry.name)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(LauncherTheme.ink)
                    .lineLimit(1)
                if let badge = entry.badge, !badge.isEmpty {
                    Text(badge)
                        .font(.system(size: 11))
                        .foregroundStyle(LauncherTheme.smoke)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 1)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(LauncherTheme.chipBorder, lineWidth: 1)
                        )
                }
                Spacer(minLength: 0)
            }
            ForEach(Array(entry.windows.enumerated()), id: \.offset) { _, window in
                windowRow(window, level: entry.level)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(LauncherTheme.ink.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(LauncherTheme.innerHighlight, lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(entry.name)
    }

    // MARK: - 窗口行（label + 进度条 + percent + reset）

    private func windowRow(_ window: CardWindow, level: String?) -> some View {
        HStack(spacing: 8) {
            Text(window.label)
                .font(.system(size: 12))
                .foregroundStyle(LauncherTheme.smoke)
                .frame(width: 34, alignment: .leading)
            // 进度条：track = mist，fill = 状态色（宽度 = percent%）
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(LauncherTheme.mist)
                    Capsule()
                        .fill(levelColor(level))
                        .frame(width: geo.size.width * CGFloat(window.percent) / 100.0)
                }
            }
            .frame(height: 6)
            Text("\(window.percent)%")
                .font(LauncherTheme.badgeMono)
                .foregroundStyle(LauncherTheme.ink)
                .frame(width: 40, alignment: .trailing)
            if let reset = window.reset, !reset.isEmpty {
                Text("↻ \(reset)")
                    .font(.system(size: 11))
                    .foregroundStyle(LauncherTheme.smoke)
                    .frame(minWidth: 48, alignment: .trailing)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(window.label)")
        .accessibilityValue("\(window.percent)%")
    }

    // MARK: - 状态色

    /// level → 状态色（契约：ok=sage / warn=#E5C15C / danger=红；未知/缺失按 sage 兜底）
    func levelColor(_ level: String?) -> Color {
        switch level {
        case "warn": return Self.warnColor
        case "danger": return Color.red
        default: return LauncherTheme.primary
        }
    }
}
