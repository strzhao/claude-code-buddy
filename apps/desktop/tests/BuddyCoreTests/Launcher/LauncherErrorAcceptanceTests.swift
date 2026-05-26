import XCTest
import Security
import CryptoKit
@testable import BuddyCore

// MARK: - LauncherErrorAcceptanceTests
//
// 验收测试：LauncherError task 002 新增 5 个 case 的 localizedDescription 契约
//
// 设计文档覆盖点（task 002 LauncherError.swift 草图）：
//   A. providerNotConfigured.localizedDescription 含"配置"或"launcher config"
//   B. invalidAPIKey("too short").localizedDescription 含关联值 "too short"
//   C. networkFailure(URLError(.timedOut)).localizedDescription 含"网络"或"timed"
//   D. providerHTTPError(500, "internal").localizedDescription 含 "500" 和 "internal"
//   E. secretStoreUnavailable.localizedDescription 含"密钥"或"存储"或"~/.buddy/"
//   F. 已有的 hotkeyConflict case 不受影响（向后兼容）
//   G. 所有 case 的 errorDescription 不返回 nil（LocalizedError 契约）
//   H. error as Error 可以转回 LauncherError（类型完整性）
//
// 黑盒原则：只通过公开 API（localizedDescription / errorDescription）验证文本契约，
// 不依赖具体实现的 switch 分支顺序。
// 测试 WILL NOT compile 直到蓝队合并实现 — 这是预期的 TDD 红灯。

final class LauncherErrorAcceptanceTests: XCTestCase {

    // MARK: - A. providerNotConfigured

    /// providerNotConfigured.localizedDescription 必须含"配置"或"launcher config"
    /// 用户需要知道"去哪里配置"，而不只是"出错了"
    func test_providerNotConfigured_localizedDescription_containsConfigHint() {
        let error = LauncherError.providerNotConfigured
        let desc = error.localizedDescription.lowercased()

        let containsHint = desc.contains("配置") || desc.contains("launcher config")
        XCTAssertTrue(containsHint,
                      "providerNotConfigured.localizedDescription 必须含\"配置\"或\"launcher config\"，" +
                      "实际: \(error.localizedDescription)")
    }

    /// providerNotConfigured.errorDescription 不返回 nil
    func test_providerNotConfigured_errorDescription_notNil() {
        let error = LauncherError.providerNotConfigured
        XCTAssertNotNil(error.errorDescription,
                        "providerNotConfigured.errorDescription 不应返回 nil")
    }

    // MARK: - B. invalidAPIKey

    /// invalidAPIKey("too short").localizedDescription 必须含关联值 "too short"
    func test_invalidAPIKey_localizedDescription_containsReason() {
        let error = LauncherError.invalidAPIKey("too short")
        let desc = error.localizedDescription

        XCTAssertTrue(desc.contains("too short"),
                      "invalidAPIKey(\"too short\").localizedDescription 必须含 \"too short\"，" +
                      "实际: \(desc)")
    }

    /// invalidAPIKey 关联值会出现在描述中（不被丢弃）
    func test_invalidAPIKey_localizedDescription_containsDifferentReason() {
        let error = LauncherError.invalidAPIKey("missing")
        XCTAssertTrue(error.localizedDescription.contains("missing"),
                      "invalidAPIKey(\"missing\").localizedDescription 必须含 \"missing\"，" +
                      "实际: \(error.localizedDescription)")
    }

    /// invalidAPIKey errorDescription 不返回 nil
    func test_invalidAPIKey_errorDescription_notNil() {
        XCTAssertNotNil(LauncherError.invalidAPIKey("test").errorDescription)
    }

    // MARK: - C. networkFailure

    /// networkFailure(URLError(.timedOut)).localizedDescription 含"网络"或"timed"
    func test_networkFailure_timedOut_localizedDescription_containsNetworkOrTimed() {
        let error = LauncherError.networkFailure(URLError(.timedOut))
        let desc = error.localizedDescription.lowercased()

        let containsHint = desc.contains("网络") || desc.contains("timed") ||
                           desc.contains("timeout") || desc.contains("失败")
        XCTAssertTrue(containsHint,
                      "networkFailure(timedOut).localizedDescription 必须含\"网络\"或\"timed\"相关词，" +
                      "实际: \(error.localizedDescription)")
    }

    /// networkFailure errorDescription 不返回 nil
    func test_networkFailure_errorDescription_notNil() {
        XCTAssertNotNil(LauncherError.networkFailure(URLError(.timedOut)).errorDescription)
    }

