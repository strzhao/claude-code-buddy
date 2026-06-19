import XCTest
import AppKit
@testable import BuddyCore

// MARK: - CopyImageAcceptanceTests
//
// 红队验收测试：CopyService.copyImage 写 PNG 到 NSPasteboard（named pasteboard 隔离）
//
// 设计文档引用：
//   .autopilot/runtime/sessions/qrcode/requirements/20260619-开始实现，图片通道认/state.md
//   ## 设计文档 §5 CopyService 加 copyImage(_ data: Data)：clearContents() + setData(data, forType: .png)
//   ## 契约规约 接口签名: func copyImage(_ data: Data)
//   ## 契约规约 副作用清单: 写剪贴板 用户点击 → NSPasteboard.setData(.png)
//   ## 验收场景:
//     场景3.P1 [real-process]: 点击 → CopyService.copyImage 写 public.png 到 pasteboard
//     场景3.P2 [det-machine]: 剪贴板被读 PNG 与 BUDDY_OUTPUT_IMAGE 一致（字节比对）
//     场景8.P2 [real-process]: 非 qr 插件图片被点击 → 复制 PNG（与 qr 一致）
//
// 黑盒策略：注入 NSPasteboard(name:) 隔离，断言 setData(.png) 类型 + 字节一致。
// 参考知识库：2026-05-29-nspasteboard-test-isolation-via-named-pasteboard
// 测试 WILL NOT compile 直到蓝队 T6 完成（CopyService.copyImage）。
//
// ⚠️ 铁律：本文件由红队独立编写，未读取蓝队 CopyService.swift 本次新增实现。

final class CopyImageAcceptanceTests: XCTestCase {

    // MARK: - Fixture: 1x1 合法 PNG（与 StdinExecutorImageOutputAcceptanceTests 同款）

    private let samplePNG: Data = Data([
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
        0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
        0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
        0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89,
        0x00, 0x00, 0x00, 0x0D, 0x49, 0x44, 0x41, 0x54,
        0x78, 0x9C, 0x62, 0x00, 0x01, 0x00, 0x00, 0x05, 0x00,
        0x01, 0x0D, 0x0A, 0x2D, 0xB4,
        0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44,
        0xAE, 0x42, 0x60, 0x82
    ])

    /// 创建隔离的 named pasteboard（参考 2026-05-29-nspasteboard-test-isolation-via-named-pasteboard）
    private func makeIsolatedPasteboard() -> NSPasteboard {
        let name = NSPasteboard.Name("ccb-copy-image-test-\(UUID().uuidString)")
        return NSPasteboard(name: name)
    }

    // MARK: - 场景3.P1 [real-process]: copyImage 写 public.png 类型到 pasteboard
    //
    // 契约引用：CopyService.copyImage clearContents() + setData(data, forType: .png)
    // 场景3.P1 assert: 含 public.png 类型 AND data 非空

    func test_P3_1_copyImage_writesPublicPngType_dataNonEmpty() {
        let pb = makeIsolatedPasteboard()
        let service = CopyService(pasteboard: pb)

        service.copyImage(samplePNG)

        // 场景3.P1 assert: 含 public.png 类型
        let types = pb.types ?? []
        XCTAssertTrue(
            types.contains(.png),
            "场景3.P1 失败：copyImage 后 pasteboard 必须含 .png (public.png) 类型，实际 types: \(types)"
        )

        // 场景3.P1 assert: data 非空
        let pngData = pb.data(forType: .png)
        XCTAssertNotNil(pngData, "copyImage 后 .png 类型 data 必须非空")
        XCTAssertFalse(pngData?.isEmpty ?? true, ".png data 必须非空")
    }

    // MARK: - 场景3.P1 补充: clearContents 先行（旧内容被清）

    func test_P3_1_copyImage_clearsExistingContents_first() {
        let pb = makeIsolatedPasteboard()
        let service = CopyService(pasteboard: pb)

        // 先写一个 string 污染
        pb.clearContents()
        pb.setString("stale content", forType: .string)
        XCTAssertEqual(pb.string(forType: .string), "stale content")

        service.copyImage(samplePNG)

        // 场景3.P1 assert 含 .png
        XCTAssertNotNil(pb.data(forType: .png), "copyImage 后必须有 .png data")
        // clearContents 副作用：旧 string 应被清空
        XCTAssertNil(
            pb.string(forType: .string),
            "copyImage 必须 clearContents() 先行，清掉旧 string 内容"
        )
    }

