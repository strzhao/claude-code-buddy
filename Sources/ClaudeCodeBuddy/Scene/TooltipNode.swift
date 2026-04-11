import SpriteKit

class TooltipNode: SKNode {

    private let backgroundNode: SKShapeNode
    private let colorDot: SKShapeNode
    private let labelText: SKLabelNode
    private let stateText: SKLabelNode
    private let cwdText: SKLabelNode
    private let pidText: SKLabelNode
    private let hintText: SKLabelNode

    private let tooltipWidth: CGFloat = 240
    private let tooltipHeight: CGFloat = 90
    private let padding: CGFloat = 8

    override init() {
        // Background
        let rect = CGRect(x: 0, y: 0, width: tooltipWidth, height: tooltipHeight)
        backgroundNode = SKShapeNode(rect: rect, cornerRadius: 6)
        backgroundNode.fillColor = NSColor(white: 0.1, alpha: 0.85)
        backgroundNode.strokeColor = NSColor(white: 0.3, alpha: 0.5)
        backgroundNode.lineWidth = 0.5

        // Color dot
        colorDot = SKShapeNode(circleOfRadius: 5)
        colorDot.position = CGPoint(x: padding + 5, y: tooltipHeight - padding - 12)

        // Label
        labelText = SKLabelNode()
        labelText.fontName = NSFont.boldSystemFont(ofSize: 12).fontName
        labelText.fontSize = 12
        labelText.fontColor = .white
        labelText.horizontalAlignmentMode = .left
        labelText.verticalAlignmentMode = .center
        labelText.position = CGPoint(x: padding + 16, y: tooltipHeight - padding - 12)

        // State badge
        stateText = SKLabelNode()
        stateText.fontName = NSFont.systemFont(ofSize: 10).fontName
        stateText.fontSize = 10
        stateText.fontColor = NSColor(white: 0.7, alpha: 1)
        stateText.horizontalAlignmentMode = .right
        stateText.verticalAlignmentMode = .center
        stateText.position = CGPoint(x: tooltipWidth - padding, y: tooltipHeight - padding - 12)

        // cwd
        cwdText = SKLabelNode()
        cwdText.fontName = NSFont.monospacedSystemFont(ofSize: 9, weight: .regular).fontName
        cwdText.fontSize = 9
        cwdText.fontColor = NSColor(white: 0.6, alpha: 1)
        cwdText.horizontalAlignmentMode = .left
        cwdText.verticalAlignmentMode = .center
        cwdText.position = CGPoint(x: padding, y: tooltipHeight - padding - 32)

        // PID + time
        pidText = SKLabelNode()
        pidText.fontName = NSFont.systemFont(ofSize: 9).fontName
        pidText.fontSize = 9
        pidText.fontColor = NSColor(white: 0.5, alpha: 1)
        pidText.horizontalAlignmentMode = .left
        pidText.verticalAlignmentMode = .center
        pidText.position = CGPoint(x: padding, y: tooltipHeight - padding - 48)

        // Hint
        hintText = SKLabelNode()
        hintText.fontName = NSFont.systemFont(ofSize: 9).fontName
        hintText.fontSize = 9
        hintText.fontColor = NSColor(white: 0.4, alpha: 1)
        hintText.horizontalAlignmentMode = .left
        hintText.verticalAlignmentMode = .center
        hintText.text = "点击跳转到终端窗口"
        hintText.position = CGPoint(x: padding, y: padding + 4)

        super.init()

        alpha = 0
        zPosition = 100

        addChild(backgroundNode)
        addChild(colorDot)
        addChild(labelText)
        addChild(stateText)
        addChild(cwdText)
        addChild(pidText)
        addChild(hintText)
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(info: SessionInfo, at catPosition: CGPoint, sceneSize: CGSize) {
        // Update content
        colorDot.fillColor = info.color.nsColor
        colorDot.strokeColor = info.color.nsColor
        labelText.text = info.label
        stateText.text = info.state.rawValue
        cwdText.text = info.cwd ?? "—"

        let timeAgo = Int(Date().timeIntervalSince(info.lastActivity))
        let pidStr = info.pid != nil ? "PID \(info.pid!)" : "PID —"
        pidText.text = "\(pidStr) · \(timeAgo)s ago"

        // Position above cat, clamped to scene bounds
        var x = catPosition.x - tooltipWidth / 2
        let y = catPosition.y + 40
        x = max(4, min(x, sceneSize.width - tooltipWidth - 4))
        position = CGPoint(x: x, y: y)

        // Fade in
        removeAllActions()
        run(SKAction.fadeIn(withDuration: 0.15))
    }

    func hide() {
        removeAllActions()
        run(SKAction.fadeOut(withDuration: 0.15))
    }
}
