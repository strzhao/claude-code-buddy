#!/usr/bin/env swift
// generate-launch-tower.swift
// Creates 16x16 boundary-launch-tower.png for rocket mode.

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let outputPath = "Sources/ClaudeCodeBuddy/Assets/Sprites/boundary-launch-tower.png"

func rgb(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1.0) -> CGColor {
    CGColor(red: CGFloat(r) / 255.0, green: CGFloat(g) / 255.0, blue: CGFloat(b) / 255.0, alpha: a)
}

let towerDark  = rgb(60, 60, 70)
let towerMid   = rgb(100, 100, 112)
let towerLight = rgb(160, 160, 170)
let warnRed    = rgb(255, 40, 40)

func px(_ ctx: CGContext, _ x: Int, _ y: Int, _ w: Int, _ h: Int, _ color: CGColor) {
    ctx.setFillColor(color)
    ctx.fill(CGRect(x: x, y: y, width: w, height: h))
}
func p(_ ctx: CGContext, _ x: Int, _ y: Int, _ color: CGColor) {
    px(ctx, x, y, 1, 1, color)
}

// 16x32 canvas — taller so the tower visually exceeds the 48-tall rocket when rendered at 2x.
let W = 16, H = 32
let ctx = CGContext(
    data: nil, width: W, height: H,
    bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
)!
ctx.interpolationQuality = .none
ctx.clear(CGRect(x: 0, y: 0, width: W, height: H))

// Main column: two vertical beams at x=2 and x=4, extending nearly full height
px(ctx, 2, 1, 1, 29, towerMid)
px(ctx, 4, 1, 1, 29, towerMid)

// Cross-bracing X pattern every 4 pixels
for base in stride(from: 2, to: 28, by: 4) {
    // X going up-right
    p(ctx, 2, base, towerDark)
    p(ctx, 3, base + 1, towerDark)
    p(ctx, 4, base + 2, towerDark)
    // X going up-left
    p(ctx, 4, base, towerDark)
    p(ctx, 3, base + 1, towerDark)
    p(ctx, 2, base + 2, towerDark)
}

// Highlight dashes along the center
for y in stride(from: 3, through: 29, by: 6) {
    p(ctx, 3, y, towerLight)
}

// Upper service arm (points right toward rocket) at y=20-22
px(ctx, 5, 20, 8, 1, towerMid)
px(ctx, 5, 22, 8, 1, towerMid)
px(ctx, 5, 21, 8, 1, towerDark)
p(ctx, 7, 21, towerLight)
p(ctx, 10, 21, towerLight)
// Arm tip — swing platform
px(ctx, 13, 19, 1, 4, towerDark)
p(ctx, 12, 19, towerDark)
p(ctx, 12, 22, towerDark)

// Lower service arm at y=10-12
px(ctx, 5, 10, 6, 1, towerMid)
px(ctx, 5, 12, 6, 1, towerMid)
px(ctx, 5, 11, 6, 1, towerDark)
p(ctx, 7, 11, towerLight)
p(ctx, 10, 11, towerLight)

// Fuel/umbilical block halfway up
px(ctx, 5, 5, 3, 3, towerDark)
p(ctx, 6, 6, towerLight)

// Crown at top
px(ctx, 1, 29, 5, 1, towerMid)
px(ctx, 2, 30, 3, 1, towerLight)
// Spire + warning light
p(ctx, 3, 31, warnRed)

// Ground flare base: legs splaying outward
px(ctx, 1, 0, 1, 2, towerDark)
px(ctx, 5, 0, 1, 2, towerDark)
p(ctx, 0, 0, towerDark)
p(ctx, 6, 0, towerDark)
// Foundation pad
px(ctx, 0, 0, 7, 1, towerDark)

// Write PNG
let url = URL(fileURLWithPath: outputPath)
guard let cg = ctx.makeImage(),
      let dest = CGImageDestinationCreateWithURL(url as CFURL,
                                                  UTType.png.identifier as CFString,
                                                  1, nil) else {
    fputs("failed to write PNG\n", stderr)
    exit(1)
}
CGImageDestinationAddImage(dest, cg, nil)
CGImageDestinationFinalize(dest)
print("wrote \(outputPath)")