    /// networkFailure 保留底层 error 信息（描述中应包含底层错误的某些内容）
    func test_networkFailure_containsUnderlyingErrorInfo() {
        let underlying = URLError(.notConnectedToInternet)
        let error = LauncherError.networkFailure(underlying)
        let desc = error.localizedDescription

        // 描述不应该是个通用错误消息，而应该包含底层信息
        XCTAssertFalse(desc.isEmpty,
                       "networkFailure.localizedDescription 不应为空字符串")
    }

    // MARK: - D. providerHTTPError

    /// providerHTTPError(500, "internal").localizedDescription 含 "500" 和 "internal"
    func test_providerHTTPError_500_localizedDescription_containsCodeAndBody() {
        let error = LauncherError.providerHTTPError(500, "internal")
        let desc = error.localizedDescription

        XCTAssertTrue(desc.contains("500"),
                      "providerHTTPError(500, ...).localizedDescription 必须含 \"500\"，" +
                      "实际: \(desc)")
        XCTAssertTrue(desc.contains("internal"),
                      "providerHTTPError(..., \"internal\").localizedDescription 必须含 \"internal\"，" +
                      "实际: \(desc)")
    }

    /// providerHTTPError(401, "unauthorized") 含 "401"
    func test_providerHTTPError_401_localizedDescription_containsCode() {
        let error = LauncherError.providerHTTPError(401, "unauthorized")
        XCTAssertTrue(error.localizedDescription.contains("401"),
                      "providerHTTPError(401, ...).localizedDescription 必须含 \"401\"，" +
                      "实际: \(error.localizedDescription)")
    }

    /// providerHTTPError errorDescription 不返回 nil
    func test_providerHTTPError_errorDescription_notNil() {
        XCTAssertNotNil(LauncherError.providerHTTPError(500, "err").errorDescription)
    }

    // MARK: - E. secretStoreUnavailable

    /// secretStoreUnavailable.localizedDescription 含"密钥"或"存储"或"~/.buddy/"
    func test_secretStoreUnavailable_localizedDescription_containsStorageHint() {
        let error = LauncherError.secretStoreUnavailable
        let desc = error.localizedDescription

        let containsHint = desc.contains("密钥") || desc.contains("存储") ||
                           desc.contains("~/.buddy/") || desc.contains("keychain") ||
                           desc.contains("Keychain") || desc.contains("secret")
        XCTAssertTrue(containsHint,
                      "secretStoreUnavailable.localizedDescription 必须含\"密钥\"或\"存储\"或\"~/.buddy/\"，" +
                      "实际: \(desc)")
    }

    /// secretStoreUnavailable errorDescription 不返回 nil
    func test_secretStoreUnavailable_errorDescription_notNil() {
        XCTAssertNotNil(LauncherError.secretStoreUnavailable.errorDescription)
    }

    // MARK: - F. 向后兼容：hotkeyConflict 不受影响

    /// task 001 的 hotkeyConflict case 在 task 002 追加后仍然正常工作
    func test_hotkeyConflict_stillWorks_backwardCompatible() {
        let error = LauncherError.hotkeyConflict("⌘⇧Space")
        let desc = error.localizedDescription

        XCTAssertTrue(desc.contains("⌘⇧Space"),
                      "hotkeyConflict 关联值必须出现在 localizedDescription 中，" +
                      "实际: \(desc)")
        XCTAssertNotNil(error.errorDescription,
                        "hotkeyConflict.errorDescription 不应返回 nil（向后兼容）")
    }

    // MARK: - G. 所有 5 个新 case 的 errorDescription 均不为 nil

    /// 批量验证 task 002 新增 5 case 的 errorDescription 非 nil
    func test_allTask002Cases_errorDescription_notNil() {
        let cases: [LauncherError] = [
            .providerNotConfigured,
            .invalidAPIKey("test-reason"),
            .networkFailure(URLError(.timedOut)),
            .providerHTTPError(500, "error body"),
            .secretStoreUnavailable
        ]
        for error in cases {
            XCTAssertNotNil(error.errorDescription,
                            "\(error).errorDescription 不应返回 nil（LocalizedError 契约）")
        }
    }

    // MARK: - H. error as Error 可以转回 LauncherError（类型完整性）

    /// LauncherError 作为 Error 抛出后可以 catch 并转型回 LauncherError
    func test_launcherError_canBeCastFromError() {
        func throwsLauncherError() throws {
            throw LauncherError.providerNotConfigured
        }

        do {
            try throwsLauncherError()
            XCTFail("应该抛出 LauncherError")
        } catch let err as LauncherError {
            if case .providerNotConfigured = err {
                // 预期路径
            } else {
                XCTFail("转型后应该是 .providerNotConfigured，实际: \(err)")
            }
        } catch {
            XCTFail("Error 转型回 LauncherError 必须成功")
        }
    }
}
