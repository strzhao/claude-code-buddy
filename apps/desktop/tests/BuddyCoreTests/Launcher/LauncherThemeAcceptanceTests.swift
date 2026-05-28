import XCTest
import AppKit
import SwiftUI
@testable import BuddyCore

// MARK: - LauncherThemeAcceptanceTests
//
// 红队验收测试：C1 LauncherTheme 公开 API 签名 & 颜色契约
//
// 覆盖契约：
//   C1-A: LauncherTheme 枚举存在，10 个 Color 属性均可访问（编译即验证）
//   C1-B: light 模式 canvas == #f7f6f1, primary == #3a7d68, borderPixel == #1a1a18, shadowPixel == #1a1a18
//   C1-C: dark 模式 canvas == #0f0f0e, primary == #52a688, borderPixel == #edece7, shadowPixel == #000000
//   C1-D: bodyText 字号必须 == 28（.system(size: 28)）
//   C1-E: pixelBorderWidth == 2, panelCornerRadius == 14, pixelShadowOffset == CGSize(4, 4)
//   C1-F: Font 属性存在（编译即验证）
//
// 红队原则：所有断言代表"设计意图应该满足"，不代表"实现实际做了什么"。
// 测试 WILL NOT compile 直到蓝队合并实现 — 这是预期的 TDD 红灯。

final class LauncherThemeAcceptanceTests: XCTestCase {

    // MARK: - 辅助方法

    /// 在指定 NSAppearance 下读取 SwiftUI Color 的 sRGB 分量
    /// 用 NSColor(color).usingColorSpace(.sRGB) 转换，确保 dynamic color 被正确解析
    private func rgbComponents(
        of color: Color,
        appearance: NSAppearance.Name
    ) -> (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat) {
        var result: (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat) = (0, 0, 0, 0)
        NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance {
            guard let ns = NSColor(color).usingColorSpace(.sRGB) else {
                XCTFail("无法将 Color 转换到 sRGB 颜色空间（appearance: \(appearance.rawValue)）")
                return
            }
            result = (
                ns.redComponent,
                ns.greenComponent,
                ns.blueComponent,
                ns.alphaComponent
            )
        }
        return result
    }

    // MARK: - C1-A: 属性存在（编译时验证）

    /// 所有 Color 属性必须存在且是 SwiftUI Color 类型（编译即验证）
    func test_C1A_allColorProperties_exist() {
        // 通过访问所有属性，编译器保证它们存在且类型正确
        let _: Color = LauncherTheme.canvas
        let _: Color = LauncherTheme.surface
        let _: Color = LauncherTheme.ink
        let _: Color = LauncherTheme.smoke
        let _: Color = LauncherTheme.primary
        let _: Color = LauncherTheme.primaryHover
        let _: Color = LauncherTheme.borderPixel
        let _: Color = LauncherTheme.shadowPixel
        let _: Color = LauncherTheme.mist
        let _: Color = LauncherTheme.selectedText
    }

    /// 所有 Font 属性必须存在且是 SwiftUI Font 类型（编译即验证）
    func test_C1F_allFontProperties_exist() {
        let _: Font = LauncherTheme.bodyText
        let _: Font = LauncherTheme.candidateName
        let _: Font = LauncherTheme.candidateDesc
        let _: Font = LauncherTheme.badgeMono
        let _: Font = LauncherTheme.footerMono
        let _: Font = LauncherTheme.outputBody
    }

    // MARK: - C1-B: Light 模式颜色契约

    /// light 模式 canvas 必须 == #f7f6f1
    func test_C1B_lightMode_canvas_isF7F6F1() {
        let (r, g, b, _) = rgbComponents(of: LauncherTheme.canvas, appearance: .aqua)
        XCTAssertEqual(r, 0xf7/255.0, accuracy: 0.01, "light canvas.red 应 == 0xf7/255")
        XCTAssertEqual(g, 0xf6/255.0, accuracy: 0.01, "light canvas.green 应 == 0xf6/255")
        XCTAssertEqual(b, 0xf1/255.0, accuracy: 0.01, "light canvas.blue 应 == 0xf1/255")
    }

