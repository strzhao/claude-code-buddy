# NSPasteboard 测试隔离用 `NSPasteboard(name:)` 而非 `.general` 单例

<!-- tags: nspasteboard, appkit, testing, isolation, global-singleton, dependency-injection, named-pasteboard, ci, macos, prompt-executor, swift-testing -->

**Scenario**: task 006 PromptExecutor 加剪贴板复制（autoCopyToClipboard=true 时调 `NSPasteboard.general.setString(...)`）。红队需要测试：
- 场景 2：autoCopyToClipboard=false → pasteboard 不变
- 场景 3：autoCopyToClipboard=true → pasteboard.string == 响应文本
- 场景 4：空 stdout → pasteboard 不变
- 场景 5：错误路径 → pasteboard 不变

直接用 `NSPasteboard.general` 写测试有 3 个隐患：

1. **进程级全局单例**：多个测试并发跑 → 测试 A 写入的内容污染测试 B 的"pasteboard 不变"断言
2. **CI 沙箱环境无桌面会话**：`NSPasteboard.general` 行为未定义，可能崩溃或返回 nil
3. **无法 mock**：`NSPasteboard.general` 是 static let，无 inject 点，"断言未被调用"只能间接靠"读取前后内容比对"

plan-reviewer 抓到此问题（D3/D4 BLOCKER）。

**Lesson**: macOS AppKit 的 `NSPasteboard(name: NSPasteboard.Name)` 初始化器创建**独立具名 pasteboard**，与 `.general`、`.find` 等系统 pasteboard 完全隔离。测试用此模式：

```swift
// 生产代码：依赖注入 pasteboard
final class PromptExecutor {
    let pasteboard: NSPasteboard
    
    init(provider: LauncherProvider, activeProviderModel: String, 
         pasteboard: NSPasteboard = .general) {
        self.provider = provider
        self.activeProviderModel = activeProviderModel
        self.pasteboard = pasteboard
    }
    
    // execute() 内调 pasteboard.setString(...)，生产时是 .general
}

// 测试：注入隔离 pasteboard
let isolated = NSPasteboard(name: NSPasteboard.Name("test-\(UUID().uuidString)"))
let executor = PromptExecutor(provider: mock, activeProviderModel: "x", pasteboard: isolated)

// 测试执行
_ = try await executor.execute(...)

// 断言隔离 pasteboard 状态
XCTAssertEqual(isolated.string(forType: .string), "你好")
// 或 nil 断言"未被调用"：
XCTAssertNil(isolated.string(forType: .string))
```

**关键优势**：
- ✅ UUID 命名保证测试间互不影响（并发安全）
- ✅ 不依赖桌面会话——具名 pasteboard 在 headless / CI 环境也工作
- ✅ 注入式 DI 自然，无需 mock 框架
- ✅ 生产代码默认行为不变（`.general` 是默认值）

**对比 mock 协议方案**（plan-reviewer 提的方案 A）：
- 优势：完全隔离任何 NSPasteboard 调用
- 劣势：引入新协议 + spy 类，代码复杂度增加；具名 pasteboard 已足够 + 接近真实 API

**Evidence**: task 006 红队 10 个 BuiltinTranslateAcceptanceTests 用此模式全 PASS，QA Wave 1 跑 50 tests 0 failures，并发跑无污染。

**关联**：
- 与"全局单例难测试"通用模式（Singleton/global state in testing）
- 与 dependency injection 思想：生产用 `.general`，测试注入具名隔离
- AppKit 其他类似 API：`UserDefaults(suiteName:)`、`FileManager()` 实例化、`URLSession(configuration:)` 等都有类似隔离模式
