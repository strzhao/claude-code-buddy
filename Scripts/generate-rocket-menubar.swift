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

// Chunky smoke puff — identical to `smokePuff` in
// Scripts/generate-rocket-sprites-v2.swift (Falcon 9 liftoff style).
// Keep this in sync so the two rocket sets read the same.
let smokePuff  = rgb(140, 140, 150, 0.9)

// MARK: - Pixel helpers

func px(_ ctx: CGContext, _ x: Int, _ y: Int, _ w: Int, _ h: Int, _ color: CGColor) {
    ctx.setFillColor(color)
    ctx.fill(CGRect(x: x, y: y, width: w, height: h))
}
func p(_ ctx: CGContext, _ x: Int, _ y: Int, _ color: CGColor) {
    px(ctx, x, y, 1, 1, color)
}

// MARK: - Rocket body (shared across all frames)

/// Draws the Starship UPPER STAGE only (Ship, no booster), parallel to
/// `drawStarshipShipAlone` in Scripts/generate-rocket-sprites-v2.swift.
/// Scaled / repositioned for the 50×34 menubar canvas (cx=25); engine
/// nozzles sit at y=6 so flame drawn below (y=0..5) reads as issuing from
/// the Raptors.
///
/// Silhouette read at 32×22 render:
///   narrow ship body (8 wide) · aft flaps wider at base · forward flaps
///   higher · pointy nose cone · 3 tiny Raptor bells at bottom.
/// Draws the Starship upper stage. `yShift` lowers (or raises) the whole
/// stack — idle mode uses -2 to "settle" the ship 2pt below the cruise
/// attitude, suggesting the Raptors are off.
func drawRocket(_ ctx: CGContext, yShift: Int = 0) {
    let cx = 25
    let baseY = 7 + yShift  // ship body bottom row (engines sit at baseY-1)
    let bodyHeight = 24    // y=7..30 — cylinder runs almost to canvas top

    // ── Ship body — 14 wide (cx-7..cx+6), 24 rows tall (y=7..30) ─────
    px(ctx, cx - 7, baseY, 14, bodyHeight, hullWhite)
    // Right-side shadow band (5pt — wider hull, wider shadow)
    px(ctx, cx + 2, baseY, 5, bodyHeight, hullShadow)
    // Left + right outlines
    px(ctx, cx - 7, baseY, 1, bodyHeight, outline)
    px(ctx, cx + 6, baseY, 1, bodyHeight, outline)

    // ── Aft flaps — 4 wide × 3 rows + tip pixels ─────────────────────
    px(ctx, cx - 11, baseY + 1, 4, 3, hullShadow)
    p(ctx,  cx - 12, baseY + 1, outline)
    p(ctx,  cx - 12, baseY + 2, outline)
    px(ctx, cx + 7,  baseY + 1, 4, 3, hullShadow)
    p(ctx,  cx + 11, baseY + 1, outline)
    p(ctx,  cx + 11, baseY + 2, outline)

    // ── Forward flaps — 3 wide × 2 rows, near upper body ─────────────
    px(ctx, cx - 10, baseY + 18, 3, 2, hullShadow)
    p(ctx,  cx - 11, baseY + 18, outline)
    px(ctx, cx + 7,  baseY + 18, 3, 2, hullShadow)
    p(ctx,  cx + 10, baseY + 18, outline)

    // ── Cockpit window band (dark horizontal bar, 10 wide) ───────────
    px(ctx, cx - 5, baseY + 15, 10, 1, ringBlack)
    px(ctx, cx - 2, baseY + 15, 4, 1, windowLit)

    // ── Rounded top cap — 3 rows of mild corner rounding at y=31..33.
    //    Replaces the pointy nose cone: no tip, just gentle curve into
    //    the canvas top edge.
    // Cap row 1: 12 wide (cx-6..cx+5) — shave 1 pixel off each side
    px(ctx, cx - 6, baseY + bodyHeight,     12, 1, hullWhite)
    px(ctx, cx + 2, baseY + bodyHeight,      4, 1, hullShadow)
    p(ctx,  cx - 6, baseY + bodyHeight,     outline)
    p(ctx,  cx + 5, baseY + bodyHeight,     outline)
    // Cap row 2: 10 wide (cx-5..cx+4)
    px(ctx, cx - 5, baseY + bodyHeight + 1, 10, 1, hullWhite)
    px(ctx, cx + 2, baseY + bodyHeight + 1,  3, 1, hullShadow)
    p(ctx,  cx - 5, baseY + bodyHeight + 1, outline)
    p(ctx,  cx + 4, baseY + bodyHeight + 1, outline)
    // Cap row 3 (canvas top, y=33): 8 wide (cx-4..cx+3) — flat-ish top
    px(ctx, cx - 4, baseY + bodyHeight + 2,  8, 1, hullWhite)
    px(ctx, cx + 2, baseY + bodyHeight + 2,  2, 1, hullShadow)
    p(ctx,  cx - 4, baseY + bodyHeight + 2, outline)
    p(ctx,  cx + 3, baseY + bodyHeight + 2, outline)

    // ── Raptor engine cluster — continuous dark ring 12 wide ─────────
    px(ctx, cx - 6, baseY - 1, 12, 1, exhaust)
    // Four-dot texture hint across the ring
    p(ctx, cx - 4, baseY - 1, ringBlack)
    p(ctx, cx - 1, baseY - 1, ringBlack)
    p(ctx, cx + 1, baseY - 1, ringBlack)
    p(ctx, cx + 4, baseY - 1, ringBlack)
}

