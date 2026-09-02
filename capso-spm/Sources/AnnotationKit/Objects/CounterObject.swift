// Packages/AnnotationKit/Sources/AnnotationKit/Objects/CounterObject.swift
import Foundation
import CoreGraphics
import AppKit

public final class CounterObject: AnnotationObject, @unchecked Sendable {
    public let id = ObjectID()
    public var style: StrokeStyle
    public var center: CGPoint
    public var radius: CGFloat
    public var number: Int

    public init(center: CGPoint, number: Int, radius: CGFloat = 20, style: StrokeStyle = StrokeStyle()) {
        self.center = center
        self.number = number
        self.radius = radius
        self.style = style
    }

    public var bounds: CGRect {
        CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
    }

    public func hitTest(point: CGPoint, threshold: CGFloat) -> Bool {
        let distance = hypot(point.x - center.x, point.y - center.y)
        return distance <= radius + threshold
    }

    public func render(in ctx: CGContext) {
        let circleRect = bounds

        ctx.saveGState()
        ctx.setFillColor(style.color.cgColor)
        ctx.fillEllipse(in: circleRect)
        ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.25))
        ctx.setLineWidth(1.5)
        ctx.strokeEllipse(in: circleRect)
        ctx.restoreGState()

        let text = "\(number)" as NSString
        let fontSize: CGFloat = number < 10 ? radius * 1.1 : radius * 0.85
        let font = NSFont.systemFont(ofSize: fontSize, weight: .bold)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white,
        ]
        let textSize = text.size(withAttributes: attributes)
        let textOrigin = CGPoint(
            x: center.x - textSize.width / 2,
            y: center.y - textSize.height / 2
        )

        let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsCtx
        text.draw(at: textOrigin, withAttributes: attributes)
        NSGraphicsContext.restoreGraphicsState()
    }

    public func move(by delta: CGSize) {
        center.x += delta.width
        center.y += delta.height
    }

    public func copy() -> any AnnotationObject {
        CounterObject(center: center, number: number, radius: radius, style: style)
    }
}