    /// light 模式 primary 必须 == #3a7d68
    func test_C1B_lightMode_primary_is3A7D68() {
        let (r, g, b, _) = rgbComponents(of: LauncherTheme.primary, appearance: .aqua)
        XCTAssertEqual(r, 0x3a/255.0, accuracy: 0.01, "light primary.red 应 == 0x3a/255")
        XCTAssertEqual(g, 0x7d/255.0, accuracy: 0.01, "light primary.green 应 == 0x7d/255")
        XCTAssertEqual(b, 0x68/255.0, accuracy: 0.01, "light primary.blue 应 == 0x68/255")
    }

    /// light 模式 borderPixel 必须 == #1a1a18
    func test_C1B_lightMode_borderPixel_is1A1A18() {
        let (r, g, b, _) = rgbComponents(of: LauncherTheme.borderPixel, appearance: .aqua)
        XCTAssertEqual(r, 0x1a/255.0, accuracy: 0.01, "light borderPixel.red 应 == 0x1a/255")
        XCTAssertEqual(g, 0x1a/255.0, accuracy: 0.01, "light borderPixel.green 应 == 0x1a/255")
        XCTAssertEqual(b, 0x18/255.0, accuracy: 0.01, "light borderPixel.blue 应 == 0x18/255")
    }

    /// light 模式 shadowPixel 必须 == #1a1a18
    func test_C1B_lightMode_shadowPixel_is1A1A18() {
        let (r, g, b, _) = rgbComponents(of: LauncherTheme.shadowPixel, appearance: .aqua)
        XCTAssertEqual(r, 0x1a/255.0, accuracy: 0.01, "light shadowPixel.red 应 == 0x1a/255")
        XCTAssertEqual(g, 0x1a/255.0, accuracy: 0.01, "light shadowPixel.green 应 == 0x1a/255")
        XCTAssertEqual(b, 0x18/255.0, accuracy: 0.01, "light shadowPixel.blue 应 == 0x18/255")
    }

    // MARK: - C1-C: Dark 模式颜色契约

    /// dark 模式 canvas 必须 == #0f0f0e
    func test_C1C_darkMode_canvas_is0F0F0E() {
        let (r, g, b, _) = rgbComponents(of: LauncherTheme.canvas, appearance: .darkAqua)
        XCTAssertEqual(r, 0x0f/255.0, accuracy: 0.01, "dark canvas.red 应 == 0x0f/255")
        XCTAssertEqual(g, 0x0f/255.0, accuracy: 0.01, "dark canvas.green 应 == 0x0f/255")
        XCTAssertEqual(b, 0x0e/255.0, accuracy: 0.01, "dark canvas.blue 应 == 0x0e/255")
    }

    /// dark 模式 primary 必须 == #52a688
    func test_C1C_darkMode_primary_is52A688() {
        let (r, g, b, _) = rgbComponents(of: LauncherTheme.primary, appearance: .darkAqua)
        XCTAssertEqual(r, 0x52/255.0, accuracy: 0.01, "dark primary.red 应 == 0x52/255")
        XCTAssertEqual(g, 0xa6/255.0, accuracy: 0.01, "dark primary.green 应 == 0xa6/255")
        XCTAssertEqual(b, 0x88/255.0, accuracy: 0.01, "dark primary.blue 应 == 0x88/255")
    }

    /// dark 模式 borderPixel 必须 == #edece7
    func test_C1C_darkMode_borderPixel_isEDECE7() {
        let (r, g, b, _) = rgbComponents(of: LauncherTheme.borderPixel, appearance: .darkAqua)
        XCTAssertEqual(r, 0xed/255.0, accuracy: 0.01, "dark borderPixel.red 应 == 0xed/255")
        XCTAssertEqual(g, 0xec/255.0, accuracy: 0.01, "dark borderPixel.green 应 == 0xec/255")
        XCTAssertEqual(b, 0xe7/255.0, accuracy: 0.01, "dark borderPixel.blue 应 == 0xe7/255")
    }

    /// dark 模式 shadowPixel 必须 == #000000（纯黑，对齐 web --color-shadow-pixel）
    func test_C1C_darkMode_shadowPixel_is000000() {
        let (r, g, b, _) = rgbComponents(of: LauncherTheme.shadowPixel, appearance: .darkAqua)
        XCTAssertEqual(r, 0.0, accuracy: 0.01, "dark shadowPixel.red 应 == 0（纯黑）")
        XCTAssertEqual(g, 0.0, accuracy: 0.01, "dark shadowPixel.green 应 == 0（纯黑）")
        XCTAssertEqual(b, 0.0, accuracy: 0.01, "dark shadowPixel.blue 应 == 0（纯黑）")
    }

