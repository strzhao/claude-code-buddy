import Foundation

/// 运行环境探测。
///
/// 用途：在 XCTest 宿主中关闭「永不终止」的逐帧动画（如 `TimelineView(.animation)`），
/// 避免动画视图被 host 进测试窗口后残留、在后续测试泵 RunLoop 时把 CFRunLoop 拖入
/// 113% CPU 无限空转（曾导致 `swift test` 偶发挂死数小时）。
enum RuntimeEnvironment {
    /// 是否运行在 XCTest 测试宿主中。
    ///
    /// 判据：测试进程里 XCTest 框架被加载，`XCTestCase` 类可解析；生产 app 进程不链接
    /// XCTest，解析为 nil。比 `XCTestConfigurationFilePath` 环境变量可靠——后者是 Xcode
    /// 专属，SwiftPM 的 `swift test` 运行器并不设置（实测会漏判）。
    /// 兜底再叠加环境变量判定，覆盖 Xcode 场景。计算一次并缓存，避免每帧重复探测。
    static let isRunningTests: Bool = {
        if NSClassFromString("XCTestCase") != nil { return true }
        return ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }()
}
