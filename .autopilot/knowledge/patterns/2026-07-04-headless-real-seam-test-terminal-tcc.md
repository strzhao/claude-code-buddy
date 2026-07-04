# 测 GUI/TCC 代码的 mock 盲区：XCTest 经终端继承 TCC 驱动真实 seam（绕开 app 重打包）

<!-- tags: testing, mock-blind-spot, tcc, screencapturekit, headless-test, real-seam, terminal-tcc, gui-skip-test-mode, region-accuracy -->

**Scenario**: GUI / TCC-gated 代码常在 `present()` 用 `RuntimeEnvironment.isRunningTests` 跳过真实 NSPanel / 真实 SCScreenCapture 创建（避免测试 GUI 副作用）。结果：headless 测试全绿，真机却挂/错（多条真实路径 bug 测不出）。

**Lesson**: 对真实路径（真实屏幕捕获 / 真实 AnnotationKit 渲染 / 真实剪贴板），写一个 XCTest 用**真实生产 seam**（不注入 mock）驱动：测试进程经**终端**继承 TCC 授权（终端身份稳定，重编译 cdhash 不变 → 无 TCC 失效，可反复自跑），绕开 app 重打包 / 手动 GUI / TCC 重授权。覆盖 mock 测不到的真实 API 调用链 + 真实解码/渲染。**盲区**：区域准确性 / GUI 视觉 / 崩溃仍需真机视觉验（headless 测不了「捕获内容对不对」「NSPanel 崩不崩」，只能测「捕获成功 + 尺寸对」）。侦察清单：① 代码有 `isRunningTests` 跳过的真实路径 → 必须 headless 补真实 seam 测试 或 真机验；② 测试只断言「非空/尺寸」不断言「区域/内容」→ 真机视觉补区域准确性；③ 坐标系转换（CG top-left vs NSScreen bottom-left）+ 单位（points vs pixels）类 bug 区域准确性必真机验。

**Evidence**: apps/desktop/tests/.../ScreenshotRealCaptureTests.swift（真实 SCScreenCapture + AnnotationRenderer，headless 跑通 capture→decode→render）；但其中 4 个真机 bug（NSPanel init 崩 / sourceRect pixels-vs-points / sourceRect CG-top-left vs NSScreen-bottom-left Y 翻转 / defocus grace period）的「区域准确性」「GUI 崩」都是 headless 测不出、真机才暴露的。（核对锚点：2026-07-04 源码版本）

**关联**: 是 `autopilot-tier-green-not-bug-free`（用户记忆）+ [[2026-07-04-swift-async-sync-bridge-semaphore-mainactor-deadlock]]（nonisolated mock 盲区）+ `2026-07-01-command-dual-path` 同类「测试盲区」家族 —— 治本：真实 seam headless 测 + 真机视觉验区域/GUI。
