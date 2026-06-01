# SwiftLint large_tuple 用内部结构体替代多元组返回

<!-- tags: swiftlint, tuples, struct, code-quality -->
**Scenario**: `CatPersonality.modifiedIdleWeights()` 返回 4 元素命名元组 `(sleep: Float, breathe: Float, blink: Float, clean: Float)`，SwiftLint 报 `large_tuple` 违规（>3 元素）。
**Lesson**: SwiftLint `large_tuple` 规则限制元组元素不超过 3 个。返回 4+ 值时，在类型内部定义 `struct IdleWeights { let sleep, breathe, blink, clean: Float }` 替代元组。结构体有命名参数、可扩展、不触发 lint 违规，且调用方代码几乎不变（`.sleep` vs `.0`）。
**Evidence**: CatPersonality.swift 从 `func modifiedIdleWeights(...) -> (sleep: Float, breathe: Float, blink: Float, clean: Float)` 改为返回 `IdleWeights` 结构体，lint 违规消失。
