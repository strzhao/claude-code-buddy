# NSPanel hidesOnDeactivate 与 didResignKeyNotification 双触发的 Combine 重入防御

<!-- tags: nspanel, combine, published, reentrancy, hidesondeactivate, didresignkey, race-condition -->
**Scenario**: 启动器 NSPanel 设 `hidesOnDeactivate=true`，同时注册 `NSWindow.didResignKeyNotification` observer 调 `hide()`。当 panel 失焦时：(1) AppKit 内部因 hidesOnDeactivate=true 调 orderOut；(2) orderOut 同步发 didResignKeyNotification；(3) observer 再次调 hide()。如果 hide() 顺序是 `orderOut(nil) → isVisible=false`，在 step 2 的 notification 回调中 isVisible 还是 true，重入 hide() 会再次 orderOut（无害）+ 再次设 isVisible=false（@Published 触发第二次 sink），导致 Combine 订阅者收到 `true → false → false` 三次而非两次。
**Lesson**: 两个防御组合：(A) `hide()` 顶部 `guard isVisible else { return }` 短路；(B) `hide()` 内**先**设 `isVisible = false` 再 `orderOut(nil)`，避免 orderOut 同步触发的 notification 回调时 guard 失效。红队 acceptance test 必须用 Combine sink 精确锁定"恰好 N 次变更"+"逐项值序列"（如 `XCTAssertEqual(receivedValues, [true, false])`），不能仅断言 isVisible 最终态。
**Evidence**: task 001 LauncherManager.hide() 落地此双防御；`test_SC01_isVisible_isPublished_changeNotified` 锁定 `receivedValues.count == 2` + 逐项断言，对 hide 顺序改动有 mutation 探针。
