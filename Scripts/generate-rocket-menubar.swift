#!/usr/bin/env swift
// generate-rocket-menubar.swift
//
// Produces the menubar-rocket sprite set that parallels the cat menubar
// (menubar-walk / menubar-run / menubar-idle). The MenuBarAnimator picks
// which set to render based on the current EntityMode.
//
// Output: Sources/ClaudeCodeBuddy/Assets/Sprites/Menubar/menubar-rocket-*.png
//   idle-1       — rocket on pad, no flame, no motion
//   walk-{1..6}  — small flame flickering (1-2 active sessions)
//   run-{1..5}   — large flame + motion streaks (3+ active sessions)
//
// Canvas 50×34 (matches cat menubar). Rocket centered at x=25, standing tall.

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let outputDir = "Sources/ClaudeCodeBuddy/Assets/Sprites/Menubar"
let W = 50, H = 34

// MARK: - Colors

func rgb(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1.0) -> CGColor {
    CGColor(red: CGFloat(r) / 255.0, green: CGFloat(g) / 255.0, blue: CGFloat(b) / 255.0, alpha: a)
}

let hullWhite  = rgb(240, 240, 245)
let hullShadow = rgb(170, 170, 182)
let hullDark   = rgb(95,  95, 108)
let windowBlue = rgb(90,  175, 220)
let windowLit  = rgb(200, 230, 250)
let finRed     = rgb(220, 60,  55)
let finShadow  = rgb(150, 35,  35)
let outline    = rgb(25,  25,  35)
let exhaust    = rgb(130, 130, 140)

let flameRed   = rgb(240, 80,  40)
let flameOrng  = rgb(255, 160, 40)
let flameYel   = rgb(255, 220, 90)
let flameCore  = rgb(255, 250, 220)

let smokeLight = rgb(200, 200, 205, 0.85)
let smokeDark  = rgb(150, 150, 155, 0.55)

// MARK: - Pixel helpers

func px(_ ctx: CGContext, _ x: Int, _ y: Int, _ w: Int, _ h: Int, _ color: CGColor) {
    ctx.setFillColor(color)
    ctx.fill(CGRect(x: x, y: y, width: w, height: h))
}
func p(_ ctx: CGContext, _ x: Int, _ y: Int, _ color: CGColor) {
    px(ctx, x, y, 1, 1, color)
}

// MARK: - Rocket body (shared across all frames)

