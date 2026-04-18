#!/usr/bin/env swift
// generate-rocket-sprites-v2.swift
// Generates 48x48 pixel-art rocket PNG sprites for Phase 1 RocketStates.
// Run with: swift Scripts/generate-rocket-sprites-v2.swift

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import AppKit

// MARK: - Output

let outputDir = "Sources/ClaudeCodeBuddy/Assets/Sprites/Rocket"

func ensureDir(_ path: String) {
    try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
}

// MARK: - Palette (F9-style white/black/red + effects)

func rgb(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1.0) -> CGColor {
    CGColor(red: CGFloat(r) / 255.0, green: CGFloat(g) / 255.0, blue: CGFloat(b) / 255.0, alpha: a)
}

let bodyWhite    = rgb(235, 235, 240)
let bodyShadow   = rgb(180, 180, 188)
let stripeRed    = rgb(210, 60, 60)
let windowBlack  = rgb(30, 30, 35)
let windowLit    = rgb(255, 220, 80)
let padGray      = rgb(100, 100, 110)
let padDark      = rgb(70, 70, 78)
/// Medium grey used for engine parts + landing gear. Reads well on both dark
/// and white backgrounds (dark greys vanish on terminals, white vanishes on pad).
let partMetal    = rgb(140, 140, 150)
/// Keep finDark as an alias mapped to the medium tone so existing callers shift.
let finDark      = rgb(140, 140, 150)
let flameCore    = rgb(255, 230, 80)
let flameOrange  = rgb(255, 150, 50)
let flameRed     = rgb(255, 90, 40)
let warningRed   = rgb(255, 40, 40)
let smokePuff    = rgb(140, 140, 150, 0.9)
// External Tank colors — real ET foam is burnt orange / rust.
let etOrange     = rgb(200, 105, 60)
let etShadow     = rgb(150, 75, 45)

// MARK: - Pixel helpers (pixel = 1pt since we use 48x48 native)

/// Fill a rect in pixel coords. y=0 is bottom.
func px(_ ctx: CGContext, _ x: Int, _ y: Int, _ w: Int, _ h: Int, _ color: CGColor) {
    ctx.setFillColor(color)
    ctx.fill(CGRect(x: x, y: y, width: w, height: h))
}

/// Single pixel.
func p(_ ctx: CGContext, _ x: Int, _ y: Int, _ color: CGColor) {
    pxS(ctx, x, y, 1, 1, color)
}

// MARK: - Scaled pixel helpers
//
// When drawing Starship frames into a 72×72 canvas (vs the 48×48 used by other
// kinds) we want the SAME drawing code to place content at 1.5× coordinates.
// Set `drawScale = 1.5` before a Starship draw, reset to 1.0 after. All
// Starship-only draw functions use pxS/pS which multiply coords by drawScale
// (floored to int, with a floor of 1 for non-empty rects).

var drawScale: CGFloat = 1.0

/// Fill a scaled rect. Accepts logical (48-canvas) coords and multiplies by
/// `drawScale` at draw time.
func pxS(_ ctx: CGContext, _ x: Int, _ y: Int, _ w: Int, _ h: Int, _ color: CGColor) {
    let s = drawScale
    let sx = Int((CGFloat(x) * s).rounded(.down))
    let sy = Int((CGFloat(y) * s).rounded(.down))
    let sw = max(1, Int((CGFloat(w) * s).rounded(.down)))
    let sh = max(1, Int((CGFloat(h) * s).rounded(.down)))
    ctx.setFillColor(color)
    ctx.fill(CGRect(x: sx, y: sy, width: sw, height: sh))
}

/// Single scaled pixel.
func pS(_ ctx: CGContext, _ x: Int, _ y: Int, _ color: CGColor) {
    pxS(ctx, x, y, 1, 1, color)
}

// MARK: - Rocket body (shared across frames)

/// Draws the base rocket silhouette at the given vertical offset.
/// `yOff` shifts the whole rocket up (used to lift it during cruise/liftoff).
/// baseY=4 (at yOff=0) puts engine bottom at sprite y=6, just above the classic
/// pad top (y=5) so the rocket visually sits ON the pad rather than floating.
func drawRocketBody(_ ctx: CGContext, yOff: Int = 0, windowLight: Bool = true) {
    let cx = 24     // center x
    let baseY = 4 + yOff

    // Nose cone (triangle-ish, tapering)
    pS(ctx, cx - 1, baseY + 32, bodyWhite)
    pS(ctx, cx,     baseY + 32, bodyWhite)
    pxS(ctx, cx - 2, baseY + 30, 4, 2, bodyWhite)
    pxS(ctx, cx - 3, baseY + 28, 6, 2, bodyWhite)

    // Main body (8 wide cylinder)
    pxS(ctx, cx - 4, baseY + 10, 8, 18, bodyWhite)
    // Right side shadow
    pxS(ctx, cx + 2, baseY + 10, 2, 18, bodyShadow)

    // Red stripe near bottom
    pxS(ctx, cx - 4, baseY + 8, 8, 2, stripeRed)

    // Window(s)
    pxS(ctx, cx - 1, baseY + 22, 2, 2, windowBlack)
    if windowLight {
        pS(ctx, cx - 1, baseY + 23, windowLit)
    }
    // Second porthole
    pS(ctx, cx - 1, baseY + 16, windowBlack)
    pS(ctx, cx, baseY + 16, windowBlack)

    // Landing legs (no wings) — two angled struts on each side, attached mid-body
    // and reaching down-outward to pad level. Simple, always deployed.
    // Left leg: hinge at (cx-4, baseY+6) → footpad (cx-6, baseY+1)
    for i in 0...5 {
        let x = (cx - 4) - (i * 2 / 5)   // gently slopes outward
        let y = (baseY + 6) - i
        pS(ctx, x, y, partMetal)
    }
    pxS(ctx, cx - 7, baseY + 1, 3, 1, partMetal)     // left footpad y=5
    // Right leg mirror: hinge (cx+3, baseY+6) → footpad (cx+5, baseY+1)
    for i in 0...5 {
        let x = (cx + 3) + (i * 2 / 5)
        let y = (baseY + 6) - i
        pS(ctx, x, y, partMetal)
    }
    pxS(ctx, cx + 4, baseY + 1, 3, 1, partMetal)     // right footpad y=5

    // Engine bell + housing in medium grey so they stay visible on any bg.
    pxS(ctx, cx - 3, baseY + 4, 6, 4, partMetal)
    pxS(ctx, cx - 2, baseY + 2, 4, 2, partMetal)
}

func drawPad(_ ctx: CGContext) {
    // Pad platform at bottom 6 pixels wide across middle
    pxS(ctx, 10, 0, 28, 4, padGray)
    pxS(ctx, 10, 4, 28, 2, padDark)
    // Pad legs/supports
    pxS(ctx, 8, 0, 2, 3, padDark)
    pxS(ctx, 38, 0, 2, 3, padDark)
}

func drawFlame(_ ctx: CGContext, yOff: Int, size: FlameSize) {
    let cx = 24
    let baseY = 10 + yOff  // engine bottom ~ baseY + 2
    let top = baseY - 1    // just below engine
    switch size {
    case .small:
        // 2-layer small flame
        pxS(ctx, cx - 2, top - 2, 4, 2, flameOrange)
        pxS(ctx, cx - 1, top - 4, 2, 2, flameCore)
    case .medium:
        pxS(ctx, cx - 3, top - 2, 6, 2, flameRed)
        pxS(ctx, cx - 2, top - 4, 4, 2, flameOrange)
        pxS(ctx, cx - 1, top - 6, 2, 2, flameCore)
    case .large:
        pxS(ctx, cx - 4, top - 2, 8, 2, flameRed)
        pxS(ctx, cx - 3, top - 4, 6, 2, flameOrange)
        pxS(ctx, cx - 2, top - 6, 4, 2, flameCore)
        pxS(ctx, cx - 1, top - 8, 2, 2, windowLit)
    }
}

