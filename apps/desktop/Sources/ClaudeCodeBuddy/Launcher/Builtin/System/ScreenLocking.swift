import Foundation

/// 锁屏 seam 协议（SC6 契约）。
/// 生产实现用私有框架 SACLockScreenImmediate，测试注入 Mock（绝不真锁屏）。
protocol ScreenLocking {
    /// 立即锁定屏幕。
    /// - Throws: `LauncherError.systemCommandFailed("锁定屏幕")` 如果锁屏失败
    func lock() throws
}

// MARK: - 生产实现

/// 通过 Login 私有框架 SACLockScreenImmediate 锁屏的生产实现。
/// dlopen + dlsym 动态调用，无需静态链接，无需额外 TCC 权限。
struct LoginFrameworkScreenLocker: ScreenLocking {

    private static let loginFrameworkPath =
        "/System/Library/PrivateFrameworks/login.framework/Versions/Current/login"

    func lock() throws {
        // 动态加载 login.framework
        guard let handle = dlopen(Self.loginFrameworkPath, RTLD_LAZY) else {
            throw LauncherError.systemCommandFailed("锁定屏幕")
        }
        defer { dlclose(handle) }

        // 查找 SACLockScreenImmediate 符号
        guard let sym = dlsym(handle, "SACLockScreenImmediate") else {
            throw LauncherError.systemCommandFailed("锁定屏幕")
        }

        // 调用锁屏函数（返回 Int32，0 = 成功）
        typealias LockFn = @convention(c) () -> Int32
        let lockScreen = unsafeBitCast(sym, to: LockFn.self)
        let result = lockScreen()

        guard result == 0 else {
            throw LauncherError.systemCommandFailed("锁定屏幕")
        }
    }
}
