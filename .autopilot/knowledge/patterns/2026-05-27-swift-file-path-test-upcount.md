---
name: swift-file-path-test-upcount
description: Swift 测试用 #file/#filePath 上溯到项目根的 deletingLastPathComponent 次数必须等于测试文件实际嵌套深度，少一层会导致路径错误而被 XCTSkip 掩盖（非测试失败）
metadata:
  type: feedback
---

# Swift 测试 #file 上溯目录层数必须等于实际目录嵌套深度

<!-- tags: swift, swift-testing, xctest, file-path, source-location, deletinglastpathcomponent, test-skip, xctskip, source-scan, spm, package-layout -->

## 上下文

Swift 测试中常用 `#file` 或 `#filePath` 获得测试源文件路径，再上溯多层得到项目根目录，进而扫描源码做静态契约断言（grep forbidden symbol、读源文件等）。

```swift
let thisFile = URL(fileURLWithPath: #file)
let projectRoot = thisFile
    .deletingLastPathComponent()  // <file>
    .deletingLastPathComponent()  // Launcher/
    .deletingLastPathComponent()  // BuddyCoreTests/
    // ❌ 少一层
let sourceDir = projectRoot.appendingPathComponent("Sources/...")
```

## 陷阱

`URL.deletingLastPathComponent` 的语义是"去掉最右一个非空 path component"。从 `.../apps/desktop/tests/BuddyCoreTests/Launcher/MyTest.swift` 出发：

| 调用次数 | 结果 |
|---|---|
| 0 | `.../Launcher/MyTest.swift` |
| 1 | `.../Launcher/` |
| 2 | `.../BuddyCoreTests/` |
| 3 | `.../tests/` |
| 4 | `.../apps/desktop/` ← 项目根 |

少 1 层 → `projectRoot` 实际是 `.../tests/`，再 `appendingPathComponent("Sources/...")` 得到 `.../tests/Sources/...`，**该路径不存在**。

若用 XCTSkip 兜底（`throw XCTSkip("源码目录不存在")`），测试就静默被跳过，**红队/蓝队测试看起来 PASS 但实际没做任何断言**，CI 不报错。事故案例：task 007 红队 4 测试中 2 个被 XCTSkip 掩盖，直到 `--filter` 跑出看见 "with 2 tests skipped" 才发现。

## 修复

1. **数目录层数时画一遍实际路径**：每次 `deletingLastPathComponent` 等于路径中向左移动一段（即 `/` 数）。从测试文件到 SPM 项目根（含 `Package.swift` 的目录）的 `/` 数即为正确层数。
2. **不要用 XCTSkip 兜底"目录不存在"** — 这会掩盖路径解析 bug。改为 `XCTFail` 或 `XCTAssertTrue(exists)`，让路径错误立即失败。
3. **跑 `swift test --filter` 后人工检查 skipped 计数**：`Executed N tests, with K tests skipped` 中 K>0 时必须确认 K 是有意 skip（如沙盒环境）而非 bug。

```swift
// ✅ 正确：从 tests/BuddyCoreTests/Launcher/ 上溯 4 层到 apps/desktop/
let projectRoot = URL(fileURLWithPath: #file)
    .deletingLastPathComponent()  // Launcher/
    .deletingLastPathComponent()  // BuddyCoreTests/
    .deletingLastPathComponent()  // tests/
    .deletingLastPathComponent()  // apps/desktop/
let sourceDir = projectRoot.appendingPathComponent("Sources/ClaudeCodeBuddy/Launcher")
guard FileManager.default.fileExists(atPath: sourceDir.path) else {
    XCTFail("Sources 目录解析错误：\(sourceDir.path)（检查 #file 上溯层数）")
    return
}
```

## Why

- **失败但静默** 比 **失败但响亮** 危险得多。XCTSkip 让源码扫描测试"形似通过"，红队断言完全没运行
- Swift SPM 项目目录结构通常深 4-5 层，开发者凭直觉数 3 层很容易错
- `#file` 和 `#filePath` 编译期展开为绝对路径，开发机和 CI 行为一致，所以错了就是真的错（不会"另一台机器上能跑"）

## How to apply

- 任何使用 `#file`/`#filePath` + 多层 `deletingLastPathComponent` 的测试，先 `print(projectRoot.path)` 一遍肉眼验证
- review 时把"deletingLastPathComponent 注释逐层路径"作为硬要求
- XCTSkip 仅用于运行时合法降级（沙盒、CI 无 NSApp），不用于"路径找不到"
- 测试输出末尾 `with K tests skipped` K>0 必须解释，不允许默认接受

## 关联

- [[plugin-manifest-security-validation]] 类似的 path 校验场景
- task 007 设计文档蓝队 4 层正确，红队 3 层错误（同一设计目标两次实现，蓝队对了红队错了，证明"红蓝对抗"对 path 算数也有抓 bug 的价值）
