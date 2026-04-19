#!/usr/bin/env swift
// slice-dog-sprites.swift
//
// Slices pixel dog sprite sheets into individual animation frames for the
// Claude Code Buddy skin system.
//
// Sprite sheet layout (512x432, 8 cols × 9 rows, cell = 64×48):
//   Row 0: Standing idle (8 frames)  → idle-a
//   Row 1: Sitting (6 frames)        → idle-b
//   Row 2: Lying down (8 frames)     → sleep
//   Row 3: Jumping (5 frames)        → jump
//   Row 4: Walking (8 frames)        → walk-a
//   Row 5: Running (8 frames)        → walk-b
//   Row 6: Crouching run (8 frames)  → scared
//   Row 7: Begging/standing (8 frames) → paw
//   Row 8: Curled up (4 frames)      → clean
//
// Usage:
//   swift Scripts/slice-dog-sprites.swift <output-dir>
//
// This slices all 12 even-numbered sheets (Dogs-Remastered-00..22) from
// ~/Downloads/Pixel Dogs-Sprites/ into the output directory.

import Foundation
import CoreGraphics
import ImageIO

// MARK: - Configuration

struct VariantConfig {
    let id: String
    let name: String
    let sheetIndex: Int  // even number: 00, 02, 04, ...
}

let variants: [VariantConfig] = [
    VariantConfig(id: "chocolate", name: "Chocolate", sheetIndex: 0),
    VariantConfig(id: "golden", name: "Golden", sheetIndex: 2),
    VariantConfig(id: "dark-gray", name: "Dark Gray", sheetIndex: 4),
    VariantConfig(id: "blue", name: "Blue", sheetIndex: 6),
    VariantConfig(id: "rust", name: "Rust", sheetIndex: 8),
    VariantConfig(id: "silver", name: "Silver", sheetIndex: 10),
    VariantConfig(id: "warm-gray", name: "Warm Gray", sheetIndex: 12),
    VariantConfig(id: "dark-brown", name: "Dark Brown", sheetIndex: 14),
    VariantConfig(id: "cool-gray", name: "Cool Gray", sheetIndex: 16),
    VariantConfig(id: "deep-blue", name: "Deep Blue", sheetIndex: 18),
    VariantConfig(id: "copper", name: "Copper", sheetIndex: 20),
    VariantConfig(id: "orange", name: "Orange", sheetIndex: 22),
]

struct AnimRow {
    let name: String
    let row: Int
    let maxFrames: Int
}

let animations: [AnimRow] = [
    AnimRow(name: "idle-a", row: 0, maxFrames: 8),
    AnimRow(name: "idle-b", row: 1, maxFrames: 6),
    AnimRow(name: "sleep",  row: 2, maxFrames: 8),
    AnimRow(name: "jump",   row: 3, maxFrames: 5),
    AnimRow(name: "walk-a", row: 4, maxFrames: 8),
    AnimRow(name: "walk-b", row: 5, maxFrames: 8),
    AnimRow(name: "scared", row: 6, maxFrames: 8),
    AnimRow(name: "paw",    row: 7, maxFrames: 8),
    AnimRow(name: "clean",  row: 8, maxFrames: 4),
]

let cellWidth = 64
let cellHeight = 48
let outputSize = 48  // Scale to 48x48 square

let sourceDir = NSString(string: "~/Downloads/Pixel Dogs-Sprites").expandingTildeInPath

// MARK: - Argument Parsing

guard CommandLine.arguments.count == 2 else {
    fputs("Usage: swift Scripts/slice-dog-sprites.swift <output-dir>\n", stderr)
    exit(1)
}

let outputBaseDir = CommandLine.arguments[1]

// MARK: - Helper Functions

func loadImage(at path: String) -> CGImage? {
    let url = URL(fileURLWithPath: path)
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        return nil
    }
    return image
}

func savePNG(image: CGImage, to path: String) -> Bool {
    let url = URL(fileURLWithPath: path)
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
        return false
    }
    CGImageDestinationAddImage(dest, image, nil)
    return CGImageDestinationFinalize(dest)
}

