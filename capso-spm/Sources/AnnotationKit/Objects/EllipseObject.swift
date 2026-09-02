// Packages/AnnotationKit/Sources/AnnotationKit/Objects/EllipseObject.swift
import Foundation
import CoreGraphics

public final class EllipseObject: AnnotationObject, @unchecked Sendable {
    public let id = ObjectID()
    public var style: StrokeStyle
    public var rect: CGRect

    public init(rect: CGRect, style: StrokeStyle = StrokeStyle()) {
        self.rect = rect
        self.style = style
    }

    public var bounds: CGRect { rect }

    public func hitTest(point: CGPoint, threshold: CGFloat) -> Bool {
        let cx = rect.midX, cy = rect.midY
        let rx = rect.width / 2, ry = rect.height / 2
        guard rx > 0, ry > 0 else { return false }
        let dx = point.x - cx, dy = point.y - cy
        let norm = (dx * dx) / (rx * rx) + (dy * dy) / (ry * ry)
        if style.filled { return norm <= 1.0 + threshold / min(rx, ry) }
        return abs(norm - 1.0) <= (threshold + style.lineWidth / 2) / min(rx, ry)
    }

    public func render(in ctx: CGContext) {
        ctx.saveGState()
        ctx.setAlpha(style.opacity)
        if style.filled {
            ctx.setFillColor(style.color.cgColor); ctx.fillEllipse(in: rect)
        } else {
            ctx.setStrokeColor(style.color.cgColor); ctx.setLineWidth(style.lineWidth); ctx.strokeEllipse(in: rect)
        }
        ctx.restoreGState()
    }

    public func move(by delta: CGSize) {
        rect.origin.x += delta.width; rect.origin.y += delta.height
    }

    public func copy() -> any AnnotationObject {
        EllipseObject(rect: rect, style: style)
    }
}
