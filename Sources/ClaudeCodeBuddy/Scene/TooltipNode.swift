import SpriteKit

class TooltipNode: SKNode {

    private let labelNode: SKLabelNode
    private let shadowNode: SKLabelNode

    override init() {
        // Shadow label (glow effect)
        shadowNode = SKLabelNode()
        shadowNode.fontName = NSFont.boldSystemFont(ofSize: 14).fontName
        shadowNode.fontSize = 14
        shadowNode.horizontalAlignmentMode = .center
        shadowNode.verticalAlignmentMode = .bottom
        shadowNode.position = CGPoint(x: 1, y: -1)
        shadowNode.zPosition = 0

        // Main label
        labelNode = SKLabelNode()
        labelNode.fontName = NSFont.boldSystemFont(ofSize: 14).fontName
        labelNode.fontSize = 14
        labelNode.horizontalAlignmentMode = .center
        labelNode.verticalAlignmentMode = .bottom
        labelNode.zPosition = 1

        super.init()

        alpha = 0
        zPosition = 100

        addChild(shadowNode)
        addChild(labelNode)
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(label: String, color: SessionColor, at catPosition: CGPoint, sceneSize: CGSize) {
        labelNode.text = label
        labelNode.fontColor = color.nsColor
        shadowNode.text = label
        shadowNode.fontColor = color.nsColor.withAlphaComponent(0.4)

        // Position above cat head
        let x = max(30, min(catPosition.x, sceneSize.width - 30))
        let y = catPosition.y + 26
        position = CGPoint(x: x, y: y)

        removeAllActions()
        run(SKAction.fadeIn(withDuration: 0.15))
    }

    func hide() {
        removeAllActions()
        run(SKAction.fadeOut(withDuration: 0.15))
    }
}