/// Draws a stylized rocket centered at x=25. Bottom engine nozzle ends at
/// roughly y=10; flame is drawn separately below.
func drawRocket(_ ctx: CGContext) {
    let cx = 25

    // Nose cone — pointy triangle at top (y=30..33). Width grows from 1 to 8.
    p(ctx,  cx,     33, hullWhite)
    p(ctx,  cx - 1, 32, hullWhite)
    p(ctx,  cx,     32, hullWhite)
    p(ctx,  cx + 1, 32, hullWhite)
    p(ctx,  cx - 2, 31, hullWhite)
    px(ctx, cx - 1, 31, 3, 1, hullWhite)
    p(ctx,  cx + 2, 31, hullShadow)
    p(ctx,  cx - 3, 30, hullWhite)
    px(ctx, cx - 2, 30, 4, 1, hullWhite)
    p(ctx,  cx + 2, 30, hullShadow)
    p(ctx,  cx + 3, 30, hullDark)
    // Nose outline
    p(ctx,  cx - 3, 31, outline)
    p(ctx,  cx + 3, 31, outline)

    // Main body — 8pt wide (cx-4..cx+3), y=16..29 (14 rows tall)
    px(ctx, cx - 4, 16, 8, 14, hullWhite)
    // Right-side shadow band
    px(ctx, cx + 2, 16, 2, 14, hullShadow)
    // Left/right outline
    px(ctx, cx - 4, 16, 1, 14, outline)
    px(ctx, cx + 3, 16, 1, 14, outline)
    // Dark accent band around mid-body (service ring)
    px(ctx, cx - 4, 22, 8, 1, hullDark)

    // Cockpit window — small circular light 3pt wide at upper body (y=26..27)
    px(ctx, cx - 1, 26, 3, 2, windowBlue)
    p(ctx,  cx - 1, 27, windowLit)
    p(ctx,  cx,     26, outline)

    // Lower accent stripes (grid-fin hint) at y=19
    p(ctx,  cx - 3, 19, hullDark)
    p(ctx,  cx - 2, 19, hullShadow)
    p(ctx,  cx + 1, 19, hullShadow)
    p(ctx,  cx + 2, 19, hullDark)

    // Side fins (red) — triangles flared to each side at y=12..17.
    // Left fin: top at (cx-4, 17), bottom-out at (cx-8, 12)
    for dy in 0..<6 {
        let rowY = 12 + dy
        let extend = 5 - dy           // 5,4,3,2,1,0
        if extend > 0 {
            px(ctx, cx - 4 - extend, rowY, extend, 1, finRed)
            p(ctx,  cx - 4 - extend, rowY, outline)
            p(ctx,  cx - 5 + 1,      rowY, finShadow)  // darker edge near body
        }
    }
    // Right fin mirror
    for dy in 0..<6 {
        let rowY = 12 + dy
        let extend = 5 - dy
        if extend > 0 {
            px(ctx, cx + 4, rowY, extend, 1, finRed)
            p(ctx,  cx + 3 + extend, rowY, outline)
            p(ctx,  cx + 4,          rowY, finShadow)
        }
    }

    // Engine section below body — 6pt wide nozzle tapering (y=12..15)
    px(ctx, cx - 3, 12, 6, 4, hullDark)
    px(ctx, cx - 2, 11, 4, 1, hullDark)
    px(ctx, cx - 2, 10, 4, 1, exhaust)
    // Outline
    p(ctx,  cx - 3, 12, outline)
    p(ctx,  cx + 2, 12, outline)
    p(ctx,  cx - 2, 10, outline)
    p(ctx,  cx + 1, 10, outline)
}

// MARK: - Flame variants

enum FlameSize { case none, small, medium, large, huge }

func drawFlame(_ ctx: CGContext, size: FlameSize, flicker: Bool = false) {
    let cx = 25
    switch size {
    case .none:
        break
    case .small:
        // 2 wide, 3 tall — small flicker
        px(ctx, cx - 1, 7, 2, 2, flameOrng)
        p(ctx,  cx - 1, 9, flameRed)
        p(ctx,  cx,     9, flameRed)
        p(ctx,  cx,     6, flameRed)
        if flicker {
            p(ctx, cx - 2, 8, flameRed)
        }
    case .medium:
        // 4 wide, 5 tall
        px(ctx, cx - 2, 6, 4, 3, flameOrng)
        px(ctx, cx - 1, 9, 2, 1, flameOrng)
        p(ctx,  cx,     5, flameRed)
        p(ctx,  cx - 1, 4, flameRed)
        p(ctx,  cx - 1, 7, flameYel)
        p(ctx,  cx,     7, flameYel)
        if flicker {
            p(ctx, cx - 3, 7, flameRed)
            p(ctx, cx + 2, 7, flameRed)
        }
    case .large:
        // 6 wide, 7 tall
        px(ctx, cx - 3, 5, 6, 4, flameRed)
        px(ctx, cx - 2, 4, 4, 1, flameRed)
        px(ctx, cx - 2, 6, 4, 3, flameOrng)
        px(ctx, cx - 1, 7, 2, 2, flameYel)
        p(ctx,  cx,     8, flameCore)
        // Flame tail dripping downward
        p(ctx,  cx - 1, 3, flameRed)
        p(ctx,  cx,     2, flameRed)
        p(ctx,  cx - 1, 1, flameOrng)
        p(ctx,  cx,     1, flameOrng)
        if flicker {
            p(ctx, cx - 4, 6, flameRed)
            p(ctx, cx + 3, 6, flameRed)
            p(ctx, cx - 3, 3, flameRed)
        }
    case .huge:
        // 8 wide, 9 tall — hottest
        px(ctx, cx - 4, 4, 8, 5, flameRed)
        px(ctx, cx - 3, 3, 6, 1, flameRed)
        px(ctx, cx - 3, 6, 6, 3, flameOrng)
        px(ctx, cx - 2, 7, 4, 2, flameYel)
        px(ctx, cx - 1, 8, 2, 1, flameCore)
        // Long tail
        px(ctx, cx - 1, 1, 2, 2, flameRed)
        px(ctx, cx - 1, 0, 2, 1, flameOrng)
        p(ctx,  cx,     2, flameOrng)
        if flicker {
            p(ctx, cx - 5, 6, flameRed)
            p(ctx, cx + 4, 6, flameRed)
            p(ctx, cx - 4, 2, flameRed)
            p(ctx, cx + 3, 2, flameRed)
        }
    }
}

