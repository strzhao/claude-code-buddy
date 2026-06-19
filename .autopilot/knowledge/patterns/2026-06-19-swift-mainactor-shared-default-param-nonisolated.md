# Swift 6：@MainActor 隔离的 `.shared` 不能作 nonisolated 默认参数 / 在 nonisolated init·start() 引用

<!-- tags: swift, swift-6, concurrency, mainactor, actor-isolation, static-shared, default-parameter, nonisolated, singleton, compile-error, future-swift-version, queryhandler, sessionmanager, resolvedregistry, sendable -->

**Scenario**: 给 `QueryHandler` 加 `registry: BuiltinPluginRegistry` 依赖。初版写 `init(..., registry: BuiltinPluginRegistry = .shared)`（默认参数引用 `BuiltinPluginRegistry.shared`）。`BuiltinPluginRegistry` 是 `@MainActor final class`，`.shared` 是 `@MainActor` 隔离的 static。SourceKit 报 2 处 Swift 6 错误（当前 Swift 5 模式是 warning，`swift build` 不报，但 LSP 标红）：
1. `QueryHandler.swift` init 默认参数 `= .shared`——默认参数表达式在 **nonisolated** 上下文求值，不能引用 @MainActor 隔离的 `.shared`。
2. `SessionManager.swift` `start()`（nonisolated）里 `QueryHandler(registry: BuiltinPluginRegistry.shared, ...)`——nonisolated 函数体不能引用 @MainActor 的 `.shared`。

**根因**：Swift 默认参数表达式（default argument expression）是 **nonisolated** 求值的（与函数本身的 actor 隔离无关）。所以即使 `QueryHandler` 整体常在主线程用，`init` 的默认参数 `= .shared` 仍非法。同理 nonisolated 的 `start()` 函数体。

**Lesson**：需要 @MainActor 单例作依赖时，三种合法写法：

1. **可选参数 + 在 @MainActor 方法内 resolve（推荐，本任务采用）**：
   ```swift
   init(..., registry: BuiltinPluginRegistry? = nil) { self.registry = registry }   // nil 默认合法
   @MainActor private func resolvedRegistry() -> BuiltinPluginRegistry {
       registry ?? BuiltinPluginRegistry.shared   // @MainActor 方法内引用 .shared 合法
   }
   ```
   生产传 nil（resolve 到 .shared），测试传 mock。nonisolated 调用方（如 `SessionManager.start()`）不必引用 `.shared`——用默认 nil 即可。

2. **必填参数（无默认）+ 调用方在 @MainActor 上下文显式传**：`init(registry: BuiltinPluginRegistry)`，调用方必须在 @MainActor 函数内传 `.shared`。若调用方 nonisolated（如 `start()`）则无效——回到方案 1。

3. **`MainActor.assumeIsolated`（运行时断言，不推荐）**：项目已从 assumeIsolated 迁移到编译期 @MainActor（见 QueryHandler 注释 qa-reviewer B-1），新代码勿再用。

**How to apply**:
- 给 nonisolated 类型/函数注入 @MainActor 单例依赖：优先方案 1（optional + @MainActor resolve）。
- `make build`（Swift 5）对这些是 warning 不报错；但 SourceKit LSP 会标 `error-in-future-swift-version`。新代码应主动消除（项目迁移 Swift 6 时会批量炸）。
- 诊断信号：SourceKit 报 `Main actor-isolated static property 'shared' can not be referenced from a nonisolated context` → 90% 是默认参数或 nonisolated 函数体引用了 @MainActor 单例。

**Evidence**: 2026-06-19 launcher debug CLI 任务：QueryHandler 加 registry 依赖初版 `= .shared` 触发 2 处 Swift 6 警告；改 optional+nil 默认 + `resolvedRegistry()` @MainActor resolve 后 LSP 警告清零，`make build`/`make lint` 干净，13 验收测试 + 42 回归全绿。

**关联**：
- [[2026-05-30-swift-mainactor-protocol-cross-actor-call-no-nested-mainactor-run]]（@MainActor 跨 actor hop）—— 不同维度的 MainActor 陷阱。
- [[2026-05-28-swift-protocol-method-no-default-values]]（Swift 5.9 协议方法默认参数限制）—— 另一种默认参数限制，语言层不同根因。
- [[2026-05-26-appdelegate-mainactor-assumeisolated-setup]]（assumeIsolated setup）—— 本条方案 1 是其编译期替代精神。
