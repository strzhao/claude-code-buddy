#!/usr/bin/env swift
// generate-placeholders.swift
// Run with: swift Scripts/generate-placeholders.swift
// Generates 32x32 pixel-art cat PNG sprites for all states.

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// MARK: - Output directory

let outputDir = "Sources/ClaudeCodeBuddy/Assets/Sprites"

func ensureDir(_ path: String) {
    try? FileManager.default.createDirectory(atPath: path,
                                             withIntermediateDirectories: true)
}

ensureDir(outputDir)

// MARK: - Colors per state

let stateColors: [(name: String, r: CGFloat, g: CGFloat, b: CGFloat)] = [
    ("idle",     0.25, 0.45, 0.90),  // blue
    ("thinking", 0.95, 0.80, 0.20),  // yellow
    ("coding",   0.20, 0.75, 0.35),  // green
    ("enter",    0.90, 0.90, 0.90),  // light gray
    ("exit",     0.55, 0.55, 0.55),  // gray
]

// MARK: - Drawing

/// Draws a tiny pixel-art cat silhouette into a 32x32 CGContext.
///
/// - Parameters:
///   - ctx: The CGContext to draw into (32x32).
///   - r/g/b: Cat body color.
///   - frame: Frame index (1-4) for slight animation variations.
func drawCat(ctx: CGContext, r: CGFloat, g: CGFloat, b: CGFloat, frame: Int) {
    let w: CGFloat = 32
    let h: CGFloat = 32

    ctx.clear(CGRect(x: 0, y: 0, width: w, height: h))

    // ---- Body (oval) ----
    ctx.setFillColor(CGColor(red: r, green: g, blue: b, alpha: 1))
    let bodyRect = CGRect(x: 8, y: 6, width: 18, height: 14)
    ctx.fillEllipse(in: bodyRect)

    // ---- Head (circle) ----
    let headRect = CGRect(x: 11, y: 16, width: 12, height: 11)
    ctx.fillEllipse(in: headRect)

    // ---- Ears (triangles) ----
    // Left ear
    let leftEarPath = CGMutablePath()
    leftEarPath.move(to: CGPoint(x: 11, y: 24))
    leftEarPath.addLine(to: CGPoint(x: 9, y: 29))
    leftEarPath.addLine(to: CGPoint(x: 14, y: 27))
    leftEarPath.closeSubpath()
    ctx.addPath(leftEarPath)
    ctx.fillPath()

    // Right ear
    let rightEarPath = CGMutablePath()
    rightEarPath.move(to: CGPoint(x: 23, y: 24))
    rightEarPath.addLine(to: CGPoint(x: 25, y: 29))
    rightEarPath.addLine(to: CGPoint(x: 20, y: 27))
    rightEarPath.closeSubpath()
    ctx.addPath(rightEarPath)
    ctx.fillPath()

    // ---- Tail ----
    // Tail position varies per frame to simulate wagging
    let tailOffsets: [CGFloat] = [0, 2, 4, 2]
    let tailDelta = tailOffsets[(frame - 1) % tailOffsets.count]

    let tailPath = CGMutablePath()
    tailPath.move(to: CGPoint(x: 8, y: 8))
    tailPath.addCurve(
        to: CGPoint(x: 2, y: 14 + tailDelta),
        control1: CGPoint(x: 4, y: 8),
        control2: CGPoint(x: 2, y: 10 + tailDelta)
    )
    ctx.setLineWidth(2)
    ctx.setStrokeColor(CGColor(red: r * 0.7, green: g * 0.7, blue: b * 0.7, alpha: 1))
    ctx.addPath(tailPath)
    ctx.strokePath()

    // ---- Eyes ----
    // Alternate between open and half-open
    let eyeHeight: CGFloat = frame % 2 == 0 ? 2 : 3
    ctx.setFillColor(CGColor(red: 0.05, green: 0.05, blue: 0.05, alpha: 1))
    ctx.fillEllipse(in: CGRect(x: 13, y: 18, width: 3, height: eyeHeight))
    ctx.fillEllipse(in: CGRect(x: 19, y: 18, width: 3, height: eyeHeight))

    // ---- Nose ----
    ctx.setFillColor(CGColor(red: 0.9, green: 0.4, blue: 0.5, alpha: 1))
    ctx.fill(CGRect(x: 16, y: 15, width: 2, height: 1))
}

// MARK: - PNG writer

func writePNG(ctx: CGContext, to path: String) {
    guard let image = ctx.makeImage() else {
        print("Failed to create image for \(path)")
        return
    }
    let url = URL(fileURLWithPath: path)
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
        print("Failed to create destination for \(path)")
        return
    }
    CGImageDestinationAddImage(dest, image, nil)
    if CGImageDestinationFinalize(dest) {
        print("Wrote \(path)")
    } else {
        print("Failed to finalize \(path)")
    }
}

// MARK: - Generate all frames

// Frames per state
let framesPerState: [String: Int] = [
    "idle":     4,
    "thinking": 4,
    "coding":   4,
    "enter":    3,
    "exit":     3,
]

let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)

for stateInfo in stateColors {
    let stateName = stateInfo.name
    let frameCount = framesPerState[stateName] ?? 4

    for frame in 1...frameCount {
        guard let ctx = CGContext(
            data: nil,
            width: 32,
            height: 32,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo.rawValue
        ) else {
            print("Could not create CGContext")
            continue
        }

        drawCat(ctx: ctx, r: stateInfo.r, g: stateInfo.g, b: stateInfo.b, frame: frame)

        let outPath = "\(outputDir)/cat-\(stateName)-\(frame).png"
        writePNG(ctx: ctx, to: outPath)
    }
}

print("Done generating \(stateColors.flatMap { _ in [1] }.count * 4) sprite frames.")