enum FlameSize { case small, medium, large }

/// F9 flame — emerges from the BOTTOM of the engine bell (not from within the
/// engine housing) so the housing/bell doesn't show through as a dark patch.
func drawF9Flame(_ ctx: CGContext, yOff: Int, size: FlameSize) {
    let cx = 24
    let baseY = 10 + yOff
    // Flame top anchored to engine bell bottom (baseY - 8 in drawF9Body). Layers
    // cascade downward from there — i.e. below the engine.
    let top = baseY - 6
    switch size {
    case .small:
        pxS(ctx, cx - 2, top - 2, 4, 2, flameOrange)   // just below bell
        pxS(ctx, cx - 1, top - 4, 2, 2, flameCore)
    case .medium:
        pxS(ctx, cx - 3, top - 2, 6, 2, flameOrange)
        pxS(ctx, cx - 2, top - 4, 4, 2, flameCore)
    case .large:
        pxS(ctx, cx - 4, top - 2, 8, 2, flameOrange)
        pxS(ctx, cx - 3, top - 4, 6, 2, flameCore)
    }
}

/// F9 pad — thin and white (3pt tall), more like a clean mobile-launch table
/// than the classic gray concrete platform.
func drawF9Pad(_ ctx: CGContext) {
    pxS(ctx, 12, 0, 24, 2, bodyWhite)      // top surface
    pxS(ctx, 12, 2, 24, 1, bodyShadow)     // thin shadow line underneath
    // Subtle hold-down clamps (2 small dark dots)
    pS(ctx, 17, 1, windowBlack)
    pS(ctx, 30, 1, windowBlack)
    // Tiny support legs peeking out under platform
    pS(ctx, 13, 0, padDark)
    pS(ctx, 34, 0, padDark)
}

func drawWarningLight(_ ctx: CGContext, yOff: Int = 0, on: Bool) {
    let cx = 24
    let y = 10 + yOff + 34  // just below nose
    let color: CGColor = on ? warningRed : padDark
    pS(ctx, cx - 1, y, color)
    pS(ctx, cx, y, color)
}

func drawSmoke(_ ctx: CGContext) {
    // Puff at bottom sides
    pxS(ctx, 12, 1, 4, 3, smokePuff)
    pxS(ctx, 32, 1, 4, 3, smokePuff)
    pxS(ctx, 8, 2, 3, 2, smokePuff)
    pxS(ctx, 37, 2, 3, 2, smokePuff)
}

func drawLandingLegs(_ ctx: CGContext, yOff: Int) {
    // Deployed legs angle outward from fin base
    let baseY = 10 + yOff
    let cx = 24
    pxS(ctx, cx - 8, baseY + 2, 2, 2, finDark)
    pS(ctx, cx - 9, baseY + 1, finDark)
    pxS(ctx, cx + 6, baseY + 2, 2, 2, finDark)
    pS(ctx, cx + 8, baseY + 1, finDark)
}

// MARK: - Space Shuttle variant
// Iconic delta-wing orbiter — wider than classic/F9 because of the wingspan.
// Silhouette at a glance: vertical fuselage + triangular wings midway down +
// vertical tail fin at the very top + 3 SSME bells at the bottom.

func drawShuttleBody(_ ctx: CGContext, yOff: Int = 0, windowLight: Bool = true) {
    let baseY = 4 + yOff

    // STS launch stack (wider components, SRBs flush against ET):
    //   • ET (orange): 10-wide centered on sprite (x=19..28).
    //   • Left SRB (white): 4-wide at x=15..18, touches ET's left edge.
    //   • Right SRB (white): 4-wide at x=29..32, touches ET's right edge.
    //   • Orbiter (white): 8-wide at x=20..27, drawn IN FRONT of ET (ET visible
    //     at top nose + thin slivers on sides of orbiter where it doesn't cover).
    //   • Orbiter wings: big delta below SRB bodies (y=4..14) so they don't
    //     collide with SRBs up top.

    // ── LEFT SRB — shorter than orbiter; bottom flush at engine (y=2) ──
    //    body y=4..24 (21 tall), nose y=25..27, total reaches y=28
    pxS(ctx, 15, baseY + 4, 4, 21, bodyWhite)
    pxS(ctx, 17, baseY + 4, 2, 21, bodyShadow)
    pxS(ctx, 15, baseY + 4, 1, 21, partMetal)
    // Nose taper (pointed white cone)
    pxS(ctx, 15, baseY + 25, 4, 1, bodyWhite)
    pxS(ctx, 16, baseY + 26, 2, 1, bodyWhite)
    pS(ctx, 15, baseY + 25, partMetal)
    pS(ctx, 18, baseY + 25, partMetal)
    pS(ctx, 16, baseY + 26, partMetal)
    pS(ctx, 17, baseY + 26, partMetal)
    pS(ctx, 16, baseY + 27, partMetal)
    pS(ctx, 17, baseY + 27, partMetal)
    // Engine bell at very bottom
    pxS(ctx, 15, baseY + 2, 4, 2, partMetal)

    // ── RIGHT SRB (mirror, same short height, flush bottom) ──
    pxS(ctx, 29, baseY + 4, 4, 21, bodyWhite)
    pxS(ctx, 31, baseY + 4, 2, 21, bodyShadow)
    pxS(ctx, 32, baseY + 4, 1, 21, partMetal)
    pxS(ctx, 29, baseY + 25, 4, 1, bodyWhite)
    pxS(ctx, 30, baseY + 26, 2, 1, bodyWhite)
    pS(ctx, 29, baseY + 25, partMetal)
    pS(ctx, 32, baseY + 25, partMetal)
    pS(ctx, 30, baseY + 26, partMetal)
    pS(ctx, 31, baseY + 26, partMetal)
    pS(ctx, 30, baseY + 27, partMetal)
    pS(ctx, 31, baseY + 27, partMetal)
    pxS(ctx, 29, baseY + 2, 4, 2, partMetal)

    // ── EXTERNAL TANK (10 wide, slightly taller — top at y=43 @ yOff=0) ──
    pxS(ctx, 19, baseY + 4, 10, 35, etOrange)         // body y=4..38
    pxS(ctx, 26, baseY + 4, 3, 35, etShadow)
    pxS(ctx, 19, baseY + 4, 1, 35, partMetal)
    pxS(ctx, 28, baseY + 4, 1, 35, partMetal)
    // Tapered nose
    pxS(ctx, 20, baseY + 39, 8, 1, etOrange)
    pxS(ctx, 21, baseY + 40, 6, 1, etOrange)
    pxS(ctx, 22, baseY + 41, 4, 1, etOrange)
    pxS(ctx, 23, baseY + 42, 2, 1, etOrange)
    // Nose outlines
    pS(ctx, 19, baseY + 39, partMetal)
    pS(ctx, 28, baseY + 39, partMetal)
    pS(ctx, 20, baseY + 39, partMetal)
    pS(ctx, 27, baseY + 39, partMetal)
    pS(ctx, 21, baseY + 40, partMetal)
    pS(ctx, 26, baseY + 40, partMetal)
    pS(ctx, 22, baseY + 41, partMetal)
    pS(ctx, 25, baseY + 41, partMetal)
    pS(ctx, 23, baseY + 42, partMetal)
    pS(ctx, 24, baseY + 42, partMetal)

    // ── ORBITER body (8-wide, slightly taller — top at y=32 @ yOff=0) ──
    // y=baseY+6..baseY+30 (25 tall).
    pxS(ctx, 20, baseY + 6, 8, 25, bodyWhite)
    pxS(ctx, 26, baseY + 6, 2, 25, bodyShadow)
    pxS(ctx, 20, baseY + 6, 1, 25, partMetal)
    pxS(ctx, 27, baseY + 6, 1, 25, partMetal)
    // Orbiter nose (rounded white dome)
    pxS(ctx, 21, baseY + 31, 6, 1, bodyWhite)
    pxS(ctx, 22, baseY + 32, 4, 1, bodyWhite)
    pS(ctx, 21, baseY + 31, partMetal)
    pS(ctx, 26, baseY + 31, partMetal)
    pS(ctx, 22, baseY + 32, partMetal)
    pS(ctx, 25, baseY + 32, partMetal)
    pS(ctx, 22, baseY + 33, partMetal)
    pS(ctx, 25, baseY + 33, partMetal)
    // Cockpit windows
    pxS(ctx, 22, baseY + 28, 4, 1, windowBlack)
    if windowLight {
        pS(ctx, 23, baseY + 28, windowLit)
    }

    // ── ORBITER wings (delta, below orbiter body, flaring outward) ──
    // y=4..15 — clear of SRB bodies (which start at y=4 as cylinders, but wings
    // are drawn LAST so they visually sit on top in the overlap zone).
    for i in 0...11 {
        let y = baseY + 4 + i                // y=4..15
        let spread = 7 - (i * 7 / 11)        // 7 at bottom, 0 at top
        if spread > 0 {
            // Left wing
            pxS(ctx, 20 - spread, y, spread, 1, bodyWhite)
            pS(ctx, 20 - spread, y, partMetal)
            // Right wing
            pxS(ctx, 28, y, spread, 1, bodyWhite)
            pS(ctx, 27 + spread, y, partMetal)
        }
    }

    // ── ORBITER tail fin (center, between wings) ──
    pxS(ctx, 23, baseY + 4, 2, 4, partMetal)

    // ── ORBITER 3 engine bells (center bottom) ──
    pxS(ctx, 21, baseY + 2, 2, 2, partMetal)
    pxS(ctx, 23, baseY + 2, 2, 2, partMetal)
    pxS(ctx, 25, baseY + 2, 2, 2, partMetal)
}

