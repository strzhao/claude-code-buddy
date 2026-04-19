#!/usr/bin/env swift
// generate-mechazilla-tower.swift
// Creates boundary-mechazilla.png (chopsticks CLOSED) and
// boundary-mechazilla-open.png (chopsticks OPEN) — used as the right-side
// boundary decoration when a Starship 3 is on scene.

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let outputClosed = "Sources/ClaudeCodeBuddy/Assets/Sprites/boundary-mechazilla.png"
let outputOpen   = "Sources/ClaudeCodeBuddy/Assets/Sprites/boundary-mechazilla-open.png"
let outputHalf   = "Sources/ClaudeCodeBuddy/Assets/Sprites/boundary-mechazilla-half.png"

func rgb(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1.0) -> CGColor {
    CGColor(red: CGFloat(r) / 255.0, green: CGFloat(g) / 255.0, blue: CGFloat(b) / 255.0, alpha: a)
}

let towerDark  = rgb(60, 60, 70)
let towerMid   = rgb(100, 100, 112)
let towerLight = rgb(160, 160, 170)
let armMetal   = rgb(180, 180, 190)
let warnRed    = rgb(255, 40, 40)

func px(_ ctx: CGContext, _ x: Int, _ y: Int, _ w: Int, _ h: Int, _ color: CGColor) {
    ctx.setFillColor(color)
    ctx.fill(CGRect(x: x, y: y, width: w, height: h))
}
func p(_ ctx: CGContext, _ x: Int, _ y: Int, _ color: CGColor) {
    px(ctx, x, y, 1, 1, color)
}

// Canvas 16x32 — same dims as the existing boundary-launch-tower.png so render
// math in BuddyScene (boundaryRenderSizeRocket = 32x64) remains consistent.
let W = 16, H = 32

/// Draws the static tower column (same silhouette as launch-tower).
func drawTowerColumn(_ ctx: CGContext) {
    // Main column: two vertical beams
    px(ctx, 2, 1, 1, 29, towerMid)
    px(ctx, 4, 1, 1, 29, towerMid)

    // Cross-bracing X pattern
    for base in stride(from: 2, to: 28, by: 4) {
        p(ctx, 2, base, towerDark)
        p(ctx, 3, base + 1, towerDark)
        p(ctx, 4, base + 2, towerDark)
        p(ctx, 4, base, towerDark)
        p(ctx, 3, base + 1, towerDark)
        p(ctx, 2, base + 2, towerDark)
    }
    // Highlight dashes
    for y in stride(from: 3, through: 29, by: 6) {
        p(ctx, 3, y, towerLight)
    }
    // Lower service block
    px(ctx, 5, 5, 3, 3, towerDark)
    p(ctx, 6, 6, towerLight)
    // Crown
    px(ctx, 1, 29, 5, 1, towerMid)
    px(ctx, 2, 30, 3, 1, towerLight)
    p(ctx, 3, 31, warnRed)
    // Ground flare base
    px(ctx, 1, 0, 1, 2, towerDark)
    px(ctx, 5, 0, 1, 2, towerDark)
    p(ctx, 0, 0, towerDark)
    p(ctx, 6, 0, towerDark)
    px(ctx, 0, 0, 7, 1, towerDark)
}

/// CLOSED chopsticks — two parallel arms hugging inward toward the tower at
/// y=18 and y=22 (catching height). Arms extend inward a short distance, tips
/// nearly touching.
func drawChopsticksClosed(_ ctx: CGContext) {
    // ── Single top chopstick arm ──
    // Horizontal arm spans from tower pivot (x=5) to gripper tip (x=14).
    px(ctx, 5, 25, 10, 1, armMetal)            // arm top row
    px(ctx, 5, 26, 10, 1, towerDark)           // arm top outline
    px(ctx, 5, 24, 10, 1, towerDark)           // arm bottom outline
    px(ctx, 14, 24, 1, 3, armMetal)            // gripper tip
    p(ctx, 5, 25, warnRed)                      // pivot

    // ── Middle support arm (half length of top arm) ──
    // Same pivot (x=5) but only 5 wide — a short stabilizer bracket, not a
    // full catch arm. Tip at x=9.
    px(ctx, 5, 16, 5, 1, armMetal)             // arm core row
    px(ctx, 5, 17, 5, 1, towerDark)            // arm top outline
    px(ctx, 5, 15, 5, 1, towerDark)            // arm bottom outline
    px(ctx, 9, 15, 1, 3, armMetal)             // support tip
    p(ctx, 5, 16, warnRed)                      // pivot indicator
}

/// HALF chopsticks — mid-retraction frame used for the 2s close/open animation.
/// Top arm width 6 (tip at x=10), middle arm width 4 (tip at x=8).
func drawChopsticksHalf(_ ctx: CGContext) {
    // Top chopstick half-retracted: spans x=5..10 (width 6).
    px(ctx, 5, 25, 6, 1, armMetal)
    px(ctx, 5, 26, 6, 1, towerDark)
    px(ctx, 5, 24, 6, 1, towerDark)
    px(ctx, 10, 24, 1, 3, armMetal)
    p(ctx, 5, 25, warnRed)

    // Middle support half-retracted: spans x=5..8 (width 4).
    px(ctx, 5, 16, 4, 1, armMetal)
    px(ctx, 5, 17, 4, 1, towerDark)
    px(ctx, 5, 15, 4, 1, towerDark)
    px(ctx, 8, 15, 1, 3, armMetal)
    p(ctx, 5, 16, warnRed)
}

/// OPEN chopsticks — arms swing outward, tips spread apart. Arms rotated
/// upward/outward approx 30° from horizontal, giving a visible gap.
func drawChopsticksOpen(_ ctx: CGContext) {
    // Arms RETRACT HORIZONTALLY back into the tower column (telescoping in
    // against the tower), NOT rotating up from the pivot. Only a short stub
    // remains outside the column.

    // Top chopstick retracted: stub at x=5..7, horizontal at y=24..26.
    px(ctx, 5, 25, 3, 1, armMetal)
    px(ctx, 5, 26, 3, 1, towerDark)
    px(ctx, 5, 24, 3, 1, towerDark)
    p(ctx, 7, 24, armMetal)
    p(ctx, 5, 25, warnRed)

    // Middle support retracted: stub at x=5..7, horizontal at y=15..17.
    px(ctx, 5, 16, 3, 1, armMetal)
    px(ctx, 5, 17, 3, 1, towerDark)
    px(ctx, 5, 15, 3, 1, towerDark)
    p(ctx, 7, 15, armMetal)
    p(ctx, 5, 16, warnRed)
}

func render(to path: String, drawChopsticks: (CGContext) -> Void) {
    let ctx = CGContext(
        data: nil, width: W, height: H,
        bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    ctx.interpolationQuality = .none
    ctx.clear(CGRect(x: 0, y: 0, width: W, height: H))

    drawTowerColumn(ctx)
    drawChopsticks(ctx)

    let url = URL(fileURLWithPath: path)
    guard let cg = ctx.makeImage(),
          let dest = CGImageDestinationCreateWithURL(
              url as CFURL,
              UTType.png.identifier as CFString,
              1, nil
          ) else {
        fputs("failed to write PNG \(path)\n", stderr)
        exit(1)
    }
    CGImageDestinationAddImage(dest, cg, nil)
    CGImageDestinationFinalize(dest)
    print("wrote \(path)")
}

render(to: outputClosed, drawChopsticks: drawChopsticksClosed)
render(to: outputHalf,   drawChopsticks: drawChopsticksHalf)
render(to: outputOpen,   drawChopsticks: drawChopsticksOpen)
