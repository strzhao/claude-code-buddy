import XCTest
import Foundation
@testable import BuddyCore

// MARK: - LauncherCodeContractAcceptanceTests
//
// 红队验收测试：C6 + S3 + S4 代码层契约（通过 Process 运行 shell 命令验证源码）
//
// 覆盖契约：
//   C6/S3: Launcher 源码（排除 LauncherTheme.swift）中无硬编码 hex 颜色构造
//          git grep -E "Color\(red:|NSColor\(red:|0x[0-9a-fA-F]{6}|#[0-9a-fA-F]{6}"
//          排除 LauncherTheme.swift 和单行注释中的解释性 hex
//   S4:    Launcher 源码中无 .regularMaterial / .thinMaterial 等 material 背景
//   S5:    快照基线文件存在且非零字节（6 张以上）
//
// 技术说明：
//   使用 Process + Pipe 在测试进程内运行 shell 命令，避免依赖外部脚本。
//   工作目录锚定到项目根，grep 路径相对于根目录。
//
// 测试 WILL NOT compile 直到蓝队合并实现 — 这是预期的 TDD 红灯。
// 注意：C6/S3/S4 是代码内容契约，与实现无关（源文件本身就是被测对象）。

final class LauncherCodeContractAcceptanceTests: XCTestCase {

    // MARK: - 辅助方法