/// Shuttle stands on its own pad — shuttle + gantry-like support.
func drawShuttlePad(_ ctx: CGContext) {
    drawPad(ctx)   // reuse classic pad but could differ later
}

/// Shuttle flame — SRBs dominate with massive plumes (solids are huge), the
/// orbiter's 3 SSMEs produce a much smaller centre flame. Orbiter plume
/// stays compact; SRB plume scales with `size`.
func drawShuttleFlame(_ ctx: CGContext, yOff: Int, size: FlameSize) {
    let baseY = 4 + yOff

    // Orbiter center — always small (SSMEs are dwarfed by the SRBs)
    pxS(ctx, 22, baseY + 0, 4, 1, flameOrange)
    pxS(ctx, 23, baseY - 1, 2, 1, flameCore)

    // SRB plumes — dominant, scale with size.
    switch size {
    case .small:
        // Left SRB
        pxS(ctx, 14, baseY + 0, 6, 2, flameOrange)
        pxS(ctx, 15, baseY - 2, 4, 2, flameCore)
        // Right SRB
        pxS(ctx, 28, baseY + 0, 6, 2, flameOrange)
        pxS(ctx, 29, baseY - 2, 4, 2, flameCore)
    case .medium:
        // Left SRB
        pxS(ctx, 13, baseY + 0, 8, 2, flameOrange)
        pxS(ctx, 14, baseY - 2, 6, 2, flameCore)
        pxS(ctx, 15, baseY - 4, 4, 2, windowLit)
        // Right SRB
        pxS(ctx, 27, baseY + 0, 8, 2, flameOrange)
        pxS(ctx, 28, baseY - 2, 6, 2, flameCore)
        pxS(ctx, 29, baseY - 4, 4, 2, windowLit)
    case .large:
        // Left SRB — huge exhaust
        pxS(ctx, 12, baseY + 0, 10, 2, flameOrange)
        pxS(ctx, 13, baseY - 2, 8, 2, flameCore)
        pxS(ctx, 14, baseY - 4, 6, 2, windowLit)
        pxS(ctx, 15, baseY - 6, 4, 2, windowLit)
        // Right SRB
        pxS(ctx, 26, baseY + 0, 10, 2, flameOrange)
        pxS(ctx, 27, baseY - 2, 8, 2, flameCore)
        pxS(ctx, 28, baseY - 4, 6, 2, windowLit)
        pxS(ctx, 29, baseY - 6, 4, 2, windowLit)
    }
}

// MARK: - Falcon 9 variant (complete redesign)
// Coordinate convention inside these helpers: `baseY` = 10 + yOff, matches
// drawRocketBody's baseline so flame/pad math elsewhere still works.
// The body itself (nose, fairing, engine) is drawn from scratch here — we
// DO NOT reuse drawRocketBody so the F9 can have a flat fairing and its own
// accent pattern.

/// Full F9 body (from engine bell to flat-top fairing). No legs.
/// Uniform 8-wide silhouette from engine up through fairing; only the engine
/// bell itself is narrower. Grid fins (drawn separately) sit flush to the
/// body sides and are the only parts that exceed the 8-wide silhouette.
func drawF9Body(_ ctx: CGContext, yOff: Int = 0, windowLight: Bool = true) {
    let baseY = 10 + yOff
    let cx = 24

    // Engine bell (4 wide, medium grey for visibility on any bg)
    pxS(ctx, cx - 2, baseY - 8, 4, 2, partMetal)
    // Engine housing (6 wide, medium grey)
    pxS(ctx, cx - 3, baseY - 6, 6, 4, partMetal)
    // Engine section base (8 wide — matches body)
    pxS(ctx, cx - 4, baseY - 2, 8, 2, bodyWhite)
    // Red accent ring (engine/body boundary)
    pxS(ctx, cx - 4, baseY, 8, 1, stripeRed)
    // Main body lower (8 wide)
    pxS(ctx, cx - 4, baseY + 1, 8, 14, bodyWhite)
    // Right-side shadow stripe
    pxS(ctx, cx + 2, baseY + 1, 2, 14, bodyShadow)
    // Mid accent (thin red)
    pxS(ctx, cx - 4, baseY + 15, 8, 1, stripeRed)
    // Main body upper (8 wide)
    pxS(ctx, cx - 4, baseY + 16, 8, 8, bodyWhite)
    pxS(ctx, cx + 2, baseY + 16, 2, 8, bodyShadow)
    // Black interstage ring (F9 signature separator)
    pxS(ctx, cx - 4, baseY + 24, 8, 2, windowBlack)
    // Payload fairing: FLAT top, SAME 8-wide as body for uniform silhouette.
    pxS(ctx, cx - 4, baseY + 26, 8, 6, bodyWhite)
    pxS(ctx, cx + 2, baseY + 26, 2, 6, bodyShadow)
    // Portholes
    pS(ctx, cx - 1, baseY + 10, windowBlack)
    pS(ctx, cx, baseY + 10, windowBlack)
    if windowLight {
        pS(ctx, cx - 1, baseY + 11, windowLit)
    }
}