// MARK: - Flame variants

enum FlameSize { case none, small, medium, large, huge }

/// Raptor exhaust plume. Ship engines sit at y=6; flame extends DOWN from
/// there into the canvas bottom (y=5..0). Widths tuned so the flame reads
/// "thrust coming from the ship" rather than a vague glow.
func drawFlame(_ ctx: CGContext, size: FlameSize, flicker: Bool = false) {
    let cx = 25
    switch size {
    case .none:
        break
    case .small:
        // 2 wide, 3 tall — y=3..5
        px(ctx, cx - 1, 3, 2, 3, flameOrng)
        p(ctx,  cx,     2, flameRed)
        if flicker { p(ctx, cx - 2, 4, flameRed) }
    case .medium:
        // 4 wide, 5 tall — y=1..5
        px(ctx, cx - 2, 2, 4, 4, flameOrng)
        px(ctx, cx - 1, 1, 2, 1, flameRed)
        p(ctx,  cx,     0, flameRed)
        px(ctx, cx - 1, 3, 2, 2, flameYel)
        if flicker {
            p(ctx, cx - 3, 4, flameRed)
            p(ctx, cx + 2, 4, flameRed)
        }
    case .large:
        // 6 wide, 6 tall — y=0..5
        px(ctx, cx - 3, 2, 6, 4, flameRed)
        px(ctx, cx - 2, 1, 4, 1, flameRed)
        px(ctx, cx - 2, 2, 4, 3, flameOrng)
        px(ctx, cx - 1, 3, 2, 2, flameYel)
        p(ctx,  cx,     4, flameCore)
        p(ctx,  cx - 1, 0, flameRed)
        p(ctx,  cx,     0, flameRed)
        if flicker {
            p(ctx, cx - 4, 3, flameRed)
            p(ctx, cx + 3, 3, flameRed)
        }
    case .huge:
        // 12 wide, 6 tall — y=0..5 (widened to match 12pt engine ring)
        px(ctx, cx - 6, 2, 12, 4, flameRed)
        px(ctx, cx - 5, 1, 10, 1, flameRed)
        px(ctx, cx - 5, 2, 10, 3, flameOrng)
        px(ctx, cx - 3, 3, 6, 2, flameYel)
        px(ctx, cx - 1, 4, 2, 1, flameCore)
        px(ctx, cx - 1, 0, 2, 1, flameRed)
        if flicker {
            p(ctx, cx - 7, 3, flameRed)
            p(ctx, cx + 6, 3, flameRed)
            p(ctx, cx - 6, 1, flameRed)
            p(ctx, cx + 5, 1, flameRed)
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

/// F9-style smoke puff — solid grey rectangles at the requested shape.
/// `isMain = true` draws the 4×4 primary puff; `false` draws the 3×3 trail.
func drawFalconPuff(_ ctx: CGContext, x: Int, y: Int, isMain: Bool) {
    let size = isMain ? 4 : 3
    px(ctx, x, y, size, size, smokePuff)
}

/// Legacy single-frame smoke (run state) — F9 placement at the base.
func drawSmoke(_ ctx: CGContext) {
    drawFalconPuff(ctx, x: 13, y: 1, isMain: true)
    drawFalconPuff(ctx, x:  9, y: 2, isMain: false)
    drawFalconPuff(ctx, x: 33, y: 1, isMain: true)
    drawFalconPuff(ctx, x: 38, y: 2, isMain: false)
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

// ─────────────────────────────────────────────────────────────────────
// Idle animation: Raptors OFF, ship sits 2pt below cruise with F9-style
// smoke puffs (reused `drawFalconPuffs`) venting from the MID-LOWER hull
// rather than the base. 5 frames place the same 4×3 main + 3×2 trail
// F9 smoke shape at deterministically-randomized y rows inside the vent
// band (y=9..17) with slight x jitter — reads as propellant cryo-vent
// clouds drifting around the tanks.
//
// Ship body spans x=18..31 so the left puffs sit at x≈11..17 (flush
// with body left edge + one puff further out); right mirrors.

// Seed a simple deterministic PRNG so sprite regeneration is repeatable.
// (linear congruential — good enough for picking pixel offsets.)
struct SeededRNG {
    var state: UInt64
    init(_ seed: UInt64) { state = seed &+ 0x9E3779B97F4A7C15 }
    mutating func nextInt(in range: ClosedRange<Int>) -> Int {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        let span = UInt64(range.upperBound - range.lowerBound + 1)
        return range.lowerBound + Int(state >> 33 % span)
    }
}

for frame in 0..<5 {
    render(to: "menubar-rocket-idle-\(frame + 1).png") { ctx in
        drawRocket(ctx, yShift: -2)

        // Seed offset bumped per regen — change this number to roll a
        // fresh set of 5 random frames.
        var rng = SeededRNG(UInt64(frame + 42))
        // 4-6 puffs per frame, scattered across both flanks of the ship.
        // Each puff is either a 4×4 main block or a 3×3 trail block
        // (random per puff). Positions land in the mid-lower vent band
        // (y=9..16) without overlapping the ship body (x=18..31).
        let puffCount = rng.nextInt(in: 4...6)
        for _ in 0..<puffCount {
            let isMain = rng.nextInt(in: 0...1) == 0
            let size = isMain ? 4 : 3
            // Pick side 50/50. Left x∈0..(17-size), right x∈34..(49-size).
            let onLeft = rng.nextInt(in: 0...1) == 0
            let x: Int
            if onLeft {
                x = rng.nextInt(in: 0...(17 - size))
            } else {
                x = rng.nextInt(in: 34...(49 - size))
            }
            let y = rng.nextInt(in: 9...(16 - size + 1))
            drawFalconPuff(ctx, x: x, y: y, isMain: isMain)
        }
    }
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

// Run (5 frames): Raptors at MAX thrust — huge flame on every frame.
// Flicker + smoke alternate so successive frames read as animated
// turbulence rather than a static image. No motion streaks (the flame
// pulse + smoke billow already sell the speed without them).
let runPlan: [(FlameSize, Bool, Bool)] = [
    // flame,  flicker, smoke
    (.huge,   false, false),
    (.huge,   true,  true),
    (.huge,   false, true),
    (.huge,   true,  false),
    (.huge,   false, true),
]
for (i, plan) in runPlan.enumerated() {
    render(to: "menubar-rocket-run-\(i + 1).png") { ctx in
        drawRocket(ctx)
        drawFlame(ctx, size: plan.0, flicker: plan.1)
        if plan.2 {
            drawSmoke(ctx)
        }
    }
}

print("Done.")