// MARK: - Motion streaks (run mode)

/// Horizontal dashes on both sides of the rocket suggesting forward motion.
/// `intensity` controls streak length and number.
func drawMotionStreaks(_ ctx: CGContext, intensity: Int) {
    let leftStreaks:  [(x: Int, y: Int, w: Int)] = [
        (2, 24, 4),
        (4, 20, 5),
        (1, 16, 3),
    ]
    let rightStreaks: [(x: Int, y: Int, w: Int)] = [
        (44, 24, 4),
        (43, 20, 5),
        (46, 16, 3),
    ]
    let take = min(intensity, leftStreaks.count)
    for i in 0..<take {
        let ls = leftStreaks[i]
        px(ctx, ls.x, ls.y, ls.w, 1, hullShadow)
        let rs = rightStreaks[i]
        px(ctx, rs.x, rs.y, rs.w, 1, hullShadow)
    }
}

// MARK: - Smoke puffs (run mode)

func drawSmoke(_ ctx: CGContext) {
    // A couple of puffs below the rocket
    p(ctx, 19, 4, smokeLight)
    p(ctx, 18, 3, smokeDark)
    p(ctx, 21, 2, smokeLight)
    p(ctx, 22, 1, smokeDark)
    p(ctx, 28, 3, smokeLight)
    p(ctx, 30, 4, smokeLight)
    p(ctx, 31, 2, smokeDark)
}

// MARK: - Render

func render(to relativePath: String, _ body: (CGContext) -> Void) {
    let ctx = CGContext(
        data: nil, width: W, height: H,
        bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    ctx.interpolationQuality = .none
    ctx.clear(CGRect(x: 0, y: 0, width: W, height: H))

    body(ctx)

    let url = URL(fileURLWithPath: "\(outputDir)/\(relativePath)")
    guard let cg = ctx.makeImage(),
          let dest = CGImageDestinationCreateWithURL(
              url as CFURL,
              UTType.png.identifier as CFString,
              1, nil
          ) else {
        fputs("failed to write PNG \(url.path)\n", stderr)
        exit(1)
    }
    CGImageDestinationAddImage(dest, cg, nil)
    CGImageDestinationFinalize(dest)
    print("wrote \(relativePath)")
}

// MARK: - Frames

// Idle: rocket on pad, no flame.
render(to: "menubar-rocket-idle-1.png") { ctx in
    drawRocket(ctx)
}

// Walk (6 frames): rocket hovering with small / medium flame flickering.
let walkPlan: [(FlameSize, Bool)] = [
    (.small,  false),
    (.medium, false),
    (.small,  true),
    (.medium, true),
    (.medium, false),
    (.small,  false),
]
for (i, plan) in walkPlan.enumerated() {
    render(to: "menubar-rocket-walk-\(i + 1).png") { ctx in
        drawRocket(ctx)
        drawFlame(ctx, size: plan.0, flicker: plan.1)
    }
}

// Run (5 frames): large/huge flame + motion streaks + occasional smoke.
let runPlan: [(FlameSize, Bool, Int, Bool)] = [
    // flame,   flicker, streak count, smoke
    (.large,  false, 2, false),
    (.huge,   false, 3, true),
    (.large,  true,  2, false),
    (.huge,   true,  3, true),
    (.large,  false, 1, false),
]
for (i, plan) in runPlan.enumerated() {
    render(to: "menubar-rocket-run-\(i + 1).png") { ctx in
        drawRocket(ctx)
        drawFlame(ctx, size: plan.0, flicker: plan.1)
        drawMotionStreaks(ctx, intensity: plan.2)
        if plan.3 {
            drawSmoke(ctx)
        }
    }
}

print("Done.")