/// Prominent grid fins mounted flush against the body, just below the interstage.
/// 5 wide × 5 tall each. Body spans x=20..27, so left fin sits at x=15..19,
/// right fin at x=28..32 — the fins are the ONLY parts that widen the silhouette.
func drawF9GridFins(_ ctx: CGContext, yOff: Int) {
    let baseY = 10 + yOff
    let finBottom = baseY + 19
    drawGridFin(ctx, leftX: 15, bottomY: finBottom)
    drawGridFin(ctx, leftX: 28, bottomY: finBottom)
}

/// Draws a 5x5 grid fin with cross-hatch: outer border + inner lattice.
private func drawGridFin(_ ctx: CGContext, leftX: Int, bottomY: Int) {
    // Outer border (solid dark)
    pxS(ctx, leftX, bottomY, 5, 1, windowBlack)        // bottom edge
    pxS(ctx, leftX, bottomY + 4, 5, 1, windowBlack)    // top edge
    pxS(ctx, leftX, bottomY, 1, 5, windowBlack)        // left edge
    pxS(ctx, leftX + 4, bottomY, 1, 5, windowBlack)    // right edge
    // Inner cross-hatch: center vertical + horizontal lines
    pxS(ctx, leftX + 2, bottomY + 1, 1, 3, windowBlack)
    pxS(ctx, leftX + 1, bottomY + 2, 3, 1, windowBlack)
    // Inner cells: light grey for strong contrast against the black cross-hatch.
    pS(ctx, leftX + 1, bottomY + 1, bodyShadow)
    pS(ctx, leftX + 3, bottomY + 1, bodyShadow)
    pS(ctx, leftX + 1, bottomY + 3, bodyShadow)
    pS(ctx, leftX + 3, bottomY + 3, bodyShadow)
}

// MARK: - F9 legs — parameterised by rotation angle around a fixed hinge.
//
// Both legs pivot around the same hinge point (x=20 left, x=27 right, y=baseY).
// `angleDeg = 0` → leg stowed straight UP (tucked along body).
// `angleDeg = 90` → leg horizontal (pointing straight outward).
// `angleDeg = 135` → leg fully deployed (pointing down-outward).
// As `angleDeg` increases, the leg rotates from up → out → down, giving a
// visible hinge-pivot motion.

private let legLength = 8

private func legTip(hx: Double, hy: Double, angleDeg: Double, isRight: Bool) -> (Int, Int) {
    let rad = angleDeg * .pi / 180
    let dxMag = sin(rad) * Double(legLength)
    let dy = cos(rad) * Double(legLength)
    let dx = isRight ? dxMag : -dxMag
    return (Int((hx + dx).rounded()), Int((hy + dy).rounded()))
}

func drawF9LegsAtAngle(_ ctx: CGContext, yOff: Int, angleDeg: Double) {
    let baseY = 10 + yOff
    let leftHinge = (x: 20, y: baseY)
    let rightHinge = (x: 27, y: baseY)

    for (hinge, isRight) in [(leftHinge, false), (rightHinge, true)] {
        let (tipX, tipY) = legTip(hx: Double(hinge.x), hy: Double(hinge.y),
                                   angleDeg: angleDeg, isRight: isRight)
        drawLegStrut(ctx, fromX: hinge.x, fromY: hinge.y,
                     toX: tipX, toY: tipY, isRight: isRight)
        // Hinge pin at the pivot (same for every angle — reinforces visible rotation)
        pS(ctx, hinge.x, hinge.y, windowBlack)
        // Footpad once the leg has swung past horizontal
        if angleDeg >= 90 {
            pxS(ctx, tipX - 1, tipY, 3, 1, finDark)
        } else if angleDeg > 20 {
            pS(ctx, tipX, tipY, finDark)
        }
    }
}

/// Convenience wrappers for the fixed angles used by frame generators.
func drawF9LegsRetracted(_ ctx: CGContext, yOff: Int) {
    drawF9LegsAtAngle(ctx, yOff: yOff, angleDeg: 0)
}
func drawF9LegsMidDeploy(_ ctx: CGContext, yOff: Int) {
    drawF9LegsAtAngle(ctx, yOff: yOff, angleDeg: 90)
}
func drawF9LegsDeployed(_ ctx: CGContext, yOff: Int) {
    drawF9LegsAtAngle(ctx, yOff: yOff, angleDeg: 135)
}

/// Rigid 1px strut — stays a single-pixel line at any angle so the strut
/// always reads as perfectly straight (no staircase artifact from dual-pixel
/// thickness). For vertical runs we still paint a body-side neighbor to
/// give the stowed leg a bit of body to hide against; everything else is thin.
private func drawLegStrut(_ ctx: CGContext, fromX: Int, fromY: Int,
                          toX: Int, toY: Int, isRight: Bool) {
    let steps = max(abs(toX - fromX), abs(toY - fromY))
    guard steps > 0 else { return }
    let bodyward = isRight ? -1 : 1
    let isVertical = (fromX == toX)
    for i in 0...steps {
        let t = Double(i) / Double(steps)
        let x = Int((Double(fromX) * (1 - t) + Double(toX) * t).rounded())
        let y = Int((Double(fromY) * (1 - t) + Double(toY) * t).rounded())
        pS(ctx, x, y, finDark)
        if isVertical {
            pS(ctx, x + bodyward, y, finDark)
        }
    }
}

// MARK: - Frame generators

func beginFrame(width: Int = 48, height: Int = 48) -> CGContext {
    let ctx = CGContext(
        data: nil, width: width, height: height,
        bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    ctx.interpolationQuality = .none
    // Transparent background
    ctx.clear(CGRect(x: 0, y: 0, width: width, height: height))
    return ctx
}

func savePNG(_ ctx: CGContext, to path: String) {
    guard let cg = ctx.makeImage() else {
        fputs("failed to make image for \(path)\n", stderr)
        return
    }
    let url = URL(fileURLWithPath: path)
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL,
                                                      UTType.png.identifier as CFString,
                                                      1, nil) else {
        fputs("failed to create destination \(path)\n", stderr)
        return
    }
    CGImageDestinationAddImage(dest, cg, nil)
    CGImageDestinationFinalize(dest)
}

// MARK: - Generate all states

ensureDir(outputDir)

func write(_ name: String, size: (Int, Int) = (48, 48), draw: (CGContext) -> Void) {
    let ctx = beginFrame(width: size.0, height: size.1)
    draw(ctx)
    savePNG(ctx, to: "\(outputDir)/rocket_\(name).png")
    print("  wrote rocket_\(name).png (\(size.0)×\(size.1))")
}

/// Starship frames render into a 72×72 canvas with `drawScale = 1.5`.
/// `drawScale` is a file-scoped var used by the `pxS`/`pS` helpers.
func writeStarship(_ name: String, draw: (CGContext) -> Void) {
    write(name, size: (72, 72)) { ctx in
        drawScale = 1.5
        draw(ctx)
        drawScale = 1.0
    }
}

print("Generating rocket sprites at \(outputDir)...")

// Standalone pad sprite (48x48 canvas, pad at bottom).
write("pad_a") { ctx in
    drawPad(ctx)
}

// onpad: 2 frames, rocket body only (pad is separate node)
write("onpad_a") { ctx in
    drawRocketBody(ctx, yOff: 0, windowLight: true)
}
write("onpad_b") { ctx in
    drawRocketBody(ctx, yOff: 0, windowLight: false)
}

