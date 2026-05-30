import XCTest
import Foundation
@testable import BuddyCore

// MARK: - LauncherPlaceholderAcceptanceTests
//
// 红队验收测试：C4 Placeholder 文案契约
//
// 覆盖契约：
//   C4: LauncherInputView 中 TextField 的 placeholder 文字必须等于
//       "搜索插件、运行命令、或直接提问…"，末尾必须是 U+2026 `…` 单字符
//       （不是 ASCII `...` 三个点）。
//
// 测试策略（源码 grep）：
//   由于 SwiftUI TextField placeholder 不可直接 inspect，
//   通过读取 LauncherInputView.swift 源码内容，断言含正确字面值字符串。
//   同时验证末尾字符的 Unicode scalar 值 == 0x2026（U+HORIZONTAL ELLIPSIS）。
//
// 路径定位：从 #file 上溯多层到项目根，构造绝对路径。
//
// 测试 WILL NOT compile 直到蓝队合并实现 — 这是预期的 TDD 红灯。

final class LauncherPlaceholderAcceptanceTests: XCTestCase {

    // MARK: - 项目根路径辅助

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
        // fallback
        return "/Users/stringzhao/workspace/claude-code-buddy"
    }

    /// LauncherInputView.swift 的绝对路径
    private var inputViewSourcePath: String {
        "\(projectRoot)/apps/desktop/Sources/ClaudeCodeBuddy/Launcher/LauncherInputView.swift"
    }

    // MARK: - 读取源码辅助

    private func readInputViewSource() throws -> String {
        let path = inputViewSourcePath
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("LauncherInputView.swift 尚未存在（蓝队未合并），跳过 C4 测试: \(path)")
        }
        return try String(contentsOfFile: path, encoding: .utf8)
    }

    // MARK: - C4: placeholder 文案契约（完整字符串匹配）

    /// placeholder 字面值必须完整出现在 LauncherInputView.swift 中
    ///
    /// 设计意图：TextField 的提示文字是用户引导，必须准确使用设计规范中的文案。
    func test_C4_inputView_placeholder_matchesContract() throws {
        let source = try readInputViewSource()

        let expectedPlaceholder = "搜索插件、运行命令、或直接提问…"

        XCTAssertTrue(
            source.contains(expectedPlaceholder),
            """
            C4 违反：LauncherInputView.swift 中未找到 placeholder 文案。
            期望包含：\(expectedPlaceholder)
            源码路径：\(inputViewSourcePath)

            请确认 SwiftUI TextField 的 placeholder 参数使用了完整的文案字符串，
            末尾为 U+2026 省略号（…），而非 ASCII 三点号（...）。
            """
        )
    }

    /// placeholder 末尾字符必须是 U+2026（HORIZONTAL ELLIPSIS 单字符），不是 ASCII `...`
    ///
    /// 设计意图：中文 UI 应使用 Unicode 省略号（U+2026）而非三个英文句点的拼接，
    /// 这是中文排版的标准做法，且 U+2026 是单个 Unicode scalar，不可与 `...` 混淆。
    func test_C4_inputView_placeholder_endsWithU2026() throws {
        let source = try readInputViewSource()

        // 1. 验证 U+2026 字符本身出现在 placeholder 行
        let ellipsisChar: Character = "…"  // U+2026
        let ellipsisScalar: Unicode.Scalar = "…"  // U+2026 == 0x2026

        // 确认编译期 scalar 值
        XCTAssertEqual(
            ellipsisScalar.value,
            0x2026,
            "测试辅助自检：U+2026 HORIZONTAL ELLIPSIS scalar 值应 == 0x2026"
        )

        // 2. 在源码中寻找含 U+2026 的 placeholder 字面值
        let targetWithEllipsis = "搜索插件、运行命令、或直接提问…"

        XCTAssertTrue(
            source.contains(targetWithEllipsis),
            """
            C4 违反（U+2026 末尾字符）：LauncherInputView.swift 中未找到以 U+2026 结尾的 placeholder。
            期望找到：\(targetWithEllipsis)（末尾为 U+2026 HORIZONTAL ELLIPSIS）
            源码路径：\(inputViewSourcePath)
            """
        )

        // 3. 断言源码中不存在 ASCII 三点 "..." 版本的 placeholder（禁止错用）
        let wrongPlaceholder = "搜索插件、运行命令、或直接提问..."  // ASCII 三个点

        XCTAssertFalse(
            source.contains(wrongPlaceholder),
            """
            C4 违反（ASCII 三点）：LauncherInputView.swift 使用了 ASCII `...` 而非 U+2026 `…`。
            不允许出现：\(wrongPlaceholder)
            应替换为：\(targetWithEllipsis)（U+2026）
            源码路径：\(inputViewSourcePath)
            """
        )

        // 4. 验证目标字符串的末尾字符确实是 U+2026（防御性自检）
        let lastChar = targetWithEllipsis.unicodeScalars.last
        XCTAssertEqual(
            lastChar?.value,
            0x2026,
            """
            测试辅助自检：目标 placeholder 字符串末尾 Unicode scalar 应 == 0x2026。
            实际：\(lastChar.map { String($0.value, radix: 16) } ?? "nil")
            """
        )
    }

    // MARK: - C4 补充：LauncherInputView.swift 源文件必须存在

    /// LauncherInputView.swift 必须存在（蓝队工作面文件）
    func test_C4_inputViewSourceFile_exists() {
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: inputViewSourcePath),
            "LauncherInputView.swift 必须存在：\(inputViewSourcePath)"
        )
    }

    // MARK: - C4 补充：placeholder 出现在 TextField(...) 调用中

    /// placeholder 必须出现在 TextField("...") 的直接参数位置（而非普通注释或变量名）
    func test_C4_placeholder_appearsInTextFieldCall() throws {
        let source = try readInputViewSource()

        // 最常见的两种 SwiftUI TextField placeholder 写法
        let pattern1 = "TextField(\"搜索插件、运行命令、或直接提问…\""
        let pattern2 = "TextField(\"搜索插件、运行命令、或直接提问…\","

        let foundInCall = source.contains(pattern1) || source.contains(pattern2)

        XCTAssertTrue(
            foundInCall,
            """
            C4 补充：placeholder 文案未出现在 TextField(...) 调用参数位置。
            期望找到以下任一模式：
              \(pattern1)
              \(pattern2)
            源码路径：\(inputViewSourcePath)

            placeholder 必须直接作为 TextField 的 title 参数传入，
            不能是分开定义的常量（除非常量值本身满足文案契约）。
            """
        )
    }
}
