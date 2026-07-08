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
    private(set) var isOn: Bool

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

    /// 固定内在尺寸（契约 C-SWITCH-INTRINSIC）。
    ///
    /// `translatesAutoresizingMaskIntoConstraints = true` 的宿主用 intrinsicContentSize 撑开 32×20；
    /// = false 的宿主（如 PluginListCellView / SettingsToggleRow）需显式 width/height 约束（C-SWITCH-SIZE），
    /// 但覆盖此属性仍是治本兜底——避免 Auto Layout 解析为 0×0 致 CALayer 无绘制区 + hitTest 不命中。
    override var intrinsicContentSize: NSSize { NSSize(width: 32, height: 20) }

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

    // MARK: - 非 key window 点击兜底（R2）
    //
    // LSUIElement accessory app 下设置窗口可能非 key window，Cocoa 事件架构规定：
    // 非 key 窗口的第一次 mouseDown 被系统吞掉用于激活窗口，到不了 view（官方 Event-Handling Guide）。
    // override acceptsFirstMouse 返回 true → 告诉 AppKit「即使窗口非 key，本 view 也响应首击」。
    // 这是治标 safety net：让 switch 在窗口未 key 时也能点；治本（窗口真 key）靠 activation policy。
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        toggle()
    }

    /// 程序化切换开关（测试 seam，模拟用户点击）。
    func toggle() {
        isOn.toggle()
        applyState(animated: true)
        onChange?(isOn)
    }
}