// systems: 4 frames, blink sequence faster cadence (rolling lights)
write("systems_a") { ctx in
    drawRocketBody(ctx, yOff: 0, windowLight: true)
    drawWarningLight(ctx, on: false)
}
write("systems_b") { ctx in
    drawRocketBody(ctx, yOff: 0, windowLight: false)
    drawWarningLight(ctx, on: true)
}
write("systems_c") { ctx in
    drawRocketBody(ctx, yOff: 0, windowLight: true)
    drawWarningLight(ctx, on: true)
}
write("systems_d") { ctx in
    drawRocketBody(ctx, yOff: 0, windowLight: false)
    drawWarningLight(ctx, on: false)
}

// cruise: 2 frames, lifted, small flame alternating
write("cruise_a") { ctx in
    drawRocketBody(ctx, yOff: 2, windowLight: true)
    drawFlame(ctx, yOff: 2, size: .small)
}
write("cruise_b") { ctx in
    drawRocketBody(ctx, yOff: 2, windowLight: true)
    drawFlame(ctx, yOff: 2, size: .medium)
}

// abort: 2 frames, rocket body only (pad is separate node)
write("abort_a") { ctx in
    drawRocketBody(ctx, yOff: 0, windowLight: true)
    drawFlame(ctx, yOff: 0, size: .small)
    drawWarningLight(ctx, on: true)
}
write("abort_b") { ctx in
    drawRocketBody(ctx, yOff: 0, windowLight: true)
    drawFlame(ctx, yOff: 0, size: .small)
    drawWarningLight(ctx, on: false)
}

// landing: 3 frames, descending with legs deployed + small flame
write("landing_a") { ctx in
    drawRocketBody(ctx, yOff: 8, windowLight: true)
    drawLandingLegs(ctx, yOff: 8)
    drawFlame(ctx, yOff: 8, size: .small)
}
write("landing_b") { ctx in
    drawRocketBody(ctx, yOff: 4, windowLight: true)
    drawLandingLegs(ctx, yOff: 4)
    drawFlame(ctx, yOff: 4, size: .small)
}
write("landing_c") { ctx in
    drawRocketBody(ctx, yOff: 0, windowLight: true)
    drawLandingLegs(ctx, yOff: 0)
}

// liftoff: 2 frames, no pad, big flame + smoke
write("liftoff_a") { ctx in
    drawRocketBody(ctx, yOff: 4, windowLight: true)
    drawFlame(ctx, yOff: 4, size: .medium)
    drawSmoke(ctx)
}
write("liftoff_b") { ctx in
    drawRocketBody(ctx, yOff: 8, windowLight: true)
    drawFlame(ctx, yOff: 8, size: .large)
    drawSmoke(ctx)
}

// ── Falcon 9 variant (f9_ prefix). Complete redesign: flat-top fairing,
//    prominent cross-hatch grid fins (visible across all states), landing
//    legs that fold from top down during descent.

write("f9_onpad_a") { ctx in
    drawF9Body(ctx, yOff: 0, windowLight: true)
    drawF9GridFins(ctx, yOff: 0)
    drawF9LegsDeployed(ctx, yOff: 0)
}
write("f9_onpad_b") { ctx in
    drawF9Body(ctx, yOff: 0, windowLight: false)
    drawF9GridFins(ctx, yOff: 0)
    drawF9LegsDeployed(ctx, yOff: 0)
}
write("f9_systems_a") { ctx in
    drawF9Body(ctx, yOff: 0, windowLight: true)
    drawF9GridFins(ctx, yOff: 0)
    drawF9LegsDeployed(ctx, yOff: 0)
    drawWarningLight(ctx, on: false)
}
write("f9_systems_b") { ctx in
    drawF9Body(ctx, yOff: 0, windowLight: false)
    drawF9GridFins(ctx, yOff: 0)
    drawF9LegsDeployed(ctx, yOff: 0)
    drawWarningLight(ctx, on: true)
}
write("f9_systems_c") { ctx in
    drawF9Body(ctx, yOff: 0, windowLight: true)
    drawF9GridFins(ctx, yOff: 0)
    drawF9LegsDeployed(ctx, yOff: 0)
    drawWarningLight(ctx, on: true)
}
write("f9_systems_d") { ctx in
    drawF9Body(ctx, yOff: 0, windowLight: false)
    drawF9GridFins(ctx, yOff: 0)
    drawF9LegsDeployed(ctx, yOff: 0)
    drawWarningLight(ctx, on: false)
}
// cruise: legs retracted (folded up along body — will unfold top-down on landing)
write("f9_cruise_a") { ctx in
    drawF9Body(ctx, yOff: 2, windowLight: true)
    drawF9GridFins(ctx, yOff: 2)
    drawF9LegsRetracted(ctx, yOff: 2)
    drawF9Flame(ctx, yOff: 2, size: .small)
}
write("f9_cruise_b") { ctx in
    drawF9Body(ctx, yOff: 2, windowLight: true)
    drawF9GridFins(ctx, yOff: 2)
    drawF9LegsRetracted(ctx, yOff: 2)
    drawF9Flame(ctx, yOff: 2, size: .medium)
}
write("f9_abort_a") { ctx in
    drawF9Body(ctx, yOff: 0, windowLight: true)
    drawF9GridFins(ctx, yOff: 0)
    drawF9LegsRetracted(ctx, yOff: 0)
    drawF9Flame(ctx, yOff: 0, size: .small)
    drawWarningLight(ctx, on: true)
}
write("f9_abort_b") { ctx in
    drawF9Body(ctx, yOff: 0, windowLight: true)
    drawF9GridFins(ctx, yOff: 0)
    drawF9LegsRetracted(ctx, yOff: 0)
    drawF9Flame(ctx, yOff: 0, size: .small)
    drawWarningLight(ctx, on: false)
}
// landing sequence: 4 frames of progressive hinge rotation around fixed pivot.
// Legs rotate 0° (stowed up) → 45° → 90° (horizontal out) → 135° (fully deployed).
write("f9_landing_a") { ctx in
    drawF9Body(ctx, yOff: 6, windowLight: true)
    drawF9GridFins(ctx, yOff: 6)
    drawF9LegsAtAngle(ctx, yOff: 6, angleDeg: 0)
    drawF9Flame(ctx, yOff: 6, size: .small)
}
write("f9_landing_b") { ctx in
    drawF9Body(ctx, yOff: 4, windowLight: true)
    drawF9GridFins(ctx, yOff: 4)
    drawF9LegsAtAngle(ctx, yOff: 4, angleDeg: 45)
    drawF9Flame(ctx, yOff: 4, size: .small)
}
write("f9_landing_c") { ctx in
    drawF9Body(ctx, yOff: 2, windowLight: true)
    drawF9GridFins(ctx, yOff: 2)
    drawF9LegsAtAngle(ctx, yOff: 2, angleDeg: 90)
    drawF9Flame(ctx, yOff: 2, size: .small)
}
write("f9_landing_d") { ctx in
    drawF9Body(ctx, yOff: 0, windowLight: true)
    drawF9GridFins(ctx, yOff: 0)
    drawF9LegsAtAngle(ctx, yOff: 0, angleDeg: 135)
}

