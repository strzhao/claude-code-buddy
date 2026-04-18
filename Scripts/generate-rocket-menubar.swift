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

// Starship stainless-steel palette (cooler / less saturated than classic white
// rocket). Shadow band preserves the volumetric look on the booster/ship.
let hullWhite  = rgb(222, 226, 234)
let hullShadow = rgb(160, 168, 180)
let hullDark   = rgb(72,  80,  96)
let ringBlack  = rgb(28,  30,  38)
let windowBlue = rgb(90,  175, 220)
let windowLit  = rgb(200, 230, 250)
let ventOrng   = rgb(255, 150, 60)
let outline    = rgb(18,  20,  28)
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

/// Draws a stylized Starship (Super Heavy booster + Starship upper stage)
/// centered at x=25. Engine bells sit at y≈5; flame is drawn separately
/// below that. Overall silhouette is recognizable at 32×22 render size:
/// wide booster → hot-staging ring → narrower ship → pointy nose.
func drawRocket(_ ctx: CGContext) {
    let cx = 25

    // ── Super Heavy booster ───────────────────────────────────────────
    // Engine-bell ring: narrow dark band just below the booster body.
    px(ctx, cx - 3, 4, 6, 1, exhaust)
    px(ctx, cx - 3, 5, 6, 1, hullDark)

    // Booster body — 8 wide (cx-4..cx+3), y=6..12 (7 rows).
    px(ctx, cx - 4, 6, 8, 7, hullWhite)
    // Shadow band on the right (volumetric hint)
    px(ctx, cx + 2, 6, 2, 7, hullShadow)
    // Outlines
    px(ctx, cx - 4, 6, 1, 7, outline)
    px(ctx, cx + 3, 6, 1, 7, outline)

    // Grid fins — two small wings flared near booster top (y=10..11)
    px(ctx, cx - 6, 10, 2, 2, hullShadow)
    px(ctx, cx + 4, 10, 2, 2, hullShadow)
    p(ctx,  cx - 6, 11, outline)
    p(ctx,  cx + 5, 11, outline)

    // Hot-staging ring — dark band at top of booster (y=13..14). Two
    // small vent-lights glow orange to sell the engine-heat idea.
    px(ctx, cx - 4, 13, 8, 2, ringBlack)
    p(ctx,  cx - 2, 13, ventOrng)
    p(ctx,  cx + 1, 13, ventOrng)

    // ── Starship (upper stage) ────────────────────────────────────────
    // Aft flaps — two short wings just above the hot-staging ring.
    px(ctx, cx - 5, 15, 2, 1, hullShadow)
    px(ctx, cx + 4, 15, 2, 1, hullShadow)
    p(ctx,  cx - 5, 15, outline)
    p(ctx,  cx + 5, 15, outline)

    // Ship body — 6 wide (cx-3..cx+2), y=15..22 (8 rows).
    px(ctx, cx - 3, 15, 6, 8, hullWhite)
    // Shadow band
    px(ctx, cx + 1, 15, 2, 8, hullShadow)
    // Outlines
    px(ctx, cx - 3, 15, 1, 8, outline)
    px(ctx, cx + 2, 15, 1, 8, outline)

    // Forward flaps — two short wings near top of ship body (y=20..21).
    px(ctx, cx - 5, 20, 2, 1, hullShadow)
    px(ctx, cx + 4, 20, 2, 1, hullShadow)
    p(ctx,  cx - 5, 20, outline)
    p(ctx,  cx + 5, 20, outline)

    // Small flight-deck window (faint blue)
    p(ctx, cx - 1, 19, windowBlue)
    p(ctx, cx,     19, windowLit)

    // ── Nose cone — tapering triangle from 6 wide to 1-pixel tip ─────
    // y=23: 6 wide (continues body width)
    px(ctx, cx - 3, 23, 6, 1, hullWhite)
    px(ctx, cx + 1, 23, 2, 1, hullShadow)
    p(ctx,  cx - 3, 23, outline)
    p(ctx,  cx + 2, 23, outline)
    // y=24: 5 wide
    px(ctx, cx - 2, 24, 5, 1, hullWhite)
    p(ctx,  cx + 2, 24, hullShadow)
    p(ctx,  cx - 2, 24, outline)
    p(ctx,  cx + 2, 24, outline)
    // y=25: 4 wide
    px(ctx, cx - 2, 25, 4, 1, hullWhite)
    p(ctx,  cx + 1, 25, hullShadow)
    p(ctx,  cx - 2, 25, outline)
    p(ctx,  cx + 1, 25, outline)
    // y=26: 2 wide
    px(ctx, cx - 1, 26, 2, 1, hullWhite)
    p(ctx,  cx - 1, 26, outline)
    p(ctx,  cx,     26, outline)
    // y=27: 1-pixel tip
    p(ctx, cx, 27, hullWhite)
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
