// Packages/AnnotationKit/Sources/AnnotationKit/Objects/RectangleObject.swift
import Foundation
import CoreGraphics

public final class RectangleObject: AnnotationObject, @unchecked Sendable {
    public let id = ObjectID()
    public var style: StrokeStyle
    public var rect: CGRect
    public var cornerRadius: CGFloat = 0

    public init(rect: CGRect, style: StrokeStyle = StrokeStyle()) {
        self.rect = rect
        self.style = style
    }

    public var bounds: CGRect { rect }

    public func hitTest(point: CGPoint, threshold: CGFloat) -> Bool {
        if style.filled {
            return rect.insetBy(dx: -threshold, dy: -threshold).contains(point)
        }
        let outer = rect.insetBy(dx: -(threshold + style.lineWidth / 2), dy: -(threshold + style.lineWidth / 2))
        let inner = rect.insetBy(dx: threshold + style.lineWidth / 2, dy: threshold + style.lineWidth / 2)
        return outer.contains(point) && !inner.contains(point)
    }

    public func render(in ctx: CGContext) {
        ctx.saveGState()
        ctx.setAlpha(style.opacity)
        let path: CGPath
        if cornerRadius > 0 {
            path = CGPath(roundedRect: rect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
        } else {
            path = CGPath(rect: rect, transform: nil)
        }
        if style.filled {
            ctx.setFillColor(style.color.cgColor)
            ctx.addPath(path); ctx.fillPath()
        } else {
            ctx.setStrokeColor(style.color.cgColor)
            ctx.setLineWidth(style.lineWidth)
            ctx.addPath(path); ctx.strokePath()
        }
        ctx.restoreGState()
    }

    public func move(by delta: CGSize) {
        rect.origin.x += delta.width; rect.origin.y += delta.height
    }

    public func copy() -> any AnnotationObject {
        let c = RectangleObject(rect: rect, style: style)
        c.cornerRadius = cornerRadius
        return c
    }
}