// retract sequence: reverse of landing (deployed → horizontal → up).
// Played once as the rocket lifts off the pad; covers `cruise` frames for ~0.6s.
write("f9_retract_a") { ctx in
    drawF9Body(ctx, yOff: 0, windowLight: true)
    drawF9GridFins(ctx, yOff: 0)
    drawF9LegsAtAngle(ctx, yOff: 0, angleDeg: 135)
    drawF9Flame(ctx, yOff: 0, size: .medium)
}
write("f9_retract_b") { ctx in
    drawF9Body(ctx, yOff: 0, windowLight: true)
    drawF9GridFins(ctx, yOff: 0)
    drawF9LegsAtAngle(ctx, yOff: 0, angleDeg: 90)
    drawF9Flame(ctx, yOff: 0, size: .medium)
}
write("f9_retract_c") { ctx in
    drawF9Body(ctx, yOff: 0, windowLight: true)
    drawF9GridFins(ctx, yOff: 0)
    drawF9LegsAtAngle(ctx, yOff: 0, angleDeg: 45)
    drawF9Flame(ctx, yOff: 0, size: .small)
}
write("f9_retract_d") { ctx in
    drawF9Body(ctx, yOff: 2, windowLight: true)
    drawF9GridFins(ctx, yOff: 2)
    drawF9LegsAtAngle(ctx, yOff: 2, angleDeg: 0)
    drawF9Flame(ctx, yOff: 2, size: .small)
}
write("f9_liftoff_a") { ctx in
    drawF9Body(ctx, yOff: 4, windowLight: true)
    drawF9GridFins(ctx, yOff: 4)
    drawF9LegsRetracted(ctx, yOff: 4)
    drawF9Flame(ctx, yOff: 4, size: .medium)
    drawSmoke(ctx)
}
write("f9_liftoff_b") { ctx in
    drawF9Body(ctx, yOff: 8, windowLight: true)
    drawF9GridFins(ctx, yOff: 8)
    drawF9LegsRetracted(ctx, yOff: 8)
    drawF9Flame(ctx, yOff: 8, size: .large)
    drawSmoke(ctx)
}
// F9 pad sprite — thin white platform
write("f9_pad_a") { ctx in
    drawF9Pad(ctx)
}
print("F9 variant redesigned.")

// ── Space Shuttle variant (prefix rocket_shuttle_)

write("shuttle_onpad_a") { ctx in drawShuttleBody(ctx, yOff: 0, windowLight: true) }
write("shuttle_onpad_b") { ctx in drawShuttleBody(ctx, yOff: 0, windowLight: false) }
write("shuttle_systems_a") { ctx in
    drawShuttleBody(ctx, yOff: 0, windowLight: true)
    drawWarningLight(ctx, on: false)
}
write("shuttle_systems_b") { ctx in
    drawShuttleBody(ctx, yOff: 0, windowLight: false)
    drawWarningLight(ctx, on: true)
}
write("shuttle_systems_c") { ctx in
    drawShuttleBody(ctx, yOff: 0, windowLight: true)
    drawWarningLight(ctx, on: true)
}
write("shuttle_systems_d") { ctx in
    drawShuttleBody(ctx, yOff: 0, windowLight: false)
    drawWarningLight(ctx, on: false)
}
write("shuttle_cruise_a") { ctx in
    drawShuttleBody(ctx, yOff: 2, windowLight: true)
    drawShuttleFlame(ctx, yOff: 2, size: .small)
}
write("shuttle_cruise_b") { ctx in
    drawShuttleBody(ctx, yOff: 2, windowLight: true)
    drawShuttleFlame(ctx, yOff: 2, size: .medium)
}
write("shuttle_abort_a") { ctx in
    drawShuttleBody(ctx, yOff: 0, windowLight: true)
    drawShuttleFlame(ctx, yOff: 0, size: .small)
    drawWarningLight(ctx, on: true)
}
write("shuttle_abort_b") { ctx in
    drawShuttleBody(ctx, yOff: 0, windowLight: true)
    drawShuttleFlame(ctx, yOff: 0, size: .small)
    drawWarningLight(ctx, on: false)
}
write("shuttle_landing_a") { ctx in
    drawShuttleBody(ctx, yOff: 6, windowLight: true)
    drawShuttleFlame(ctx, yOff: 6, size: .small)
}
write("shuttle_landing_b") { ctx in
    drawShuttleBody(ctx, yOff: 3, windowLight: true)
    drawShuttleFlame(ctx, yOff: 3, size: .small)
}
write("shuttle_landing_c") { ctx in
    drawShuttleBody(ctx, yOff: 0, windowLight: true)
}
write("shuttle_liftoff_a") { ctx in
    drawShuttleBody(ctx, yOff: 4, windowLight: true)
    drawShuttleFlame(ctx, yOff: 4, size: .medium)
    drawSmoke(ctx)
}
write("shuttle_liftoff_b") { ctx in
    drawShuttleBody(ctx, yOff: 8, windowLight: true)
    drawShuttleFlame(ctx, yOff: 8, size: .large)
    drawSmoke(ctx)
}
write("shuttle_pad_a") { ctx in drawShuttlePad(ctx) }
print("Shuttle variant added.")

// MARK: - Starship variant (prefix rocket_starship_)
// SpaceX Starship — tall two-stage design. In Phase 1 the sprite is still drawn
// on a 48x48 canvas (same as other kinds); RocketEntity applies setScale(1.5)
// at runtime to make it visually larger.
//
// Layout (48x48 canvas, origin bottom-left, baseY = 4):
//   0..22    → Super Heavy booster (~18 rows tall) drawn by drawStarship3Booster
//   20..22   → hot-staging ring (dark band)
//   22..43   → Starship upper stage drawn by drawStarship3Body (~20 rows)
//
// The ship body is drawn centered on cx=24, booster same. Booster is slightly
// wider than ship per real Starship proportions (booster 10 wide, ship 8 wide).

/// Starship UPPER STAGE (the Ship). Pointy nose, 2 forward flaps, 2 aft flaps.
/// `yOff` shifts the whole ship vertically (used for flight offsets).
/// `shipBaseY`: the y-row where the ship's bottom starts. Defaults to baseY+22
/// so the ship sits directly on top of the Super Heavy booster when stacked.
func drawStarship3Body(_ ctx: CGContext, yOff: Int = 0,
                       shipBaseY: Int? = nil,
                       windowLight: Bool = true) {
    let baseY = (shipBaseY ?? (4 + 22)) + yOff
    let cx = 24

    // Ship main body (8 wide, from baseY up to baseY+16)
    pxS(ctx, cx - 4, baseY, 8, 16, bodyWhite)
    // Right-side shadow
    pxS(ctx, cx + 2, baseY, 2, 16, bodyShadow)
    // Left + right outline for contrast on pale backgrounds
    pxS(ctx, cx - 4, baseY, 1, 16, partMetal)
    pxS(ctx, cx + 3, baseY, 1, 16, partMetal)

    // Nose cone taper — 4 rows narrowing to a 1px tip
    pxS(ctx, cx - 3, baseY + 16, 6, 1, bodyWhite)
    pS(ctx, cx - 3, baseY + 16, partMetal)
    pS(ctx, cx + 2, baseY + 16, partMetal)
    pxS(ctx, cx - 2, baseY + 17, 4, 1, bodyWhite)
    pS(ctx, cx - 2, baseY + 17, partMetal)
    pS(ctx, cx + 1, baseY + 17, partMetal)
    pxS(ctx, cx - 1, baseY + 18, 2, 1, bodyWhite)
    pS(ctx, cx - 1, baseY + 18, partMetal)
    pS(ctx, cx, baseY + 18, partMetal)
    // Pointy tip
    pS(ctx, cx, baseY + 19, partMetal)

    // Forward flaps (near the nose, small triangular fins outside the body)
    //   left: 1x2 at (cx-5, baseY+13..14); right mirrored
    pxS(ctx, cx - 5, baseY + 13, 1, 2, bodyShadow)
    pS(ctx, cx - 6, baseY + 13, partMetal)
    pxS(ctx, cx + 4, baseY + 13, 1, 2, bodyShadow)
    pS(ctx, cx + 5, baseY + 13, partMetal)

    // Aft flaps (wider, near base — 2x3 per side)
    pxS(ctx, cx - 6, baseY + 1, 2, 3, bodyShadow)
    pS(ctx, cx - 7, baseY + 1, partMetal)
    pS(ctx, cx - 7, baseY + 2, partMetal)
    pxS(ctx, cx + 4, baseY + 1, 2, 3, bodyShadow)
    pS(ctx, cx + 6, baseY + 1, partMetal)
    pS(ctx, cx + 6, baseY + 2, partMetal)

    // Cockpit / forward window band — small dark horizontal stripe near top-third
    pxS(ctx, cx - 2, baseY + 11, 4, 1, windowBlack)
    if windowLight {
        pS(ctx, cx - 1, baseY + 11, windowLit)
    }

    // Small Raptor engine nozzles cluster at the base (3 tiny bells)
    pxS(ctx, cx - 3, baseY - 1, 2, 1, partMetal)
    pxS(ctx, cx - 1, baseY - 1, 2, 1, partMetal)
    pxS(ctx, cx + 1, baseY - 1, 2, 1, partMetal)
}

