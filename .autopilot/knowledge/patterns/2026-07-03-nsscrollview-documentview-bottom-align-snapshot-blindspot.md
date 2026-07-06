# NSScrollView documentView 贴底对齐：隔离 snapshot 看不到，须 heightAnchor≥clipView + 真机验证

<!-- tags: appkit, nsscrollview, documentview, clipview, isflipped, autolayout, bottom-align, fill-viewport, plugin-gallery, settings, snapshot-blindspot, isolated-vs-embedded, real-app-verify, qa-tier1-5, plan-reviewer, prior-art, height-anchor -->

**Scenario**: 设置页「AI 配置」分页在大窗下内容跑到下半截、顶部空一大块；小窗下表单/JSON tab 被顶出可视区。`ProviderSettingsViewController` 用 NSScrollView 包裹一个普通 NSView（documentView，`isFlipped=false`），内容从 topAnchor 链式约束。**隔离 snapshot**（`assertSnapshot(of: vc.view, .image(size:))` 只渲染 scrollView 本体）显示内容贴顶、一切正常；但**真机**（scrollView 嵌入 splitView→window contentView 链后）内容贴**底**，顶部大留白。两者相反，隔离 snapshot 复现不了真机 bug。

**Lesson**:
- **根因**：NSScrollView 的 documentView 是非翻转坐标系（`isFlipped=false`）。当 documentView 的 fittingSize.height < clipView（可视区）高度时，Cocoa 默认把 documentView 顶到 clipView **底部**（非翻转坐标原点在左下）→ 视觉上"内容贴底、顶部空"。窗口越高，顶部留白越大；小窗内容超高时顶部（表单/JSON tab）被滚出可视区。
- **正解（同 repo 已验证先例）**：`PluginGalleryViewController.swift:195-197` 用同款模式修过同症状（原注释"内容少时撑满 viewport，顶部对齐，避免 cell 整体靠下"）——给 documentView 加 `heightAnchor.constraint(greaterThanOrEqualTo: scrollView.contentView.heightAnchor)`（撑满 viewport → 顶/底都贴 clipView → 内容从顶排布即视觉贴顶），配 `widthAnchor == scrollView.contentView.widthAnchor`。**不要**改 documentView 自身的 isFlipped（不影响它在 clipView 中的垂直对齐，AppKit 机制判定无效——本轮 plan-reviewer 初审 BLOCKER 即此，幸被审查拦下否则真机返工）。
- **隔离 snapshot 的盲区**：`assertSnapshot` 强制把 view 渲染到给定 size，documentView 在隔离环境下行为与"嵌入 window/splitView 链后"**不同**（嵌套链改变 clipView/documentView 的对齐上下文）。**隔离 snapshot 全绿 ≠ 真机正确**。涉及 scrollView/嵌套窗口的布局 bug 必须真机 build 验证（QA Tier 1.5），snapshot 只能做隔离回归基线。

**How to apply**:
- NSScrollView + 内容高度 < 可视区 → 内容贴底：加 `documentView.heightAnchor ≥ scrollView.contentView.heightAnchor`（先例 `PluginGalleryViewController:195-197` 逐字复制 + 注释引用先例）。
- 怀疑 scrollView/嵌套窗口布局 bug：**别只信隔离 snapshot**。`make run` 真机看，或 snapshot 整个 window/splitVC 层级而非裸 VC.view。涉及布局的诊断优先 `make run` 真机 + 用户验收（det-human 谓词），别靠裸 VC snapshot 下结论。
- 嵌套 scrollView（内层如 JSON 编辑器）"拉满不溢出"陷阱：固定 fraction（如 0.5×viewport）没扣掉 header/tab/工具区开销 → 总高超 viewport → 内层捕获滚动把 tab 顶飞。改用 **fill 布局**：工具区钉 container.bottom（required）+ C6 height ≥ viewport（required）+ 包裹层 NSStackView distribution=.fill → 内层填满"其余部分之外"的剩余空间，数学上必然不溢出。
- autopilot QA：det-machine（AX/test）覆盖不到的 det-human 布局项（如"内容贴顶"）必须用户真机验收；红队写 best-effort 约束存在性断言（如断言 heightAnchor≥clipView 约束存在）作降级守护。

**关联**: [[2026-06-28-settings-section-enum-extension-test-contract]]（同 Settings 子系统测试合约）、[[2026-04-19-lsuielement-nscollectionview-sendevent-click]]（LSUIElement 嵌套窗口交互同根因层）、[[2026-06-28-red-team-assertion-mechanism-precision]]（红队/验收机制精度），本轮 brainstorm `.autopilot/requirements/2026-07-02-设置页交互优化/`。
