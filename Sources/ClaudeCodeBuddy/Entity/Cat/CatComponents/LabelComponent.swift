import SpriteKit

// MARK: - LabelComponent

/// Manages all label nodes and alert overlay for a CatEntity.
class LabelComponent {

    // MARK: - Dependencies

    unowned let spriteNode: SKSpriteNode

    // MARK: - Label Node Properties

    private(set) var labelNode: SKLabelNode?
    private(set) var shadowLabelNode: SKLabelNode?
    private(set) var tabNameNode: SKLabelNode?
    private(set) var tabNameShadowNode: SKLabelNode?
    private(set) var alertOverlayNode: SKNode?
    private(set) var tabName: String = ""

    // MARK: - Init

    init(spriteNode: SKSpriteNode) {
        self.spriteNode = spriteNode
    }

    // MARK: - Configuration

    func configure(color: SessionColor, labelText: String) {
        // Create shadow label (behind, for glow effect)
        let shadow = SKLabelNode(text: labelText)
        shadow.fontName = NSFont.boldSystemFont(ofSize: CatConstants.Visual.labelFontSize).fontName
        shadow.fontSize = CatConstants.Visual.labelFontSize
        shadow.fontColor = color.nsColor.withAlphaComponent(CatConstants.Visual.labelShadowAlpha)
        shadow.position = CatConstants.Visual.labelShadowOffset
        shadow.verticalAlignmentMode = .bottom
        shadow.horizontalAlignmentMode = .center
        shadow.zPosition = CatConstants.Visual.labelShadowZPosition
        shadow.isHidden = true
        spriteNode.addChild(shadow)
        shadowLabelNode = shadow

        // Create main label
        let label = SKLabelNode(text: labelText)
        label.fontName = NSFont.boldSystemFont(ofSize: CatConstants.Visual.labelFontSize).fontName
        label.fontSize = CatConstants.Visual.labelFontSize
        label.fontColor = color.nsColor
        label.position = CGPoint(x: 0, y: CatConstants.Visual.labelYOffset)
        label.verticalAlignmentMode = .bottom
        label.horizontalAlignmentMode = .center
        label.zPosition = CatConstants.Visual.labelZPosition
        label.isHidden = true
        spriteNode.addChild(label)
        labelNode = label

        // Record tab name
        tabName = labelText

        // Create tab name shadow (for waiting state)
        let tabShadow = SKLabelNode(text: labelText)
        tabShadow.fontName = NSFont.boldSystemFont(ofSize: CatConstants.Visual.tabLabelFontSize).fontName
        tabShadow.fontSize = CatConstants.Visual.tabLabelFontSize
        tabShadow.fontColor = color.nsColor.withAlphaComponent(CatConstants.Visual.labelShadowAlpha)
        tabShadow.position = CGPoint(x: CatConstants.Visual.labelShadowOffset.x, y: CatConstants.Visual.tabLabelShadowYOffset)
        tabShadow.verticalAlignmentMode = .bottom
        tabShadow.horizontalAlignmentMode = .center
        tabShadow.zPosition = CatConstants.Visual.labelShadowZPosition
        tabShadow.isHidden = true
        spriteNode.addChild(tabShadow)
        tabNameShadowNode = tabShadow

        // Create tab name label (for waiting state)
        let tabLabel = SKLabelNode(text: labelText)
        tabLabel.fontName = NSFont.boldSystemFont(ofSize: CatConstants.Visual.tabLabelFontSize).fontName
        tabLabel.fontSize = CatConstants.Visual.tabLabelFontSize
        tabLabel.fontColor = color.nsColor
        tabLabel.position = CGPoint(x: 0, y: CatConstants.Visual.tabLabelYOffset)
        tabLabel.verticalAlignmentMode = .bottom
        tabLabel.horizontalAlignmentMode = .center
        tabLabel.zPosition = CatConstants.Visual.labelZPosition
        tabLabel.isHidden = true
        spriteNode.addChild(tabLabel)
        tabNameNode = tabLabel
    }

    // MARK: - Label Management

    func updateLabel(_ newLabel: String) {
        labelNode?.text = newLabel
        shadowLabelNode?.text = newLabel
        tabName = newLabel
        tabNameNode?.text = newLabel
        tabNameShadowNode?.text = newLabel
    }

    func showLabel(text: String? = nil) {
        if let text = text {
            // Truncate to avoid Metal texture overflow (max 16384px width)
            let truncated = text.count > CatConstants.Visual.labelMaxLength
                ? String(text.prefix(CatConstants.Visual.labelMaxLength)) + "…"
                : text
            // Only update the tool-description label nodes; do not overwrite tabName
            labelNode?.text = truncated
            shadowLabelNode?.text = truncated
        }
        labelNode?.isHidden = false
        shadowLabelNode?.isHidden = false
    }

    func hideLabel(isDebugCat: Bool) {
        labelNode?.isHidden = true
        shadowLabelNode?.isHidden = true
        if isDebugCat {
            // Debug cats keep tab name visible for identification
            tabNameNode?.isHidden = false
            tabNameShadowNode?.isHidden = false
        } else {
            tabNameNode?.isHidden = true
            tabNameShadowNode?.isHidden = true
        }
    }

    // MARK: - Alert Overlay

    func addAlertOverlay(afterLabel text: String) {
        let overlay = SKNode()
        overlay.zPosition = CatConstants.Visual.alertOverlayZPosition

        // Estimate label width: ~7pt per character at font size 11
        let labelHalfWidth = CGFloat(text.count) * CatConstants.Visual.alertBadgeCharWidth
        let badgeX = labelHalfWidth + CatConstants.Visual.alertBadgeHPadding

        let circle = SKShapeNode(circleOfRadius: CatConstants.Visual.alertBadgeRadius)
        circle.fillColor = CatConstants.Visual.alertBadgeColor
        circle.strokeColor = .white
        circle.lineWidth = CatConstants.Visual.alertBadgeLineWidth
        circle.position = CGPoint(x: badgeX, y: CatConstants.Visual.alertBadgeYOffset)
        overlay.addChild(circle)

        let label = SKLabelNode(text: "!")
        label.fontName = NSFont.boldSystemFont(ofSize: CatConstants.Visual.alertBadgeFontSize).fontName
        label.fontSize = CatConstants.Visual.alertBadgeFontSize
        label.fontColor = .white
        label.verticalAlignmentMode = .center
        label.horizontalAlignmentMode = .center
        label.position = CGPoint(x: badgeX, y: CatConstants.Visual.alertBadgeYOffset)
        overlay.addChild(label)

        // Pulse the badge
        let fadeOut = SKAction.fadeAlpha(to: CatConstants.Animation.badgePulseMinAlpha, duration: CatConstants.Animation.badgeFadeDuration)
        let fadeIn = SKAction.fadeAlpha(to: 1.0, duration: CatConstants.Animation.badgeFadeDuration)
        let pulse = SKAction.repeatForever(SKAction.sequence([fadeOut, fadeIn]))
        overlay.run(pulse)

        spriteNode.addChild(overlay)
        alertOverlayNode = overlay
    }

    func removeAlertOverlay() {
        alertOverlayNode?.removeFromParent()
        alertOverlayNode = nil
    }
}