/// Starship SUPER HEAVY booster (lower stage). Sits in rows 4..22 of the canvas
/// (~18 rows tall, 10 wide). Taller hot-staging ring at its very top, 4 grid
/// fins near top, large engine cluster at very bottom.
func drawStarship3Booster(_ ctx: CGContext, yOff: Int = 0) {
    let baseY = 4 + yOff
    let cx = 24
    // Main cylinder — 8 wide (cx-4..cx+3), 17 rows tall (was 18; trimmed by 1
    // so the booster renders 30pt at 1.5× instead of 31.5pt).
    pxS(ctx, cx - 4, baseY, 8, 17, bodyWhite)
    // Right-side shadow band
    pxS(ctx, cx + 2, baseY, 2, 17, bodyShadow)
    // Left/right outline
    pxS(ctx, cx - 4, baseY, 1, 17, partMetal)
    pxS(ctx, cx + 3, baseY, 1, 17, partMetal)

    // Hot-staging ring — bold dark 2-row band at the top (baseY+15..16).
    pxS(ctx, cx - 4, baseY + 15, 8, 2, windowBlack)
    // Tiny white vent slots in the ring for detail
    pS(ctx, cx - 2, baseY + 16, bodyShadow)
    pS(ctx, cx, baseY + 16, bodyShadow)
    pS(ctx, cx + 2, baseY + 16, bodyShadow)

    // Grid fins — flush against 8-wide body.
    drawStarshipGridFin(ctx, leftX: cx - 7, bottomY: baseY + 11)
    drawStarshipGridFin(ctx, leftX: cx + 4, bottomY: baseY + 11)

    // Engine cluster — 8 wide ring at the bottom with hint of nozzle arcs.
    pxS(ctx, cx - 5, baseY - 2, 10, 2, partMetal)
    pS(ctx, cx - 4, baseY - 3, partMetal)
    pS(ctx, cx - 1, baseY - 3, partMetal)
    pS(ctx, cx + 2, baseY - 3, partMetal)

    // Subtle horizontal ring near mid-body
    pxS(ctx, cx - 4, baseY + 7, 8, 1, bodyShadow)

}

/// 3x3 grid fin for Super Heavy (smaller than F9's 5x5, flush against body).
private func drawStarshipGridFin(_ ctx: CGContext, leftX: Int, bottomY: Int) {
    // outer border
    pxS(ctx, leftX, bottomY, 3, 1, windowBlack)
    pxS(ctx, leftX, bottomY + 2, 3, 1, windowBlack)
    pxS(ctx, leftX, bottomY, 1, 3, windowBlack)
    pxS(ctx, leftX + 2, bottomY, 1, 3, windowBlack)
    // inner cell
    pS(ctx, leftX + 1, bottomY + 1, bodyShadow)
}

/// Starship pad — massive Orbital Launch Mount-ish platform. Wider and taller
/// than F9 pad to support the ~1.5x sprite. Drawn at the bottom of the canvas.
func drawStarshipPad(_ ctx: CGContext) {
    // Big concrete-ish top slab
    pxS(ctx, 8, 0, 32, 2, padGray)
    pxS(ctx, 8, 2, 32, 2, padDark)
    // Central circular flame deflector hint
    pS(ctx, 23, 2, windowBlack)
    pS(ctx, 24, 2, windowBlack)
    // Side pillars / legs
    pxS(ctx, 6, 0, 2, 3, padDark)
    pxS(ctx, 40, 0, 2, 3, padDark)
    // Mini supports
    pS(ctx, 5, 0, padDark)
    pS(ctx, 42, 0, padDark)
}

/// Small flame emerging from beneath the booster (engine cluster at baseY-2).
func drawStarshipFlame(_ ctx: CGContext, yOff: Int, size: FlameSize) {
    let cx = 24
    let baseY = 4 + yOff
    let top = baseY - 3
    switch size {
    case .small:
        pxS(ctx, cx - 3, top - 2, 6, 2, flameOrange)
        pxS(ctx, cx - 1, top - 4, 2, 2, flameCore)
    case .medium:
        pxS(ctx, cx - 4, top - 2, 8, 2, flameRed)
        pxS(ctx, cx - 3, top - 4, 6, 2, flameOrange)
        pxS(ctx, cx - 1, top - 6, 2, 2, flameCore)
    case .large:
        pxS(ctx, cx - 5, top - 2, 10, 2, flameRed)
        pxS(ctx, cx - 4, top - 4, 8, 2, flameOrange)
        pxS(ctx, cx - 2, top - 6, 4, 2, flameCore)
        pxS(ctx, cx - 1, top - 8, 2, 2, windowLit)
    }
}

/// Dramatic Super-Heavy liftoff plume. Unlike `drawStarshipFlame` which
/// extends the flame BELOW the engine ring (off-canvas on a 72-canvas sprite
/// with sprite-bottom at scene y=5), this fills the BOTTOM of the canvas up
/// TO the engine ring so the plume actually renders.
///
/// All coords in 48-canvas; `pxS` scales 1.5× for the 72-canvas Starship.
/// Engine ring sits at y=2..3 (drawStarship3Booster: `baseY-2=2`), so we paint
/// from y=0 up to y=3 with layered heat colors.
func drawStarshipBoosterLiftoffFlame(_ ctx: CGContext) {
    let cx = 24
    // Outer red glow — ~1.5× booster body width so the plume reads as "bigger
    // than the ship" without dominating the frame.
    pxS(ctx, cx - 6, 0, 12, 2, flameRed)
    // Mid orange
    pxS(ctx, cx - 4, 0, 8, 3, flameOrange)
    // Core — bright yellow/white at engine centerline
    pxS(ctx, cx - 2, 0, 4, 3, flameCore)
    pxS(ctx, cx - 1, 0, 2, 4, windowLit)
}