/// Check if a cell at (col, row) in the sprite sheet has any non-transparent pixels.
func hasContent(in image: CGImage, col: Int, row: Int) -> Bool {
    let x = col * cellWidth
    let y = row * cellHeight
    guard x + cellWidth <= image.width, y + cellHeight <= image.height else { return false }
    let cropRect = CGRect(x: x, y: y, width: cellWidth, height: cellHeight)
    guard let cropped = image.cropping(to: cropRect) else { return false }

    let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
    guard let ctx = CGContext(
        data: nil, width: cellWidth, height: cellHeight,
        bitsPerComponent: 8, bytesPerRow: cellWidth * 4,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: bitmapInfo.rawValue
    ) else { return false }

    ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: cellWidth, height: cellHeight))
    guard let data = ctx.data else { return false }

    let pixels = data.assumingMemoryBound(to: UInt8.self)
    for i in stride(from: 3, to: cellWidth * cellHeight * 4, by: 4) {
        if pixels[i] > 10 { return true }  // alpha > 10 means visible
    }
    return false
}

func cropAndScale(image: CGImage, col: Int, row: Int) -> CGImage? {
    let x = col * cellWidth
    let y = row * cellHeight
    guard x + cellWidth <= image.width, y + cellHeight <= image.height else { return nil }

    let cropRect = CGRect(x: x, y: y, width: cellWidth, height: cellHeight)
    guard let cropped = image.cropping(to: cropRect) else { return nil }

    // Scale to outputSize x outputSize with nearest-neighbor
    let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
    guard let ctx = CGContext(
        data: nil, width: outputSize, height: outputSize,
        bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: bitmapInfo.rawValue
    ) else { return nil }

    ctx.interpolationQuality = .none

    // Center the 64x48 content within 48x48 by scaling proportionally
    // Scale factor: min(48/64, 48/48) = min(0.75, 1.0) = 0.75
    let scale = min(Double(outputSize) / Double(cellWidth), Double(outputSize) / Double(cellHeight))
    let scaledW = Double(cellWidth) * scale
    let scaledH = Double(cellHeight) * scale
    let offsetX = (Double(outputSize) - scaledW) / 2.0
    let offsetY = (Double(outputSize) - scaledH) / 2.0

    ctx.draw(cropped, in: CGRect(x: offsetX, y: offsetY, width: scaledW, height: scaledH))
    return ctx.makeImage()
}

// MARK: - Main

let fm = FileManager.default
let spritesDir = "\(outputBaseDir)/Sprites"
try? fm.createDirectory(atPath: spritesDir, withIntermediateDirectories: true)

var totalFrames = 0

for variant in variants {
    let sheetPath = "\(sourceDir)/Dogs-Remastered-\(String(format: "%02d", variant.sheetIndex)).png"
    guard let sheet = loadImage(at: sheetPath) else {
        fputs("Warning: Could not load \(sheetPath), skipping variant \(variant.id)\n", stderr)
        continue
    }

    let prefix = "dog-\(variant.id)"
    print("Processing variant: \(variant.id) (sheet \(variant.sheetIndex))...")

    for anim in animations {
        // Auto-detect actual frame count by checking for content
        var actualFrames = 0
        for col in 0..<anim.maxFrames {
            if hasContent(in: sheet, col: col, row: anim.row) {
                actualFrames = col + 1
            } else {
                break
            }
        }

        if actualFrames == 0 {
            fputs("  Warning: No frames found for \(anim.name) in variant \(variant.id)\n", stderr)
            continue
        }

        for frame in 0..<actualFrames {
            guard let scaled = cropAndScale(image: sheet, col: frame, row: anim.row) else { continue }
            let outPath = "\(spritesDir)/\(prefix)-\(anim.name)-\(frame + 1).png"
            if savePNG(image: scaled, to: outPath) {
                totalFrames += 1
            } else {
                fputs("  Error writing \(outPath)\n", stderr)
            }
        }
    }
}

print("Done! Sliced \(totalFrames) frames across \(variants.count) variants.")
