# CoreImage CIFilter.qrCodeGenerator + swiftc/lipo universal binary 作为 marketplace 插件可执行文件

<!-- tags: coreimage, qr-code, cifilter, universal-binary, lipo, swiftc, command-mode, marketplace-plugin, png, appkit, nsbitmapimagerep -->
**Scenario**: qr 插件需要「输入文本 → 生成可扫码 PNG」能力。Launcher 框架是 Swift AppKit app，但插件可执行文件是独立子进程，不能用框架内的 CoreImage 调用。需要把 CoreImage 生成逻辑编译成独立 universal binary 随插件分发，在 Intel + Apple Silicon 上都能跑。

**Lesson**: CoreImage QR 生成链路：`CIFilter.qrCodeGenerator()`（设 message + correctionLevel M/H）→ `outputImage`（默认 extent ~23px module）→ `.transformed(by: CGAffineTransform(scaleX:y:))` 放大到 ≥480px 保证扫码 → `CIContext().createCGImage` → `NSBitmapImageRep(cgImage:)` → `.representation(using: .png, properties: [:])` → 写文件。必须放大，CoreImage 默认 module 太小（~23px）扫不出。

**Universal binary 构建（Makefile）**：插件可执行文件不能用 `swift build`（那是编译 framework target），必须用裸 `swiftc` 双架构编译 + `lipo` 合并：
```makefile
build-qr-gen:
	@build_dir=$$(mktemp -d); \
	swiftc -target arm64-apple-macosx14 -O -o $$build_dir/arm64 src.swift -framework AppKit -framework CoreImage; \
	swiftc -target x86_64-apple-macosx14 -O -o $$build_dir/x86_64 src.swift -framework AppKit -framework CoreImage; \
	lipo -create -output plugins/qr/qr-gen $$build_dir/arm64 $$build_dir/x86_64; \
	chmod 755 plugins/qr/qr-gen; rm -rf $$build_dir
```
**时序关键**：`build:` 目标必须依赖 `build-qr-gen` 且在其后跑 `swift build`——SPM `.copy("Marketplace")` 在 swift build 时拷资源，此时二进制必须已在位，否则 bundle 里 qr-gen 缺失。

**框架注入图片路径**：子进程不自己决定输出路径，框架 `StdinExecutor` 注入环境变量 `BUDDY_OUTPUT_IMAGE=/tmp/buddy-plugin-<uuid>.png`，子进程写该路径，框架读文件成 `Data` 填 `PluginResult.image`。stdout 保持纯文本不被污染。

**Evidence**: `.autopilot/runtime/sessions/qrcode`；Makefile build-qr-gen 目标；Sources/ClaudeCodeBuddy/Marketplace/plugins/qr/qr-gen.swift（CIFilter + NSBitmapImageRep PNG + 放大 480px）；端到端冒烟：universal binary 解码 payload == "https://github.com"，空输入 exit 1。
