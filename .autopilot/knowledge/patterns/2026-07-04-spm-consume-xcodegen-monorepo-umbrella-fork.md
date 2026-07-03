# 消费三方 XcodeGen monorepo SPM 包：fork + root umbrella Package.swift（path: 互引收敛）

<!-- tags: spm, third-party-dependency, xcodegen, monorepo, umbrella-package, fork, package-swift, dependency-consumption, reusable-pattern, dry-run -->

**Scenario**: 想把一个三方 Swift 仓库作为远程 SPM 依赖（`.package(url:...)`）接进自己的纯 SPM app，但该仓库是 XcodeGen 工程：仓库根**没有 `Package.swift`**，子包之间全用 `.package(path: "../SiblingKit")` 互引。SPM 无法远程消费这种结构——远程包不允许 `path:` 依赖，且根无 manifest 则无 products 可引。dry-run clone 后 `swift package resolve` 直接报错。

**Lesson**: 不要 vendor-copy 源码、也不要等上游重构。**fork 该仓库 + 加一个 root umbrella `Package.swift`**：把子包间的 `path:` 互引收敛成**包内 target 依赖**（`.target(name: "CaptureKit", dependencies: [.target(name: "SharedKit")])`），用 `.product` 暴露要消费的子包。fork 保留与上游 rebase 同步能力，umbrella manifest 是纯增量文件不动子包源码。这是任何「根无 Package.swift / path: 互引 / 想远程消费」三方 Swift 依赖的通用解，也是项目后续接更多三方 SPM 依赖的可复用范式。dry-run 必须验证三件事：① 远程 clone 后 `swift build` 通过 ② 子包 `path:` 互引已全部改包内 target 依赖（grep 残留 `path:`） ③ products 名字与消费方 `.product(name:...)` 完全一致。

**Evidence**: strzhao/capso-spm slim 包装仓（fork Capso，加 root Package.swift，swift-tools 6.0 / `.macOS(.v14)`，3 target：SharedKit / CaptureKit / AnnotationKit）；a809f89 接入 `.package(url: "https://github.com/strzhao/capso-spm", from: "1.0.0")` + BuddyCore 依赖 `.product(name: "CaptureKit"/"AnnotationKit", package: "capso-spm")`；/tmp/capso-spm-validate dry-run 证明 macOS 14 部署目标下编译通过；user 反馈「后续也会需要涉及到这部分的三方依赖的」确立此范式优先级。（核对锚点：2026-07-04 源码版本）

**关联**: 与 `2026-04-13-spm-bundle-module-app-package-path`、`2026-06-21-spm-bundle-module-crash-custom-replacement` 同属 SPM 主题但正交（那两条是打包/产物路径，本条是远程依赖消费）。
