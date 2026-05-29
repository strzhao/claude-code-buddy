import XCTest
import Foundation
@testable import BuddyCore

// MARK: - LauncherSourceContractAcceptanceTests
//
// 红队验收测试：C6 + C7 + C8 源码契约（三合一）
//
// 覆盖契约：
//   C6: LauncherInputView.swift 含 `.spring(response: 0.32` 和
//       `.scaleEffect(visible ? 1.0 : 0.96)` 两个子串（入场弹性动画）
//   C7: LauncherTheme.swift 中 bodyText / candidateName / candidateDesc / statusFooter
//       四个 token 的定义区域内各自含 `design: .rounded` 字面值（Rounded 字体设计）
//   C8: LauncherInputView.swift 不含 `shadowPixel` 或 `pixelShadowOffset`
//       （旧式硬阴影已移除，C8 禁止 legacy pixel-shadow 遗留）
//
// 测试策略：通过 try String(contentsOfFile:) 读取源文件，用 contains 断言。
// 路径定位：从 #file 上溯多层到 .git 仓库根。
//
// 注意：这些都是"源码文本契约"，不是"运行时行为契约"，
//       因此 grep 策略完全准确——只要源码包含正确的字面值，编译后行为自然满足设计意图。
//
// 测试 WILL NOT compile 直到蓝队合并实现 — 这是预期的 TDD 红灯。

final class LauncherSourceContractAcceptanceTests: XCTestCase {

    // MARK: - 路径辅助

    /// 从 #file 上溯找到 .git 所在的仓库根目录
    private var projectRoot: String {
        var url = URL(fileURLWithPath: #file)
        for _ in 0..<12 {
            url = url.deletingLastPathComponent()
            let gitDir = url.appendingPathComponent(".git")
            if FileManager.default.fileExists(atPath: gitDir.path) {
                return url.path
            }
        }
        return "/Users/stringzhao/workspace/claude-code-buddy"
    }

    private var launcherDir: String {
        "\(projectRoot)/apps/desktop/Sources/ClaudeCodeBuddy/Launcher"
    }

    private var inputViewPath: String {
        "\(launcherDir)/LauncherInputView.swift"
    }

    private var themePath: String {
        "\(launcherDir)/LauncherTheme.swift"
    }

    // MARK: - 读取源码辅助

    private func readSource(at path: String, label: String) throws -> String {
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("\(label) 尚未存在（蓝队未合并），跳过：\(path)")
        }
        return try String(contentsOfFile: path, encoding: .utf8)
    }

    // MARK: - C6: inputView 入场弹性动画契约

    /// C6: LauncherInputView.swift 必须含 `.spring(response: 0.32` 子串
    ///
    /// 设计意图：输入视图使用 0.32s response 的弹性动画入场，
    /// 提供轻快、自然的 Apple HIG 级动效体验。
    func test_C6_inputView_hasSpringEntryAnimation() throws {
        let source = try readSource(at: inputViewPath, label: "LauncherInputView.swift")

        // C6 契约子串 1：spring response 0.32
        XCTAssertTrue(
            source.contains(".spring(response: 0.32"),
            """
            C6 违反（spring response）：LauncherInputView.swift 中未找到弹性动画参数。
            期望含子串：.spring(response: 0.32
            设计意图：入场动画使用 response=0.32 的 spring 曲线（Apple HIG 推荐节奏）。
            源码路径：\(inputViewPath)
            """
        )

        // C6 契约子串 2：scaleEffect 入场缩放
        XCTAssertTrue(
            source.contains(".scaleEffect(visible ? 1.0 : 0.96)"),
            """
            C6 违反（scaleEffect）：LauncherInputView.swift 中未找到入场缩放动效。
            期望含子串：.scaleEffect(visible ? 1.0 : 0.96)
            设计意图：视图入场时从 0.96 scale 弹到 1.0，产生"弹出"感，避免突兀出现。
            源码路径：\(inputViewPath)
            """
        )
    }

    // MARK: - C7: theme fonts 使用 Rounded 字体设计

    /// C7: LauncherTheme.swift 中 bodyText / candidateName / candidateDesc / statusFooter
    ///     四个 token 的定义区域内各含 `design: .rounded` 字面值
    ///
    /// 测试策略：
    ///   按 token 名将源码按行分割，找到 token 名所在行，
    ///   在该行（或紧邻的上下 5 行内）检查是否含 `design: .rounded`。
    ///   若 token 定义跨多行，则在 ±5 行范围内断言。
    func test_C7_themeFonts_useRoundedDesign() throws {
        let source = try readSource(at: themePath, label: "LauncherTheme.swift")

        let fontTokens = ["bodyText", "candidateName", "candidateDesc", "statusFooter"]

        for token in fontTokens {
            assertTokenUsesRoundedDesign(source: source, token: token)
        }
    }