    // MARK: - 场景3.P2 [det-machine]: 剪贴板 PNG 与输入字节一致（md5 比对）
    //
    // 契约引用：场景3.P2 assert: md5(clipboard_png)==md5(file_png) OR decoded 相同
    // 这里验 copyImage 输入 → pasteboard 输出字节一致

    func test_P3_2_clipboardPng_bytesEqualInput() throws {
        let pb = makeIsolatedPasteboard()
        let service = CopyService(pasteboard: pb)

        service.copyImage(samplePNG)

        let clipboardData = pb.data(forType: .png)
        let cbData = try XCTUnwrap(clipboardData, "pasteboard .png data 必须存在")
        XCTAssertEqual(
            cbData,
            samplePNG,
            "场景3.P2 失败：剪贴板 PNG 字节必须与 copyImage 输入字节一致"
        )
    }

    // MARK: - 场景3.P2 补充: 多次 copyImage 不累积（每次 clearContents）

    func test_P3_2_multipleCopyImages_doesNotAccumulate() {
        let pb = makeIsolatedPasteboard()
        let service = CopyService(pasteboard: pb)

        let otherPNG = Data([0x89, 0x50, 0x4E, 0x47, 0xFF])  // 另一段字节

        service.copyImage(samplePNG)
        service.copyImage(otherPNG)

        let final = pb.data(forType: .png)
        XCTAssertEqual(
            final,
            otherPNG,
            "多次 copyImage 每次 clearContents，最终应只保留最后一次的字节"
        )
    }

    // MARK: - 场景8.P2 [real-process]: 通用图片能力 — 任意 PNG 字节都能复制（不限 qr 插件）
    //
    // 契约引用：场景8.P2 assert: 含 public.png
    // 关键：CopyService.copyImage 是通用 API，不耦合 qr 插件身份

    func test_P8_2_copyImage_genericForAnyPng_arbitraryBytes() {
        let pb = makeIsolatedPasteboard()
        let service = CopyService(pasteboard: pb)

        // 一段完全无关的 PNG 字节（模拟"非 qr 插件"输出）
        let arbitraryPNG = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
                                  0x00, 0x00, 0x00, 0x00])
        service.copyImage(arbitraryPNG)

        let types = pb.types ?? []
        XCTAssertTrue(
            types.contains(.png),
            "场景8.P2 失败：copyImage 必须通用，任意 PNG 字节都应写入 public.png 类型（与插件身份解耦）"
        )
        XCTAssertEqual(pb.data(forType: .png), arbitraryPNG,
                       "任意 PNG 字节必须原样写入剪贴板")
    }

    // MARK: - 场景3.P3 [real-process] 辅助: copyImage 是用户点击的副作用入口
    //
    // 注：完整 AX 可达性树 + AXActions contains "press" 在 LauncherResultImageSnapshotTests
    // 或 QA 真机判定。本文件验 CopyService 契约层：API 可被点击 handler 调用且副作用可观测。

    func test_P3_3_copyImage_isCallableAndObservable() {
        // VISUAL_RESIDUE: AXActions contains "press" 且 press 后剪贴板变更 — 留 QA 真机判定
        // 此处锁定契约层：copyImage 调用后剪贴板必然变更（可被 AX handler 感知的前提）
        let pb = makeIsolatedPasteboard()
        let service = CopyService(pasteboard: pb)

        // 调用前 pasteboard 空
        XCTAssertNil(pb.data(forType: .png), "调用前 pasteboard 应无 .png")

        service.copyImage(samplePNG)

        // 调用后必然有 .png（这是 "press 后剪贴板变更" 的前置可观测点）
        XCTAssertNotNil(
            pb.data(forType: .png),
            "copyImage 必须让剪贴板产生可观测变更（AX press handler 的前置契约）"
        )
        // VISUAL_RESIDUE: 留 QA 真机判定 AXActions.contains("press")
    }
}
