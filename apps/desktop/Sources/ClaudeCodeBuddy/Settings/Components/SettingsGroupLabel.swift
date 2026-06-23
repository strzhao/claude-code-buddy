import AppKit

// MARK: - SettingsGroupLabel

/// 分组小标题（A3，对标系统设置分组标题如「通用」「系统」）。
///
/// 11pt medium + secondaryLabelColor，带底部留白。
final class SettingsGroupLabel: NSTextField {

    init(title: String) {
        super.init(frame: .zero)
        stringValue = title
        font = SettingsTheme.groupLabelFont()
        textColor = SettingsTheme.footnoteColor()
        isEditable = false
        isBezeled = false
        drawsBackground = false
        isSelectable = false
        translatesAutoresizingMaskIntoConstraints = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
