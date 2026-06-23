import AppKit

// MARK: - SageSwitch
//
// 完全自绘的 sage 开关（NSView + CALayer）。
//
// 背景：macOS NSSwitch **无任何公开 tint/color API**（Apple 文档 + Stack Overflow + Sir Studio +
// WebSearch 四次确认）。开态由私有 NSWidgetView 渲染，只读系统级 accent，不受 Asset Catalog
// AccentColor / app 域 AppleAccentColor / SwiftUI Toggle.tint 嵌入影响（均已实测失败）。
// sage 自定义色的唯一可靠方案：完全自绘 NSView，画 track（on=sage/off=灰）+ knob（白圆），
// 点击切换 + 动画。供 SettingsToggleRow 使用。
final class SageSwitch: NSView {

    private let trackLayer = CALayer()
    private let knobLayer = CALayer()
    private var isOn: Bool

    /// 状态变化回调（newState: Bool，仅用户点击触发）。
    var onChange: ((Bool) -> Void)?

    init(isOn: Bool) {
        self.isOn = isOn
        super.init(frame: NSRect(x: 0, y: 0, width: 32, height: 20))
        setupLayers()
        applyState(animated: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupLayers() {
        wantsLayer = true
        trackLayer.cornerRadius = bounds.height / 2
        layer?.addSublayer(trackLayer)

        knobLayer.backgroundColor = NSColor.white.cgColor
        knobLayer.shadowColor = NSColor.black.cgColor
        knobLayer.shadowOpacity = 0.15
        knobLayer.shadowRadius = 1
        knobLayer.shadowOffset = CGSize(width: 0, height: -1)
        layer?.addSublayer(knobLayer)

        // Accessibility（替代 NSSwitch 的 AX 行为）
        setAccessibilityRole(.checkBox)
    }

    /// 外部同步状态（不触发 onChange）。
    func setState(_ on: Bool) {
        guard isOn != on else { return }
        isOn = on
        applyState(animated: false)
    }

    private func applyState(animated: Bool) {
        // sage 是 dynamic NSColor；cgColor 取当前 appearance 快照，viewDidChangeEffectiveAppearance 时刷新
        let trackColor = isOn
            ? SettingsTheme.accent.cgColor
            : NSColor.tertiaryLabelColor.withAlphaComponent(0.25).cgColor
        let knobSize = bounds.height - 4
        let knobOriginX = isOn ? bounds.width - knobSize - 2 : 2

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = animated ? 0.18 : 0
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            trackLayer.backgroundColor = trackColor
            knobLayer.frame = CGRect(x: knobOriginX, y: 2, width: knobSize, height: knobSize)
        }, completionHandler: nil)

        trackLayer.cornerRadius = bounds.height / 2
        knobLayer.cornerRadius = knobSize / 2
        setAccessibilityValue(isOn ? 1 : 0)
    }

    override func layout() {
        super.layout()
        trackLayer.frame = bounds
        trackLayer.cornerRadius = bounds.height / 2
        let knobSize = bounds.height - 4
        let knobOriginX = isOn ? bounds.width - knobSize - 2 : 2
        knobLayer.frame = CGRect(x: knobOriginX, y: 2, width: knobSize, height: knobSize)
        knobLayer.cornerRadius = knobSize / 2
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyState(animated: false)
    }

    override func mouseDown(with event: NSEvent) {
        isOn.toggle()
        applyState(animated: true)
        onChange?(isOn)
    }
}
