# SPM library target 的 Bundle.module 在 .app 打包中的正确路径

<!-- tags: spm, bundle, resource, packaging, crash -->
**Scenario**: Swift Package 的 library target（BuddyCore）声明了 `.copy("Assets")` 资源，executable target 依赖该 library。`swift build` 生成 `ClaudeCodeBuddy_BuddyCore.bundle`，但打包脚本未将其放入 .app 导致启动 crash。
**Lesson**: SPM 生成的 `resource_bundle_accessor.swift` 查找路径为 `Bundle.main.bundleURL.appendingPathComponent("ClaudeCodeBuddy_BuddyCore.bundle")`。对 macOS .app 而言，`Bundle.main.bundleURL` 指向 `.app` 根目录，因此资源 bundle 必须复制到 `.app/` 根目录下（与 `Contents/` 同级）。不要将原始 Assets 目录复制到 `Contents/Resources/`——那不是 Bundle.module 的查找路径。
**Evidence**: Scripts/bundle.sh 修复 commit 5898989; .build/release/BuddyCore.build/DerivedSources/resource_bundle_accessor.swift
