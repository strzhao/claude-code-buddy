# stage-1 Handoff

## 实现摘要
新建 ContentColumnView（NSView 子类）：`NSScrollView`（撑满四边）→ `documentView`（宽度跟 contentView 只竖滚 + `height ≥ contentView.height` 防贴底盲区 patterns/2026-07-03）→ `contentColumn`（`width ≤ 780` + centerX 居中 + leading/trailing ≥ spacingXl(24)）。暴露 `scrollView`(let) / `contentColumn` / `maxWidth`(test seam)。AX 透明不挂 id。

## 文件变更
- `Sources/ClaudeCodeBuddy/Settings/Components/ContentColumnView.swift`（新建）
- `tests/BuddyCoreTests/Settings/ContentColumnViewTests.swift`（蓝队 5 测试）
- `tests/BuddyCoreTests/Settings/ContentColumnViewAcceptanceTests.swift`（红队 5 测试）
- commit：`106a936`（蓝队）+ merge commit（红队）

## 下游须知（stage-2 设置主体套地基）
- **ContentColumnView API**：`.contentColumn`（加内容进这里）/ `.scrollView`（let）/ `.maxWidth`（test seam，默认 780）。
- **接入方式**：单栏面板（General/About/Hotkey/Provider）整体包 ContentColumnView，内容加进 contentColumn；双栏（PluginGallery/snip）只包右栏；SkinGallery 不用（网格全宽）。
- **防贴底约束已内置**（documentView height ≥ contentView），蓝红双测试守，下游无需再处理。
- **AX**：ContentColumnView 不挂 id；**阶段 2 必做 AX 唯一性修订 3 处**（SettingsSplitVC:170→settings.detail.container / EmptyPluginStateVC:121→settings.plugin.empty / :160 child 保持 settings.detail）。

## 偏差说明
蓝队修正 plan 语法：`private(set) let contentColumn` → 裸 `let`（Swift 中 let 本身只读，private(set) 冗余致编译错；语义等价，@testable 可读）。无功能偏差，下游消费 `detailContainer = rightColumn.contentColumn` 不受影响。
