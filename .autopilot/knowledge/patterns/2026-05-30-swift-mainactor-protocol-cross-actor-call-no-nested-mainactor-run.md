# Swift Concurrency: @MainActor 协议方法跨 actor 调用编译器自动 hop，**不**嵌套 `MainActor.run`

<!-- tags: swift, concurrency, mainactor, protocol, async, hop, mainactor-run, plan-reviewer-blocker, market-hud, swift-6 -->

**Scenario**: task 006 MarketHUD 设计了 @MainActor 协议：

```swift
protocol MarketHUDDisplaying: AnyObject {
    @MainActor func show(text: String, actions: [MarketHUD.Action])
    @MainActor func dismiss()
}
```

第一版 MarketplaceManager.syncFromRemote（nonisolated async 上下文）写：

```swift
// ❌ 第一版（错误）
await MainActor.run {
    self.hud?.show(text: "translate 已更新到 v0.2.0", actions: [...])
}
```

plan-reviewer 抓出 B2 BLOCKER：双重 hop / 嵌套语义歧义。`MarketHUDDisplaying.show` 已是 `@MainActor`，再外层 `MainActor.run { hud?.show(...) }` 会让编译器先 hop 到 MainActor 执行外层闭包，闭包内**又**调一个已经在 MainActor 上的方法 — 多此一举且容易在 Swift 6 mode 下成为警告。

**Lesson**: **从 nonisolated async 上下文调 @MainActor 协议方法时，直接 `await methodCall(...)` 即可——编译器自动 hop 到 MainActor 执行，无需 MainActor.run 包裹**。

```swift
// ✅ 正确写法
await self.hud?.show(text: "translate 已更新到 v0.2.0", actions: [...])
```

**原理**:
- 调用 `@MainActor func show(...)` 时，调用方与方法的 actor isolation 不一致 → 编译器隐式插入 actor hop
- `await` 关键字标记此处可能挂起（hop 是 suspension point 之一）
- Optional chaining `hud?.show(...)` + actor hop 仍工作（nil 时 hop 也省略）

**何时需要 `MainActor.run`**:
- 调用**非 actor 隔离**的代码但需要主线程（如 NSPanel 直接操作）：
  ```swift
  await MainActor.run {
      panel.makeKeyAndOrderFront(nil)   // NSPanel 不在 actor 内但需 main thread
  }
  ```
- 包裹**多条**主线程操作避免多次 hop：
  ```swift
  await MainActor.run {
      panel.title = "x"
      panel.setContentSize(NSSize(...))
      panel.center()
  }
  ```

**何时**不**需要 `MainActor.run`**:
- 单次调用 @MainActor 标记的方法 / 单次访问 @MainActor 隔离的属性
- 编译器自动 hop 已足够

**性能注意**：`MainActor.run { @MainActor 方法() }` 不仅冗余，还可能让 actor hop 次数从 1 次变 2 次（先 hop 到 MainActor 执行闭包，闭包内再 hop ... 取决于编译器优化，但语义上不安全）。

**Evidence**: task 006 plan-reviewer B2 BLOCKER 抓出此问题；修复后 syncFromRemote 内 4 处 `await hud?.show(...)` 直接调，编译通过 + 蓝队 9 集成单测 + 红队 13 AT 全部 PASS。

**关联陷阱**:
- **handler closure 也应标 @MainActor**：`struct Action { let handler: @MainActor () -> Void }`，避免调用方在 nonisolated 上下文捕获 main-thread-only API 时报错
- **measurable benchmark**：嵌套 `MainActor.run` 在 release build 中虽然被优化器消除，但 debug build 下确实多一次 task scheduling
- **Swift 6 strict concurrency mode** 下，错误的嵌套会成为编译错误而非警告

**侦察清单**（写 Swift Concurrency 跨 actor 调用代码时立即检查）:

1. ✅ 调用的方法是否标 @MainActor？标了 → 直接 `await methodCall(...)`，不嵌套 MainActor.run
2. ✅ 多条 main-thread 操作 → 用 1 个 `MainActor.run { ... }` 包裹批处理
3. ✅ closure handler 类型 → 主线程依赖时标 `@MainActor () -> Void`
4. ✅ Optional chaining `?.` 与 actor hop 互兼容，可放心 chain

**关联**:
- 与 task 002 pattern "Swift Process 桥接 async 用 terminationHandler"（同样关注 async 桥接陷阱）
- 与 SwiftUI `Task { @MainActor in }` 模式（显式标 main actor 是因为 Task 默认 nonisolated）
- 与 Swift 6 migration: 这类隐式 hop 在 strict mode 下编译期可被验证
