# AppDelegate.applicationDidFinishLaunching 调 @MainActor 单例 setup 用 MainActor.assumeIsolated

<!-- tags: mainactor, swift-concurrency, appdelegate, isolated, assumeisolated, async, applicationdidfinishlaunching -->
**Scenario**: LauncherManager 标注 `@MainActor final class`，所有方法继承 MainActor 隔离。AppDelegate.applicationDidFinishLaunching 在主线程被调用但**不**是 async 方法，直接写 `LauncherManager.shared.setup()` 在 Swift 6 严格并发模式下报"Call to main actor-isolated instance method 'setup()' in a synchronous nonisolated context"。
**Lesson**: 用 `MainActor.assumeIsolated { LauncherManager.shared.setup() }` 显式声明"我确定此时已在 MainActor 上"，编译器接受。优于 `Task { @MainActor in ... }`（异步切换 + 时序不确定）或 `await MainActor.run { ... }`（applicationDidFinishLaunching 不是 async）。通用规则：从 AppDelegate/NSWindowDelegate/SwiftUI .onAppear 等"已知在主线程"的非 async context 调 @MainActor 方法用 assumeIsolated 是最优解；只有真异步链路才用 await MainActor.run。
**Evidence**: task 001 AppDelegate.swift setupLauncher() 用此模式；`make build` 0 error，runtime `buddy ping` 验证 setup() 正常执行。
