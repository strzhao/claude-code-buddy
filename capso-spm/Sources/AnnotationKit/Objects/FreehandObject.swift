import Foundation
import CoreGraphics

public final class FreehandObject: AnnotationObject, @unchecked Sendable {
    public let id = ObjectID()
    public var style: StrokeStyle
    public var points: [CGPoint]
    private var _cachedPath: CGPath?

    public init(points: [CGPoint] = [], style: StrokeStyle = StrokeStyle()) {
        self.points = points
        self.style = style
    }

    public func addPoint(_ point: CGPoint) {
        points.append(point)
        _cachedPath = nil
    }

    /// Invalidate cached smoothed path after external point mutations.
    public func invalidateCache() {
        _cachedPath = nil
    }

    private var smoothPath: CGPath {
        if let cached = _cachedPath { return cached }
        let path = BezierSmoothing.smoothPath(from: points)
        _cachedPath = path
        return path
    }

    public var bounds: CGRect {
        smoothPath.boundingBoxOfPath.insetBy(dx: -style.lineWidth, dy: -style.lineWidth)
    }

    public func hitTest(point: CGPoint, threshold: CGFloat) -> Bool {
        let strokedPath = smoothPath.copy(
            strokingWithWidth: style.lineWidth + threshold * 2,
            lineCap: .round, lineJoin: .round, miterLimit: 0
        )
        return strokedPath.contains(point)
    }

    public func render(in ctx: CGContext) {
        ctx.saveGState()
        ctx.setStrokeColor(style.color.cgColor)
        ctx.setLineWidth(style.lineWidth)
        ctx.setAlpha(style.opacity)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.addPath(smoothPath)
        ctx.strokePath()
        ctx.restoreGState()
    }

    public func move(by delta: CGSize) {
        for i in 0..<points.count {
            points[i].x += delta.width
            points[i].y += delta.height
        }
        _cachedPath = nil
    }

    public func copy() -> any AnnotationObject {
        FreehandObject(points: points, style: style)
    }
}