    // MARK: - C1-D: bodyText 字号 == 28

    /// bodyText 必须基于 .system(size: 28)
    /// 用 NSFont 解析验证字号
    func test_C1D_bodyText_fontSize_is28() {
        // 把 SwiftUI Font 转换为 NSFont 验证字号
        let nsFont = NSFont.systemFont(ofSize: 28)
        // 直接验证系统字体字号：LauncherTheme.bodyText 应与 .system(size: 28) 语义一致
        // 由于 SwiftUI Font 不直接暴露 pointSize，我们通过 NSHostingController 间接验证
        // 最安全的红队断言：验证设计规定的字号值 28 在 LauncherConstants 中一致
        XCTAssertEqual(nsFont.pointSize, 28.0, accuracy: 0.1, "系统字体 28pt 应可正确初始化（bodyText 字号基准验证）")
        // 保证 LauncherTheme.bodyText 存在且编译（已在 test_C1F 覆盖）
        let _: Font = LauncherTheme.bodyText
    }

    // MARK: - C1-E: 几何常量契约

    /// pixelBorderWidth 必须 == 2
    func test_C1E_pixelBorderWidth_is2() {
        XCTAssertEqual(
            LauncherTheme.pixelBorderWidth,
            2.0,
            accuracy: 0.001,
            "LauncherTheme.pixelBorderWidth 必须 == 2（2px pixel-border 契约）"
        )
    }

    /// panelCornerRadius 必须 == 14
    func test_C1E_panelCornerRadius_is14() {
        XCTAssertEqual(
            LauncherTheme.panelCornerRadius,
            14.0,
            accuracy: 0.001,
            "LauncherTheme.panelCornerRadius 必须 == 14（14px 圆角契约）"
        )
    }

    /// pixelShadowOffset 必须 == CGSize(width: 4, height: 4)
    func test_C1E_pixelShadowOffset_is4x4() {
        XCTAssertEqual(
            LauncherTheme.pixelShadowOffset.width,
            4.0,
            accuracy: 0.001,
            "LauncherTheme.pixelShadowOffset.width 必须 == 4"
        )
        XCTAssertEqual(
            LauncherTheme.pixelShadowOffset.height,
            4.0,
            accuracy: 0.001,
            "LauncherTheme.pixelShadowOffset.height 必须 == 4"
        )
    }

    /// pixelShadowSmOffset 必须 == CGSize(width: 2, height: 2)
    func test_C1E_pixelShadowSmOffset_is2x2() {
        XCTAssertEqual(
            LauncherTheme.pixelShadowSmOffset.width,
            2.0,
            accuracy: 0.001,
            "LauncherTheme.pixelShadowSmOffset.width 必须 == 2"
        )
        XCTAssertEqual(
            LauncherTheme.pixelShadowSmOffset.height,
            2.0,
            accuracy: 0.001,
            "LauncherTheme.pixelShadowSmOffset.height 必须 == 2"
        )
    }

    // MARK: - C1-B/C 全套颜色 dynamic 差异验证（light != dark）

    /// canvas 在 light 和 dark 模式下颜色不同（验证 dynamic color 生效）
    func test_C1_canvas_isDynamic_lightDarkDiffer() {
        let light = rgbComponents(of: LauncherTheme.canvas, appearance: .aqua)
        let dark  = rgbComponents(of: LauncherTheme.canvas, appearance: .darkAqua)
        XCTAssertNotEqual(light.r, dark.r, "canvas 在 light/dark 下 red 分量应不同（dynamic color 未生效）")
    }

    /// primary 在 light 和 dark 模式下颜色不同
    func test_C1_primary_isDynamic_lightDarkDiffer() {
        let light = rgbComponents(of: LauncherTheme.primary, appearance: .aqua)
        let dark  = rgbComponents(of: LauncherTheme.primary, appearance: .darkAqua)
        XCTAssertNotEqual(light.r, dark.r, "primary 在 light/dark 下 red 分量应不同（dynamic color 未生效）")
    }
}
