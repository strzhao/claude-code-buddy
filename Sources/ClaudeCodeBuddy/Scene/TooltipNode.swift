import SpriteKit

class TooltipNode: SKNode {

    private let labelNode: SKLabelNode
    private let shadowNode: SKLabelNode

    override init() {
        // Shadow label (glow effect)
        shadowNode = SKLabelNode()
        shadowNode.fontName = NSFont.boldSystemFont(ofSize: 10).fontName
        shadowNode.fontSize = 10
        shadowNode.horizontalAlignmentMode = .center
        shadowNode.verticalAlignmentMode = .bottom
        shadowNode.position = CGPoint(x: 1, y: -1)
        shadowNode.zPosition = 0

        // Main label
        labelNode = SKLabelNode()
        labelNode.fontName = NSFont.boldSystemFont(ofSize: 10).fontName
        labelNode.fontSize = 10
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

        let x = max(30, min(catPosition.x, sceneSize.width - 30))
        let y = catPosition.y + 26
        position = CGPoint(x: x, y: y)

        removeAllActions()
        run(SKAction.fadeIn(withDuration: 0.15))
    }

    /// Positions the tooltip either above (default) or below `anchor`, flipping
    /// automatically when the anchor is close to the top of the scene.
    /// Only used by BuddyScene's per-frame tooltip follower.
    func place(at anchor: CGPoint, sceneSize: CGSize,
               aboveOffset: CGFloat = 26,
               belowOffset: CGFloat = 24) {
        let x = max(30, min(anchor.x, sceneSize.width - 30))
        let aboveY = anchor.y + aboveOffset
        if aboveY + 12 <= sceneSize.height {
            labelNode.verticalAlignmentMode = .bottom
            shadowNode.verticalAlignmentMode = .bottom
            shadowNode.position = CGPoint(x: 1, y: -1)
            position = CGPoint(x: x, y: aboveY)
        } else {
            // No room above → flip below the entity (text hangs down).
            labelNode.verticalAlignmentMode = .top
            shadowNode.verticalAlignmentMode = .top
            shadowNode.position = CGPoint(x: 1, y: -1)
            position = CGPoint(x: x, y: anchor.y - belowOffset)
        }
    }

    func hide() {
        removeAllActions()
        run(SKAction.fadeOut(withDuration: 0.15))
    }
}