/// Small Raptor flame from UPPER stage only (when cruising / landing without
/// booster). Flame issues from the ship base (shipBaseY-1 area).
func drawStarshipShipFlame(_ ctx: CGContext, yOff: Int, size: FlameSize,
                           shipBaseY: Int? = nil) {
    let cx = 24
    let shipBase = (shipBaseY ?? (4 + 22)) + yOff
    let top = shipBase - 2
    switch size {
    case .small:
        pxS(ctx, cx - 2, top, 4, 2, flameOrange)
        pxS(ctx, cx - 1, top - 2, 2, 1, flameCore)
    case .medium:
        pxS(ctx, cx - 3, top, 6, 2, flameOrange)
        pxS(ctx, cx - 1, top - 2, 2, 2, flameCore)
    case .large:
        pxS(ctx, cx - 3, top, 6, 2, flameRed)
        pxS(ctx, cx - 2, top - 2, 4, 2, flameOrange)
        pxS(ctx, cx - 1, top - 4, 2, 2, flameCore)
    }
}

// ── Full stack on pad: booster at bottom + ship on top.
// The ship sits directly on the booster's hot-staging ring (shipBaseY = 4 + 18
// since booster top row is baseY+17; ship base = booster top + 1 = 22).
//
// When `yOff` is applied, both booster and ship shift together.

/// For on-pad / systems frames: full stack, booster + ship, ship perched on top.
func drawStarshipFullStack(_ ctx: CGContext, yOff: Int = 0, windowLight: Bool = true) {
    drawStarship3Booster(ctx, yOff: yOff)
    drawStarship3Body(ctx, yOff: yOff, shipBaseY: 4 + 18, windowLight: windowLight)
}

/// For cruise/landing/abort frames: ONLY the ship (booster has separated away).
/// Ship is drawn at the canvas baseline so its engines sit near y=4 (ground area).
/// Ship-alone keeps the SAME canvas y as the full-stack sprite so that a
/// texture swap (onpad full-stack → cruise ship-alone) does NOT visually
/// drop the ship on screen. Ship baseY matches full-stack's ship baseY (22).
func drawStarshipShipAlone(_ ctx: CGContext, yOff: Int = 0, windowLight: Bool = true) {
    drawStarship3Body(ctx, yOff: yOff, shipBaseY: 4 + 18, windowLight: windowLight)
}

// ── Generate Starship sprite set ──
// On-pad sprite is SHIP-ALONE. The booster is supplied by a separate
// `boosterNode` so `restoreBoosterFadeIn` can fade it in independently.
// (Previously the on-pad texture drew the full stack, which meant the booster
// popped in instantly when the texture swapped — the fade never read.)
writeStarship("starship_onpad_a") { ctx in drawStarshipShipAlone(ctx, yOff: 0, windowLight: true) }
writeStarship("starship_onpad_b") { ctx in drawStarshipShipAlone(ctx, yOff: 0, windowLight: false) }

writeStarship("starship_systems_a") { ctx in
    drawStarshipFullStack(ctx, yOff: 0, windowLight: true)
    drawWarningLight(ctx, on: false)
}
writeStarship("starship_systems_b") { ctx in
    drawStarshipFullStack(ctx, yOff: 0, windowLight: false)
    drawWarningLight(ctx, on: true)
}
writeStarship("starship_systems_c") { ctx in
    drawStarshipFullStack(ctx, yOff: 0, windowLight: true)
    drawWarningLight(ctx, on: true)
}
writeStarship("starship_systems_d") { ctx in
    drawStarshipFullStack(ctx, yOff: 0, windowLight: false)
    drawWarningLight(ctx, on: false)
}

// cruise: SHIP ALONE (booster already separated). Only ship flame.
// yOff stays at 0 — matches onpad's ship position so texture swaps don't
// visually shift the ship.
writeStarship("starship_cruise_a") { ctx in
    drawStarshipShipAlone(ctx, yOff: 0, windowLight: true)
    drawStarshipShipFlame(ctx, yOff: 0, size: .small, shipBaseY: 4 + 18)
}
writeStarship("starship_cruise_b") { ctx in
    drawStarshipShipAlone(ctx, yOff: 0, windowLight: true)
    drawStarshipShipFlame(ctx, yOff: 0, size: .medium, shipBaseY: 4 + 18)
}

// abort: ship alone, warning light flashing, small hover flame
writeStarship("starship_abort_a") { ctx in
    drawStarshipShipAlone(ctx, yOff: 0, windowLight: true)
    drawStarshipShipFlame(ctx, yOff: 0, size: .small, shipBaseY: 4 + 18)
    drawWarningLight(ctx, on: true)
}
writeStarship("starship_abort_b") { ctx in
    drawStarshipShipAlone(ctx, yOff: 0, windowLight: true)
    drawStarshipShipFlame(ctx, yOff: 0, size: .small, shipBaseY: 4 + 18)
    drawWarningLight(ctx, on: false)
}

// landing: ship alone descending (3 frames of yOff)
writeStarship("starship_landing_a") { ctx in
    drawStarshipShipAlone(ctx, yOff: 8, windowLight: true)
    drawStarshipShipFlame(ctx, yOff: 8, size: .small, shipBaseY: 4 + 18)
}
writeStarship("starship_landing_b") { ctx in
    drawStarshipShipAlone(ctx, yOff: 4, windowLight: true)
    drawStarshipShipFlame(ctx, yOff: 4, size: .small, shipBaseY: 4 + 18)
}
writeStarship("starship_landing_c") { ctx in
    drawStarshipShipAlone(ctx, yOff: 0, windowLight: true)
}

// liftoff: full stack (booster still attached), big flame + smoke.
// Played as the stack rises — booster separation is handled procedurally in
// the state, NOT in the frames themselves.
writeStarship("starship_liftoff_a") { ctx in
    drawStarshipFullStack(ctx, yOff: 4, windowLight: true)
    drawStarshipFlame(ctx, yOff: 4, size: .medium)
    drawSmoke(ctx)
}
writeStarship("starship_liftoff_b") { ctx in
    drawStarshipFullStack(ctx, yOff: 8, windowLight: true)
    drawStarshipFlame(ctx, yOff: 8, size: .large)
    drawSmoke(ctx)
}

// retract: ship alone (short, simple — used as takeoff primer if needed)
writeStarship("starship_retract_a") { ctx in
    drawStarshipFullStack(ctx, yOff: 0, windowLight: true)
    drawStarshipFlame(ctx, yOff: 0, size: .small)
}
writeStarship("starship_retract_b") { ctx in
    drawStarshipFullStack(ctx, yOff: 2, windowLight: true)
    drawStarshipFlame(ctx, yOff: 2, size: .medium)
}

// Booster sprite frames for the detachable `boosterNode`.
//   _a: body only — rest pose (on OLM) and post-separation dead-fall.
//   _b: body + huge Super-Heavy liftoff plume — phase-2 ignition.
// RocketEntity.setBoosterIgnited(_:) swaps between them at the right moments
// in the Cruising state's liftoff sequence.
writeStarship("starship_booster_a") { ctx in
    drawStarship3Booster(ctx, yOff: 0)
}
writeStarship("starship_booster_b") { ctx in
    // Draw the flame FIRST so the booster body renders over it at the engine
    // ring line (cleaner engine/flame boundary).
    drawStarshipBoosterLiftoffFlame(ctx)
    drawStarship3Booster(ctx, yOff: 0)
}

// Starship pad — large Orbital Launch Mount
writeStarship("starship_pad_a") { ctx in drawStarshipPad(ctx) }

print("Starship variant added.")

print("Done.")
