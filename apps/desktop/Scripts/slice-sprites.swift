#!/usr/bin/env swift
// slice-sprites.swift
// Run with: swift Scripts/slice-sprites.swift <sprite-sheet.png> '<json-config>'
//
// JSON config format:
// {
//   "frameSize": 32,
//   "outputSize": 48,
//   "animations": [
//     {"name": "idle-a", "row": 0, "frames": 4},
//     ...
//   ]
// }
//
// Output: Sources/ClaudeCodeBuddy/Assets/Sprites/cat-{name}-{frame}.png (1-indexed)

import Foundation
import CoreGraphics
import ImageIO

// MARK: - Config Structures

struct AnimationConfig: Decodable {
    let name: String
    let row: Int
    let frames: Int
}

struct SliceConfig: Decodable {
    let frameSize: Int
    let outputSize: Int
    let animations: [AnimationConfig]
}

// MARK: - Argument Parsing

guard CommandLine.arguments.count == 3 else {
    fputs("Usage: swift slice-sprites.swift <sprite-sheet.png> '<json-config>'\n", stderr)
    exit(1)
}

let sheetPath = CommandLine.arguments[1]
let jsonString = CommandLine.arguments[2]

guard let jsonData = jsonString.data(using: .utf8) else {
    fputs("Error: Could not encode JSON string as UTF-8\n", stderr)
    exit(1)
}

let config: SliceConfig
do {
    config = try JSONDecoder().decode(SliceConfig.self, from: jsonData)
} catch {
    fputs("Error parsing JSON config: \(error)\n", stderr)
    exit(1)
}

// MARK: - Load Sprite Sheet

let sheetURL = URL(fileURLWithPath: sheetPath)
guard let sheetSource = CGImageSourceCreateWithURL(sheetURL as CFURL, nil),
      let sheetImage = CGImageSourceCreateImageAtIndex(sheetSource, 0, nil) else {
    fputs("Error: Could not load sprite sheet from '\(sheetPath)'\n", stderr)
    exit(1)
}

let frameSize = config.frameSize
let outputSize = config.outputSize
let sheetWidth = sheetImage.width
let sheetHeight = sheetImage.height

print("Sheet size: \(sheetWidth)x\(sheetHeight), frameSize: \(frameSize), outputSize: \(outputSize)")

// MARK: - Output Directory

let outputDir = "Sources/ClaudeCodeBuddy/Assets/Sprites"
try? FileManager.default.createDirectory(atPath: outputDir,
                                          withIntermediateDirectories: true)

// MARK: - Slice and Scale

let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)

for anim in config.animations {
    let row = anim.row
    let yOffset = row * frameSize

    for frameIndex in 0..<anim.frames {
        let col = frameIndex
        let xOffset = col * frameSize

        // Validate bounds
        guard xOffset + frameSize <= sheetWidth,
              yOffset + frameSize <= sheetHeight else {
            fputs("Warning: Frame \(frameIndex) of '\(anim.name)' is out of sheet bounds — skipping\n", stderr)
            continue
        }

        // Crop the frame from the sheet
        let cropRect = CGRect(x: xOffset, y: yOffset, width: frameSize, height: frameSize)
        guard let cropped = sheetImage.cropping(to: cropRect) else {
            fputs("Warning: Could not crop frame \(frameIndex) of '\(anim.name)'\n", stderr)
            continue
        }

        // Scale up to outputSize using nearest-neighbor (no interpolation)
        guard let scaledCtx = CGContext(
            data: nil,
            width: outputSize,
            height: outputSize,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo.rawValue
        ) else {
            fputs("Error: Could not create CGContext for '\(anim.name)' frame \(frameIndex)\n", stderr)
            continue
        }

        scaledCtx.interpolationQuality = .none
        scaledCtx.draw(cropped, in: CGRect(x: 0, y: 0, width: outputSize, height: outputSize))

        guard let scaledImage = scaledCtx.makeImage() else {
            fputs("Error: Could not create scaled image for '\(anim.name)' frame \(frameIndex)\n", stderr)
            continue
        }

        // Save PNG — frame is 1-indexed
        let frameNumber = frameIndex + 1
        let outPath = "\(outputDir)/cat-\(anim.name)-\(frameNumber).png"
        let outURL = URL(fileURLWithPath: outPath)

        guard let dest = CGImageDestinationCreateWithURL(outURL as CFURL, "public.png" as CFString, 1, nil) else {
            fputs("Error: Could not create image destination for '\(outPath)'\n", stderr)
            continue
        }

        CGImageDestinationAddImage(dest, scaledImage, nil)

        if CGImageDestinationFinalize(dest) {
            print("Wrote \(outPath)")
        } else {
            fputs("Error: Failed to write '\(outPath)'\n", stderr)
        }
    }
}

print("Done.")
