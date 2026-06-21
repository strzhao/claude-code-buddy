import SpriteKit

/// SKView 子类，用 NSTrackingArea 替代全局鼠标监听以降低 CPU 占用。
/// 重写 mouseMoved/mouseEntered/mouseExited 通过回调将事件传递给 MouseTracker。
final class BuddySKView: SKView {

    var onMouseMoved: ((NSEvent) -> Void)?
    var onMouseEntered: (() -> Void)?
    var onMouseExited: (() -> Void)?

    override func mouseMoved(with event: NSEvent) {
        onMouseMoved?(event)
    }

    override func mouseEntered(with event: NSEvent) {
        onMouseEntered?()
    }

    override func mouseExited(with event: NSEvent) {
        onMouseExited?()
    }

    override func updateTrackingAreas() {
        // 移除旧 tracking area 再添加新的，避免子视图变化时残留
        trackingAreas.forEach { removeTrackingArea($0) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
    }
}
