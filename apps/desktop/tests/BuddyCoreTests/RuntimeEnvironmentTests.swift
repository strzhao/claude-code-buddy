import XCTest
@testable import BuddyCore

/// 守护 `RuntimeEnvironment.isRunningTests` 探测逻辑。
///
/// `LauncherPulseDots` 等永不终止的动画依赖此判定在测试下冻结；若探测失效，
/// 动画会在测试中逐帧重绘并残留窗口，导致 `swift test` 偶发挂死数小时。
final class RuntimeEnvironmentTests: XCTestCase {

    /// 当前正运行在 XCTest 宿主中，探测必须为 true。
    /// 反向探针：若有人误改/删除 XCTestConfigurationFilePath 检测，此处变 false → 红灯。
    func test_isRunningTests_isTrueUnderXCTest() {
        XCTAssertTrue(
            RuntimeEnvironment.isRunningTests,
            "RuntimeEnvironment.isRunningTests 在 XCTest 宿主中必须为 true；" +
            "否则 LauncherPulseDots 的 TimelineView(.animation) 不会被冻结，测试会偶发挂死。"
        )
    }
}