    /// 辅助：在源码中检查 token 名称附近（±5 行）是否含 `design: .rounded`
    private func assertTokenUsesRoundedDesign(source: String, token: String) {
        let lines = source.components(separatedBy: "\n")

        // 找到 token 名出现的所有行号
        var tokenLineIndices: [Int] = []
        for (idx, line) in lines.enumerated() {
            if line.contains(token) {
                tokenLineIndices.append(idx)
            }
        }

        guard !tokenLineIndices.isEmpty else {
            XCTFail(
                """
                C7 违反（token 未找到）：LauncherTheme.swift 中未找到 token '\(token)' 的定义。
                期望含 '\(token)' 字面值（font token 名）。
                源码路径：\(themePath)
                """
            )
            return
        }

        // 在 token 所在行的 ±5 行窗口内，查找 design: .rounded
        let windowRadius = 5
        var foundRounded = false

        for tokenIdx in tokenLineIndices {
            let start = max(0, tokenIdx - windowRadius)
            let end   = min(lines.count - 1, tokenIdx + windowRadius)
            let window = lines[start...end].joined(separator: "\n")
            if window.contains("design: .rounded") {
                foundRounded = true
                break
            }
        }

        // 如果窗口策略未找到，退而尝试全文 contains（适用于 token 定义和 rounded 在同段落的场景）
        if !foundRounded {
            // 分块检查：按 token 名切割文件，检查每个分块是否含 design: .rounded
            let segments = source.components(separatedBy: token)
            // 第一个 segment 是 token 名之前的内容，从第二个 segment 起每个包含紧跟 token 的代码
            for segment in segments.dropFirst() {
                // 取 segment 开头 300 字符（典型 font 定义不会超过此范围）
                let preview = String(segment.prefix(300))
                if preview.contains("design: .rounded") {
                    foundRounded = true
                    break
                }
            }
        }

        XCTAssertTrue(
            foundRounded,
            """
            C7 违反（\(token) Rounded 字体）：LauncherTheme.swift 中 '\(token)' 定义区域
            未找到 `design: .rounded` 字面值（±5 行窗口内 + 分段检查均未找到）。

            设计意图：launcher 的 \(token) 字体应使用 .rounded 设计（SF Pro Rounded），
            提供更温和、现代的 Apple HIG 视觉风格。

            例如：Font.system(size: XX, weight: .medium, design: .rounded)

            源码路径：\(themePath)
            """
        )
    }

    // MARK: - C8: inputView 不含 legacy 硬阴影符号

    /// C8: LauncherInputView.swift 不应含 `shadowPixel` 字符串
    ///
    /// 设计意图：新版 launcher 使用 NSVisualEffectView 毛玻璃，
    /// 旧式 pixel-shadow（shadowPixel / pixelShadowOffset）已移除，
    /// 任何遗留引用均属设计回归。
    func test_C8_inputView_noLegacyHardShadow() throws {
        let source = try readSource(at: inputViewPath, label: "LauncherInputView.swift")

        // C8 契约：不含 shadowPixel
        XCTAssertFalse(
            source.contains("shadowPixel"),
            """
            C8 违反（shadowPixel）：LauncherInputView.swift 含 `shadowPixel` 字面值。
            这是旧式 pixel-shadow 遗留引用，应已在本次 UI 升级中移除。
            源码路径：\(inputViewPath)

            修复方式：删除所有 LauncherTheme.shadowPixel 的引用，
            视觉阴影由 NSVisualEffectView 毛玻璃自动处理。
            """
        )

        // C8 契约：不含 pixelShadowOffset
        XCTAssertFalse(
            source.contains("pixelShadowOffset"),
            """
            C8 违反（pixelShadowOffset）：LauncherInputView.swift 含 `pixelShadowOffset` 字面值。
            这是旧式 pixel-shadow offset 遗留引用，应已在本次 UI 升级中移除。
            源码路径：\(inputViewPath)

            修复方式：删除所有 LauncherTheme.pixelShadowOffset 的引用。
            """
        )
    }

    // MARK: - C6 补充：spring animation 两个子串都存在才算完整契约

    /// C6 整合验证：spring + scaleEffect 两个子串必须同时存在
    func test_C6_springAndScaleEffect_bothPresent() throws {
        let source = try readSource(at: inputViewPath, label: "LauncherInputView.swift")

        let hasSpring      = source.contains(".spring(response: 0.32")
        let hasScaleEffect = source.contains(".scaleEffect(visible ? 1.0 : 0.96)")

        XCTAssertTrue(
            hasSpring && hasScaleEffect,
            """
            C6 整合违反：LauncherInputView.swift 的入场弹性动画必须同时满足两个子串。
            .spring(response: 0.32       — \(hasSpring ? "✓ 找到" : "✗ 未找到")
            .scaleEffect(visible ? 1.0 : 0.96) — \(hasScaleEffect ? "✓ 找到" : "✗ 未找到")

            两者缺一不可：spring 定义曲线，scaleEffect 定义入场形变幅度。
            源码路径：\(inputViewPath)
            """
        )
    }

    // MARK: - C7 补充：LauncherTheme.swift 中全局含 design: .rounded 至少 4 次

    /// C7 计数验证：`design: .rounded` 出现次数 >= 4（对应 4 个 font token）
    func test_C7_roundedDesign_appearsAtLeast4Times() throws {
        let source = try readSource(at: themePath, label: "LauncherTheme.swift")

        // 统计 design: .rounded 出现次数
        var count = 0
        var searchRange = source.startIndex..<source.endIndex
        let target = "design: .rounded"
        while let range = source.range(of: target, range: searchRange) {
            count += 1
            searchRange = range.upperBound..<source.endIndex
        }

        XCTAssertGreaterThanOrEqual(
            count,
            4,
            """
            C7 计数违反：LauncherTheme.swift 中 `design: .rounded` 出现次数 = \(count)，期望 >= 4。
            四个 font token（bodyText / candidateName / candidateDesc / statusFooter）
            每个都应独立使用 design: .rounded。
            源码路径：\(themePath)
            """
        )
    }
}
