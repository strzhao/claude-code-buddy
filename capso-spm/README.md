# capso-spm

SPM-packaged subset of [Capso](https://github.com/lzhgus/Capso) (a native Swift screenshot/screen-recording app by **Awesome Mac Apps**, licensed BSL 1.1).

## What this is

Capso's upstream repo is an XcodeGen project (`project.yml`) with 12 SPM sub-packages under `Packages/` that reference each other via local `path:` dependencies — it has **no root `Package.swift`**, so it cannot be consumed as a remote SPM dependency directly.

This repo re-packages the **three headless kits** needed for screenshot capture + annotation, as a single multi-target SPM package consumable via `.package(url:)`:

- **SharedKit** — shared utilities (geometry, permissions, image helpers)
- **CaptureKit** — `ScreenCaptureManager` (wraps `SCScreenshotManager`, macOS 14+) + selection geometry/hit-testing
- **AnnotationKit** — `AnnotationObject` model + 8 object types (Freehand/Rectangle/Pixelate/Ellipse/Counter/Line/Arrow/Text) + `AnnotationRenderer` (pure function: CGImage + objects → composited CGImage)

The other 9 kits (CameraKit/EditorKit/EffectsKit/ExportKit/HistoryKit/OCRKit/RecordingKit/ShareKit/TranslationKit) and CaptureKit's Scrolling sub-module are **omitted** (not needed for screenshot annotation; avoids pulling GRDB/Soto/Vision).

## Attribution & License

All source in `Sources/` is **verbatim from [lzhgus/Capso](https://github.com/lzhgus/Capso)**. Copyright and all rights remain with the original authors (**Awesome Mac Apps**).

Licensed under the **Business Source License 1.1** ([LICENSE](LICENSE)).

- **Additional Use Grant**: You may use this freely provided you do not use it for a "Screen Capture Service" (a commercial product whose primary purpose is screenshot/screen-recording). A tool that *happens to include* screenshot functionality (e.g. a Claude Code companion app) is explicitly allowed.
- **Change Date**: 2029-04-08 — on this date the license converts to Apache 2.0.

Upstream sync: re-vendor the three kits' `Sources/` from Capso `main` via sparse-checkout + rsync (upstream has no subtree split).

## Usage

```swift
.package(url: "https://github.com/strzhao/capso-spm", from: "1.0.0")

// target dependency:
.product(name: "CaptureKit", package: "capso-spm"),
.product(name: "AnnotationKit", package: "capso-spm"),
```

Requires macOS 14+. Swift 6 language mode (consumable from Swift 5 apps — the dependency compiles in its own mode).