    /// 运行 shell 命令，返回 (stdout, exitCode)
    private func run(command: String, workingDirectory: String? = nil) -> (output: String, exitCode: Int32) {
        let process = Process()
        let pipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", command]
        process.standardOutput = pipe
        process.standardError = pipe

        if let dir = workingDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: dir)
        }

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return ("Error running process: \(error)", -1)
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        return (output, process.terminationStatus)
    }

    /// 项目根目录（从 Bundle 路径推断）
    private var projectRoot: String {
        // 测试 Bundle 位于 apps/desktop/.build/... 下，上溯到项目根
        // 用 .git 目录作为仓库根标识（CLAUDE.md 在 apps/desktop 也存在，会误判）
        let bundlePath = Bundle(for: type(of: self)).bundlePath
        var url = URL(fileURLWithPath: bundlePath)
        for _ in 0..<12 {
            url = url.deletingLastPathComponent()
            let gitDir = url.appendingPathComponent(".git")
            if FileManager.default.fileExists(atPath: gitDir.path) {
                return url.path
            }
        }
        // fallback：hardcode 已知路径
        return "/Users/stringzhao/workspace/claude-code-buddy"
    }

    // MARK: - C6/S3: 无硬编码 hex 颜色（排除 LauncherTheme.swift）

    /// Launcher 源码（除 LauncherTheme.swift 外）不应含 Color(red:) / NSColor(red:) / 0xHHHHHH / #HHHHHH
    /// 即：所有颜色构造必须通过 LauncherTheme.* 访问，不直接写字面值
    func test_C6_S3_noHardcodedColorInLauncherSources() {
        let launcherDir = "\(projectRoot)/apps/desktop/Sources/ClaudeCodeBuddy/Launcher"

        // 跟设计文档 C6 完全一致的 grep 命令
        let grepCmd = """
        git -C "\(projectRoot)" grep -n -E \
          "Color\\(red:|NSColor\\(red:|0x[0-9a-fA-F]{6}|#[0-9a-fA-F]{6}" \
          apps/desktop/Sources/ClaudeCodeBuddy/Launcher/ \
          | grep -v LauncherTheme.swift \
          | grep -v '//.*#[0-9a-fA-F]\\{6\\}'
        """

        let (output, _) = run(command: grepCmd, workingDirectory: projectRoot)
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)

        XCTAssertTrue(
            trimmed.isEmpty,
            """
            C6 违反：Launcher 源码（排除 LauncherTheme.swift）含硬编码颜色构造。
            违规行：
            \(trimmed)

            所有颜色必须通过 LauncherTheme.* dynamic Color 访问，不允许直接写 hex/rgb 字面值。
            路径检查：\(launcherDir)
            """
        )
    }

    // MARK: - S4: 无 .regularMaterial / .thinMaterial 在 Launcher 路径

    /// Launcher 源码不应包含任何 material 背景（.regularMaterial / .thinMaterial 等）
    /// 设计文档：移除毛玻璃效果，统一使用 LauncherTheme.canvas 纯色背景
    func test_S4_noMaterialBackground_inLauncherSources() {
        let grepCmd = """
        git -C "\(projectRoot)" grep -n \
          -E "\\.(regularMaterial|thinMaterial|ultraThinMaterial|thickMaterial|ultraThickMaterial)" \
          apps/desktop/Sources/ClaudeCodeBuddy/Launcher/
        """

        let (output, _) = run(command: grepCmd, workingDirectory: projectRoot)
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)

        XCTAssertTrue(
            trimmed.isEmpty,
            """
            S4 违反：Launcher 源码含 material 背景（应已全部移除，改用 LauncherTheme.canvas）。
            违规行：
            \(trimmed)

            设计契约：移除 .regularMaterial 毛玻璃，使用 LauncherTheme.canvas dynamic Color 替代。
            """
        )
    }

    // MARK: - S5: 快照基线文件存在且非零字节

    /// 快照目录下应有 ≥ 6 张 .png 基线文件，且每张 > 0 字节
    func test_S5_snapshotBaselines_existAndNonEmpty() {
        let snapshotRoot = "\(projectRoot)/apps/desktop/tests/BuddyCoreTests/Launcher/__Snapshots__"

        let lsCmd = "find \"\(snapshotRoot)\" -name '*.png' -type f"
        let (output, _) = run(command: lsCmd)
        let lines = output.split(separator: "\n").map(String.init).filter { !$0.isEmpty }

        XCTAssertGreaterThanOrEqual(
            lines.count,
            6,
            "快照基线文件应 ≥ 6 张（LauncherWindowSnapshotTests + LauncherCandidateViewSnapshotTests），实际 \(lines.count) 张"
        )

        // 验证每张文件非零字节
        let fm = FileManager.default
        for path in lines {
            guard let attrs = try? fm.attributesOfItem(atPath: path),
                  let size = attrs[.size] as? Int else {
                XCTFail("无法读取快照文件属性：\(path)")
                continue
            }
            XCTAssertGreaterThan(
                size,
                0,
                "快照文件不应为空字节：\(path)（size=\(size)）"
            )
        }
    }

    // MARK: - 补充：LauncherTheme.swift 必须存在

    /// LauncherTheme.swift 源文件必须存在于 Launcher 目录（蓝队任务 1 产物）
    func test_launcherTheme_sourceFileExists() {
        let themePath = "\(projectRoot)/apps/desktop/Sources/ClaudeCodeBuddy/Launcher/LauncherTheme.swift"
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: themePath),
            "LauncherTheme.swift 必须存在：\(themePath)"
        )
    }

    // MARK: - 补充：windowWidth 更新到 720（源码层 grep 验证）

    /// LauncherConstants.swift 中 windowWidth 值应 grep 到 720
    func test_launcherConstants_windowWidth_sourceGreps720() {
        let grepCmd = """
        git -C "\(projectRoot)" grep -n "windowWidth.*720" \
          apps/desktop/Sources/ClaudeCodeBuddy/Launcher/LauncherConstants.swift
        """
        let (output, _) = run(command: grepCmd, workingDirectory: projectRoot)
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)

        XCTAssertFalse(
            trimmed.isEmpty,
            """
            LauncherConstants.swift 中未找到 windowWidth == 720 的声明。
            请确认 windowWidth 已从 600 更新到 720（C2 契约）。
            """
        )
    }

    // MARK: - 补充：candidateRowHeight 出现在 LauncherConstants.swift（新增常量验证）

    /// LauncherConstants.swift 中应新增 candidateRowHeight 常量
    func test_launcherConstants_candidateRowHeight_exists_inSource() {
        let grepCmd = """
        git -C "\(projectRoot)" grep -n "candidateRowHeight" \
          apps/desktop/Sources/ClaudeCodeBuddy/Launcher/LauncherConstants.swift
        """
        let (output, _) = run(command: grepCmd, workingDirectory: projectRoot)
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)

        XCTAssertFalse(
            trimmed.isEmpty,
            "LauncherConstants.swift 中应新增 candidateRowHeight 常量（C2 契约，蓝队任务 2 产物）"
        )
    }
}
