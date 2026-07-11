# stage-0 Handoff

## 实现摘要
SettingsTheme 扩展间距栅格：4 倍数 scale（spacingXs=4/sm=8/md=12/lg=16/xl=24/xxl=32/section=48）+ 布局常量（contentMaxWidth=780/sidebarWidth=200/pluginListWidth=240/minRowHeight=44/contentTopInset=48）+ 现有语义 token 值收口到 scale（语义名不变，调用方零改动：groupSpacing/groupTopInset 20→24，其余值不变）。

## 文件变更
- `Sources/ClaudeCodeBuddy/Settings/SettingsTheme.swift`（scale + 布局常量 + 语义 token 收口）
- `tests/BuddyCoreTests/Settings/SettingsThemeTests.swift`（追加 3 测试）
- `tests/BuddyCoreTests/Settings/SettingsThemeAcceptanceTests.swift`（红队 3 验收测试）
- commit：`27aef59`（蓝队实现）+ merge commit（红队测试）

## 下游须知（stage-1 ContentColumnView 及后续）
- 消费 `SettingsTheme.contentMaxWidth`(780) / `spacingXl`(24) / `spacingSection`(48) 做限宽居中 + 上下留白。
- **ContentColumnView 必须含 `documentView.heightAnchor.constraint(greaterThanOrEqualTo: scrollView.contentView.heightAnchor)`**（patterns/2026-07-03 防 NSScrollView 贴底空顶，plan Task 2 已落地 + 红队 test_documentView_fillsViewportHeight_noBottomAlign 守）。
- AX：ContentColumnView 透明容器不挂 id，调用方 child view 持 `settings.detail`（阶段 2 修订 3 处 AX id 复用到唯一）。

## 偏差说明
无。蓝红队均按 plan Task 1 执行，QA 全绿（红队 3 / 蓝队 18 / lint 0 / build OK）。
