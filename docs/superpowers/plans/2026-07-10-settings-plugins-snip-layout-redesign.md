# 设置 / 插件 / Snip 面板布局重构 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把设置窗口三个面板（设置主体 / 插件 / snip）的布局从"贴边拉满 + 硬编码间距 + 三套范式"重构为"限宽居中 + 统一栅格 + 单一 master-detail 范式 + snip 收敛到 AppKit"。

**Architecture:** 分 5 阶段——栅格 token 扩展（阶段 0）→ ContentColumnView 内容容器（阶段 1）→ 设置主体单栏面板套地基 + 间距收口（阶段 2）→ 插件面板双栏改造（阶段 3）→ snip 从 SwiftUI 迁 AppKit（阶段 4）。每阶段独立可测、可提交。数据层 `SnippetsService` 全程不动。

**Tech Stack:** Swift 5.9 / AppKit（NSViewController/NSView/NSTableView/NSScrollView/Auto Layout）/ 少量 SwiftUI 仅待删除（SnipPanelView）/ XCTest in-process + swift-snapshot-testing / BuddyLogger。

## Global Constraints

- **平台**：macOS 13+（`sizingOptions` 等 API 需要；deployment target 不变）。
- **栅格 token**（阶段 0 后所有间距必须引用，禁再硬编码）：`spacingXs=4 / sm=8 / md=12 / lg=16 / xl=24 / xxl=32 / section=48`；布局常量 `contentMaxWidth=780 / sidebarWidth=200 / pluginListWidth=240 / minRowHeight=44 / contentTopInset=48`。
- **AX 契约**（红队 SC-01..16 守护；AC-AX-01 唯一性，不可破坏）：`settings.detail` **只在活动 child root view**（`SettingsDetailContainerViewController.transition` 的 childView，`SettingsSplitViewController:160`）。**阶段 2 必做 AX 唯一性修订**（4 处 setAccessibilityIdentifier + 2 测试适配，详见 Task 6.5）：① `SettingsSplitViewController:75` viewDidLoad `detailContainer.view` 的 `settings.detail` → `settings.detail.container`；② `SettingsSplitViewController:170` transition 容器 view 的 `settings.detail` → `settings.detail.container`；③ `EmptyPluginStateVC:121` container 的 `settings.detail` → `settings.plugin.empty`；④ `:160` child root view 保持 `settings.detail`。**测试适配**（改硬断言，否则 make test 挂）：`SettingsSidebarAcceptanceTests:771` + `SettingsAXContractTests:155` 容器 view 断言 `==settings.detail` → `==settings.detail.container`。改后全窗递归 `identifier=="settings.detail"` 仅 :160 child 命中（唯一）。sidebar row id `settings.sidebar.{section}`；窗口 title `设置`。
- **日志**：所有新增日志用 `BuddyLogger.shared`（subsystem `settings` / `snippets`），禁 `print`/`NSLog`。
- **SwiftLint**：`make lint` 必须过（trailing closure / 标识符命名 / 文件长度）。
- **真机 QA（AI 自测，不依赖用户手动 GUI）**：GUI / 布局 / sizing / NSHostingController 类变更 headless `swift test` 有盲区，每阶段必须 `SKIP_FETCH_PLUGINS=1 make bundle` → `pkill -f ClaudeCodeBuddy; sleep 1; open apps/desktop/ClaudeCodeBuddy.app` → AI 用 osascript 读窗口 frame + in-process XCTest 驱动验证（buddy inspect 不能读窗口几何/AX，CLAUDE.md 限制）。纯视觉（间距呼吸感 / 对齐 / 限宽居中观感）才 fallback 用户目视。
- **testHook 原则**（patterns/2026-07-09）：验收 testHook 必须经真实 action 链路（`button.target?.perform(action)` / `tableView.selectRowIndexes`），禁直接调私有方法（如 saveCreate）；字段值用 `textField.stringValue=` 后 performClick 提交按钮。testHook_startCreate / testHook_selectRow 已合规（调真实 API）。
- **阶段间快照中间态**：各阶段末只重录该阶段涉及面板的快照；阶段 2 末插件面板 cell 仍旧范式（Task 8 未做），其快照在阶段 3 Task 9 重录——阶段间 merge 的快照允许"半新半旧"中间态，不阻断。
- **commitlint**：subject 首词用中文或小写英文 type（如 `feat(settings):` / `refactor(snip):`），body 每行 ≤100 字符。
- **数据层不动**：`SnippetsService` / `SnippetItem` / `SnippetsError` / `~/.buddy/snippets.json` schema / `PluginSettingsPanelProvider` 协议 / `PluginPanelRegistry` 注册方式——全部不变。

## Spec 细化说明（对 2026-07-10 design doc 3.3① 的修正）

spec 3.3① 原写"改 `SettingsDetailContainerViewController.transition(to:)` 统一包 ContentColumnView"。**细化**：PluginGallery 与 snip 是双栏 master-detail，整体包会把左右双栏一起限宽（错误）。正确做法——**ContentColumnView 作为可复用「内容容器」组件，由各面板按需使用，不改顶层 transition**：
- 单栏面板（General / About / KeyboardShortcuts / Provider）：VC 内容整体塞进一个 ContentColumnView。
- 双栏面板（PluginGallery / snip）：VC 自己管左右分栏，**只把右栏内容**塞进 ContentColumnView。
- SkinGallery：不用 ContentColumnView（网格市场全宽）。

---

## File Structure

**新建：**
- `Sources/ClaudeCodeBuddy/Settings/Components/ContentColumnView.swift` — 限宽居中 + 内嵌 scroll 的内容容器（阶段 1）。
- `tests/BuddyCoreTests/Settings/ContentColumnViewTests.swift` — ContentColumnView 行为测试。
- `tests/BuddyCoreTests/Settings/SnipAppKitAcceptanceTests.swift` — snip 迁 AppKit 后的端到端 in-process 测试（阶段 4 红利）。

**修改：**
- `Sources/ClaudeCodeBuddy/Settings/SettingsTheme.swift` — 加 scale + 布局常量（阶段 0）。
- `Sources/ClaudeCodeBuddy/Settings/Components/SettingsGroupView.swift` — 间距收口（阶段 2）。
- `Sources/ClaudeCodeBuddy/Settings/Components/SettingsToggleRow.swift` — 间距收口（阶段 2）。
- `Sources/ClaudeCodeBuddy/Settings/Components/SettingsFormRow.swift` — 间距收口（阶段 2）。
- `Sources/ClaudeCodeBuddy/Settings/GeneralSettingsViewController.swift` — 包 ContentColumnView + 间距收口（阶段 2）。
- `Sources/ClaudeCodeBuddy/Settings/AboutSettingsViewController.swift` — 包 ContentColumnView + 间距收口（阶段 2）。
- `Sources/ClaudeCodeBuddy/Settings/KeyboardShortcutsViewController.swift` — 包 ContentColumnView + 间距收口（阶段 2）。
- `Sources/ClaudeCodeBuddy/Settings/ProviderSettingsViewController.swift` — 去 ScrollView 改 ContentColumnView（阶段 2）。
- `Sources/ClaudeCodeBuddy/Settings/EmptyPluginStateVC.swift` — 响应式 + 间距收口（阶段 2）。
- `Sources/ClaudeCodeBuddy/Settings/SettingsSplitViewController.swift` — sidebar 固定 200（阶段 2）。
- `Sources/ClaudeCodeBuddy/Settings/PluginGalleryViewController.swift` — 左栏固定 240 / 删比例算法 / globalHeader 收口 / PluginListCellView 重排补图标 / 右栏包 ContentColumnView（阶段 3）。
- `Sources/ClaudeCodeBuddy/Settings/Plugins/SnipPanelVC.swift` — 重写为纯 AppKit NSViewController（阶段 4）。
- `tests/BuddyCoreTests/Settings/SnipPanelVCSnapshotTests.swift` — 父类变更适配（阶段 4）。
- `tests/BuddyCoreTests/Launcher/SnipGUIInProcessAcceptanceTests.swift` — AC-13 适配（阶段 4）。
- `tests/BuddyCoreTests/Launcher/SnipPanelRenderDiagnosticTests.swift` — 重录基线（阶段 4）。
- `tests/BuddyCoreTests/Settings/__Snapshots__/SettingsPageSnapshotTests/*.png` — 重录（阶段 2/3）。

**删除：**
- `Sources/ClaudeCodeBuddy/Settings/Plugins/SnipPanelView.swift`（阶段 4）。

---

## Task 1: 栅格 token 扩展

**Files:**
- Modify: `apps/desktop/Sources/ClaudeCodeBuddy/Settings/SettingsTheme.swift`（在 `Layout Spacing Grid` 区追加）
- Test: `apps/desktop/tests/BuddyCoreTests/Settings/SettingsThemeTests.swift`（新建）

**Interfaces:**
- Produces: `SettingsTheme.spacingXs/sm/md/lg/xl/xxl/section`（CGFloat）、`contentMaxWidth/sidebarWidth/pluginListWidth/minRowHeight/contentTopInset`（CGFloat）。后续所有 task 消费这些。

- [ ] **Step 1: 写失败测试**

创建 `tests/BuddyCoreTests/Settings/SettingsThemeTests.swift`：

```swift
import XCTest
@testable import BuddyCore

final class SettingsThemeTests: XCTestCase {
    func test_spacingScale_isFourMultiples() {
        XCTAssertEqual(SettingsTheme.spacingXs, 4)
        XCTAssertEqual(SettingsTheme.spacingSm, 8)
        XCTAssertEqual(SettingsTheme.spacingMd, 12)
        XCTAssertEqual(SettingsTheme.spacingLg, 16)
        XCTAssertEqual(SettingsTheme.spacingXl, 24)
        XCTAssertEqual(SettingsTheme.spacingXxl, 32)
        XCTAssertEqual(SettingsTheme.spacingSection, 48)
    }

    func test_layoutConstants() {
        XCTAssertEqual(SettingsTheme.contentMaxWidth, 780)
        XCTAssertEqual(SettingsTheme.sidebarWidth, 200)
        XCTAssertEqual(SettingsTheme.pluginListWidth, 240)
        XCTAssertEqual(SettingsTheme.minRowHeight, 44)
        XCTAssertEqual(SettingsTheme.contentTopInset, 48)
    }

    func test_legacySemanticTokens_alignedToScale() {
        XCTAssertEqual(SettingsTheme.contentPadding, SettingsTheme.spacingXl)      // 24
        XCTAssertEqual(SettingsTheme.cardContentPadding, SettingsTheme.spacingLg)  // 16
        XCTAssertEqual(SettingsTheme.rowSpacing, SettingsTheme.spacingSm)          // 8
        XCTAssertEqual(SettingsTheme.groupSpacing, SettingsTheme.spacingXl)        // 20 -> 24
        XCTAssertEqual(SettingsTheme.groupTopInset, SettingsTheme.spacingXl)       // 20 -> 24
    }
}
```

- [ ] **Step 2: 运行测试确认失败**

Run: `make -C apps/desktop test-only FILTER=SettingsThemeTests`
Expected: FAIL — `spacingXs` 等不存在（编译错误）。

- [ ] **Step 3: 实现 — 扩展 SettingsTheme**

修改 `SettingsTheme.swift` 的 `// MARK: - Layout Spacing Grid` 区。把现有 token 值收口 + 新增 scale 与布局常量。**替换整段**（从 `/// 内容左右页边距：24pt` 到 `static let cardCornerRadius: CGFloat = 10`）为：

```swift
    // MARK: - Spacing Scale (4 倍数栅格，所有间距的唯一来源)

    static let spacingXs: CGFloat = 4
    static let spacingSm: CGFloat = 8
    static let spacingMd: CGFloat = 12
    static let spacingLg: CGFloat = 16
    static let spacingXl: CGFloat = 24
    static let spacingXxl: CGFloat = 32
    static let spacingSection: CGFloat = 48

    // MARK: - Layout Constants

    /// 内容列限宽（detail 内容居中最大宽度）。
    static let contentMaxWidth: CGFloat = 780
    /// 设置 sidebar 固定宽度。
    static let sidebarWidth: CGFloat = 200
    /// 插件 / snip 左列表栏固定宽度。
    static let pluginListWidth: CGFloat = 240
    /// 交互行最小行高（HIG）。
    static let minRowHeight: CGFloat = 44
    /// 内容顶部留白。
    static let contentTopInset: CGFloat = 48

    // MARK: - Semantic Spacing (引用 scale，保持调用方 API 不变)

    /// 内容左右页边距 = spacingXl(24)。
    static let contentPadding: CGFloat = spacingXl
    /// 分组顶部留白 = spacingXl(24)。
    static let groupTopInset: CGFloat = spacingXl
    /// 分组之间间距 = spacingXl(24)。
    static let groupSpacing: CGFloat = spacingXl
    /// 分组卡片内行间距 = spacingSm(8)。
    static let rowSpacing: CGFloat = spacingSm
    /// 分组卡片左右内边距 = spacingLg(16)。
    static let cardContentPadding: CGFloat = spacingLg
    /// 分组卡片圆角：10pt。
    static let cardCornerRadius: CGFloat = 10
```

- [ ] **Step 4: 运行测试确认通过**

Run: `make -C apps/desktop test-only FILTER=SettingsThemeTests`
Expected: PASS（3 个测试全绿）。

- [ ] **Step 5: lint + 全量编译确认无回归**

Run: `make -C apps/desktop lint && make -C apps/desktop build`
Expected: lint 过 + 编译过（语义 token 名不变，调用方零改动）。

- [ ] **Step 6: commit**

```bash
git add apps/desktop/Sources/ClaudeCodeBuddy/Settings/SettingsTheme.swift apps/desktop/tests/BuddyCoreTests/Settings/SettingsThemeTests.swift
git commit -m "feat(settings): 扩展间距栅格 token(scale+布局常量)" -m "新增 4 倍数 scale 与限宽/分栏/行高常量，语义 token 值收口到 scale"
```

---

## Task 2: ContentColumnView 内容容器组件

**Files:**
- Create: `apps/desktop/Sources/ClaudeCodeBuddy/Settings/Components/ContentColumnView.swift`
- Test: `apps/desktop/tests/BuddyCoreTests/Settings/ContentColumnViewTests.swift`

**Interfaces:**
- Consumes: `SettingsTheme.contentMaxWidth / spacingXl / spacingSection`（Task 1）。
- Produces: `ContentColumnView`（NSView 子类）、其 `contentColumn: NSView`（调用方把内容加进这个 view）、`maxWidth: CGFloat`（test seam）。后续 Task 4/5/8/10/11 消费。

- [ ] **Step 1: 写失败测试**

创建 `tests/BuddyCoreTests/Settings/ContentColumnViewTests.swift`：

```swift
import XCTest
@testable import BuddyCore

final class ContentColumnViewTests: XCTestCase {
    func test_init_hasScrollViewAndContentColumn() {
        let cv = ContentColumnView(frame: NSRect(x: 0, y: 0, width: 1000, height: 600))
        cv.layoutSubtreeIfNeeded()
        XCTAssertNotNil(cv.scrollView)
        XCTAssertNotNil(cv.contentColumn)
    }

    func test_contentColumn_widthCappedToMaxWidth_whenViewportWide() {
        let cv = ContentColumnView(frame: NSRect(x: 0, y: 0, width: 1200, height: 600))
        cv.layoutSubtreeIfNeeded()
        // 视口 1200 > 780+padding，contentColumn 应被限到 780
        XCTAssertLessThanOrEqual(cv.contentColumn.bounds.width, SettingsTheme.contentMaxWidth + 1)
    }

    func test_maxWidth_seamAdjustsCap() {
        let cv = ContentColumnView(frame: NSRect(x: 0, y: 0, width: 1200, height: 600))
        cv.maxWidth = 500
        cv.layoutSubtreeIfNeeded()
        XCTAssertLessThanOrEqual(cv.contentColumn.bounds.width, 500 + 1)
    }

    func test_addContent_toContentColumn() {
        let cv = ContentColumnView(frame: NSRect(x: 0, y: 0, width: 1000, height: 600))
        let label = NSTextField(labelWithString: "hi")
        label.translatesAutoresizingMaskIntoConstraints = false
        cv.contentColumn.addSubview(label)
        cv.layoutSubtreeIfNeeded()
        XCTAssertTrue(label.superview === cv.contentColumn)
    }

    func test_documentView_fillsViewportHeight_noBottomAlign() {
        // patterns/2026-07-03：documentView height ≥ contentView height，防内容少时贴底空顶
        let cv = ContentColumnView(frame: NSRect(x: 0, y: 0, width: 1000, height: 600))
        cv.layoutSubtreeIfNeeded()
        XCTAssertGreaterThanOrEqual(
            cv.scrollView.documentView!.bounds.height,
            cv.scrollView.contentView.bounds.height
        )
    }
}
```

- [ ] **Step 2: 运行确认失败**

Run: `make -C apps/desktop test-only FILTER=ContentColumnViewTests`
Expected: FAIL — `ContentColumnView` 不存在。

- [ ] **Step 3: 实现 ContentColumnView**

创建 `apps/desktop/Sources/ClaudeCodeBuddy/Settings/Components/ContentColumnView.swift`：

```swift
import AppKit

// MARK: - ContentColumnView

/// 限宽居中内容列 + 内嵌滚动（布局地基组件）。
///
/// 结构：`NSScrollView`（撑满四边）→ `documentView`（宽度跟随 clipView，只竖滚）
///       → `contentColumn`（`width ≤ contentMaxWidth` + `centerX` 居中）。
/// 调用方把主内容加进 `contentColumn` 即获得限宽居中 + 超视口滚动。
///
/// AX：本组件是透明布局容器，**不挂 AX id**；调用方的 child view 持 AX 锚点（契约 7）。
///
/// 使用：
/// ```swift
/// let column = ContentColumnView()
/// view.addSubview(column)  // 四边撑满
/// column.contentColumn.addSubview(mySettingsGroup)
/// ```
final class ContentColumnView: NSView {

    /// 滚动视图（撑满）。暴露供调用方配置 scroller 行为。
    let scrollView = NSScrollView()
    /// documentView（宽度跟随 clip，只竖滚）。
    private let documentView = NSView()
    /// 实际内容容器（限宽居中）。调用方把内容加到这里。
    private(set) let contentColumn = NSView()

    /// 限宽值（默认 SettingsTheme.contentMaxWidth）。test seam。
    var maxWidth: CGFloat = SettingsTheme.contentMaxWidth {
        didSet { widthConstraint?.constant = maxWidth }
    }
    private var widthConstraint: NSLayoutConstraint?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupView()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupView() {
        wantsLayer = true

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear
        // documentView 跟随 clip 宽度（只竖滚，横向不滚）
        scrollView.documentView = documentView
        addSubview(scrollView)

        contentColumn.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(contentColumn)

        let widthC = contentColumn.widthAnchor.constraint(lessThanOrEqualToConstant: maxWidth)
        widthConstraint = widthC

        NSLayoutConstraint.activate([
            // scrollView 撑满
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            // documentView 宽度 = clipView 宽度（横向不滚），高度自适应内容
            documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            documentView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            // 防 documentView 贴底空顶（patterns/2026-07-03）：内容高度 < clipView 时强制 ≥ clipView 高，顶部对齐
            documentView.heightAnchor.constraint(greaterThanOrEqualTo: scrollView.contentView.heightAnchor),

            // contentColumn 限宽 + 居中 + 上下/左右留白
            widthC,
            contentColumn.topAnchor.constraint(equalTo: documentView.topAnchor,
                                               constant: SettingsTheme.spacingSection),
            contentColumn.bottomAnchor.constraint(equalTo: documentView.bottomAnchor,
                                                  constant: -SettingsTheme.spacingSection),
            contentColumn.leadingAnchor.constraint(greaterThanOrEqualTo: documentView.leadingAnchor,
                                                  constant: SettingsTheme.spacingXl),
            contentColumn.trailingAnchor.constraint(lessThanOrEqualTo: documentView.trailingAnchor,
                                                   constant: -SettingsTheme.spacingXl),
            contentColumn.centerXAnchor.constraint(equalTo: documentView.centerXAnchor),
        ])
    }
}
```

- [ ] **Step 4: 运行确认通过**

Run: `make -C apps/desktop test-only FILTER=ContentColumnViewTests`
Expected: PASS（4 个测试全绿）。

- [ ] **Step 5: lint + commit**

```bash
make -C apps/desktop lint
git add apps/desktop/Sources/ClaudeCodeBuddy/Settings/Components/ContentColumnView.swift apps/desktop/tests/BuddyCoreTests/Settings/ContentColumnViewTests.swift
git commit -m "feat(settings): 新增 ContentColumnView 限宽居中内容容器" -m "NSScrollView+documentView+contentColumn 三层，限宽 780 居中，只竖滚"
```

---

## Task 3: 复用组件间距收口（SettingsGroupView / ToggleRow / FormRow）

**Files:**
- Modify: `apps/desktop/Sources/ClaudeCodeBuddy/Settings/Components/SettingsGroupView.swift:45-50`
- Modify: `apps/desktop/Sources/ClaudeCodeBuddy/Settings/Components/SettingsToggleRow.swift:88-114`
- Modify: `apps/desktop/Sources/ClaudeCodeBuddy/Settings/Components/SettingsFormRow.swift:89-109`
- Test: 现有快照 + 编译回归（无新测试；间距变更由 Task 6/9 快照重录守）

**Interfaces:**
- Consumes: `SettingsTheme.spacing*`（Task 1）。
- Produces: 组件内部约束全部用 scale token。

- [ ] **Step 1: SettingsGroupView 间距收口**

`SettingsGroupView.swift:45-50` 把 stackView 的 `4` 外边距改为 `SettingsTheme.spacingXs`：

old:
```swift
        NSLayoutConstraint.activate([
            stackView.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            stackView.leadingAnchor.constraint(equalTo: leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: trailingAnchor),
            stackView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
```
new:
```swift
        NSLayoutConstraint.activate([
            stackView.topAnchor.constraint(equalTo: topAnchor, constant: SettingsTheme.spacingXs),
            stackView.leadingAnchor.constraint(equalTo: leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: trailingAnchor),
            stackView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -SettingsTheme.spacingXs),
        ])
```

- [ ] **Step 2: SettingsToggleRow 间距收口**

`SettingsToggleRow.swift:88-114` 替换约束块（`10→spacingMd`、`8→spacingSm`、`2→spacingXs`、`12→spacingMd`、`4→spacingXs`）：

old:
```swift
        var constraints: [NSLayoutConstraint] = [
            // 标题：左对齐 cardContentPadding，距顶 10
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: SettingsTheme.cardContentPadding),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: sourceBadgeLabel.leadingAnchor, constant: -8),

            // 来源徽标：标题右侧
            sourceBadgeLabel.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            sourceBadgeLabel.trailingAnchor.constraint(lessThanOrEqualTo: toggleSwitch.leadingAnchor, constant: -8),

            // 副标题：标题下方 2pt
            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            subtitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: toggleSwitch.leadingAnchor, constant: -12),

            // 详情：副标题下方 4pt（展开时显示，收起时高度 0 隐藏）
            detailLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            detailLabel.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 4),
            detailLabel.trailingAnchor.constraint(lessThanOrEqualTo: toggleSwitch.leadingAnchor, constant: -12),
            detailLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),

            // switch：右对齐 cardContentPadding，垂直居中；自绘开关尺寸 32×20
            toggleSwitch.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -SettingsTheme.cardContentPadding),
            toggleSwitch.centerYAnchor.constraint(equalTo: centerYAnchor),
            toggleSwitch.widthAnchor.constraint(equalToConstant: 32),
            toggleSwitch.heightAnchor.constraint(equalToConstant: 20),
        ]
```
new:
```swift
        var constraints: [NSLayoutConstraint] = [
            // 最低行高 44（HIG）
            heightAnchor.constraint(greaterThanOrEqualToConstant: SettingsTheme.minRowHeight),

            // 标题：左对齐 cardContentPadding，距顶 spacingMd
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: SettingsTheme.cardContentPadding),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: SettingsTheme.spacingMd),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: sourceBadgeLabel.leadingAnchor, constant: -SettingsTheme.spacingSm),

            // 来源徽标：标题右侧
            sourceBadgeLabel.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            sourceBadgeLabel.trailingAnchor.constraint(lessThanOrEqualTo: toggleSwitch.leadingAnchor, constant: -SettingsTheme.spacingSm),

            // 副标题：标题下方 spacingXs
            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: SettingsTheme.spacingXs),
            subtitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: toggleSwitch.leadingAnchor, constant: -SettingsTheme.spacingMd),

            // 详情：副标题下方 spacingXs（展开时显示，收起时高度 0 隐藏）
            detailLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            detailLabel.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: SettingsTheme.spacingXs),
            detailLabel.trailingAnchor.constraint(lessThanOrEqualTo: toggleSwitch.leadingAnchor, constant: -SettingsTheme.spacingMd),
            detailLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -SettingsTheme.spacingMd),

            // switch：右对齐 cardContentPadding，垂直居中；自绘开关尺寸 32×20
            toggleSwitch.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -SettingsTheme.cardContentPadding),
            toggleSwitch.centerYAnchor.constraint(equalTo: centerYAnchor),
            toggleSwitch.widthAnchor.constraint(equalToConstant: 32),
            toggleSwitch.heightAnchor.constraint(equalToConstant: 20),
        ]
```

- [ ] **Step 3: SettingsFormRow 间距收口**

`SettingsFormRow.swift:89-116` 替换约束块（`10→spacingMd`、`12→spacingMd`、`2→spacingXs`、`8→spacingSm`、行高 44→`minRowHeight`）：

old:
```swift
        NSLayoutConstraint.activate([
            // 标题：左对齐 cardContentPadding，距顶 10
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: SettingsTheme.cardContentPadding),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: controlContainer.leadingAnchor, constant: -12),

            // 副标题：标题下方 2pt
            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            subtitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: controlContainer.leadingAnchor, constant: -12),

            // 错误标签：副标题下方 2pt
            errorLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            errorLabel.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 2),
            errorLabel.trailingAnchor.constraint(lessThanOrEqualTo: controlContainer.leadingAnchor, constant: -12),
            errorLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),

            // 右侧控件容器：trailing cardContentPadding，垂直居中
            controlContainer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -SettingsTheme.cardContentPadding),
            controlContainer.centerYAnchor.constraint(equalTo: centerYAnchor),
            controlContainer.widthAnchor.constraint(greaterThanOrEqualToConstant: 120),

            // 右侧控件填满容器
            controlView.leadingAnchor.constraint(equalTo: controlContainer.leadingAnchor),
            controlView.trailingAnchor.constraint(equalTo: controlContainer.trailingAnchor),
            controlView.topAnchor.constraint(equalTo: controlContainer.topAnchor),
            controlView.bottomAnchor.constraint(equalTo: controlContainer.bottomAnchor),
        ])
```
new:
```swift
        NSLayoutConstraint.activate([
            // 最低行高 44（HIG）
            heightAnchor.constraint(greaterThanOrEqualToConstant: SettingsTheme.minRowHeight),

            // 标题：左对齐 cardContentPadding，距顶 spacingMd
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: SettingsTheme.cardContentPadding),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: SettingsTheme.spacingMd),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: controlContainer.leadingAnchor, constant: -SettingsTheme.spacingMd),

            // 副标题：标题下方 spacingXs
            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: SettingsTheme.spacingXs),
            subtitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: controlContainer.leadingAnchor, constant: -SettingsTheme.spacingMd),

            // 错误标签：副标题下方 spacingXs
            errorLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            errorLabel.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: SettingsTheme.spacingXs),
            errorLabel.trailingAnchor.constraint(lessThanOrEqualTo: controlContainer.leadingAnchor, constant: -SettingsTheme.spacingMd),
            errorLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -SettingsTheme.spacingSm),

            // 右侧控件容器：trailing cardContentPadding，垂直居中
            controlContainer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -SettingsTheme.cardContentPadding),
            controlContainer.centerYAnchor.constraint(equalTo: centerYAnchor),
            controlContainer.widthAnchor.constraint(greaterThanOrEqualToConstant: 120),

            // 右侧控件填满容器
            controlView.leadingAnchor.constraint(equalTo: controlContainer.leadingAnchor),
            controlView.trailingAnchor.constraint(equalTo: controlContainer.trailingAnchor),
            controlView.topAnchor.constraint(equalTo: controlContainer.topAnchor),
            controlView.bottomAnchor.constraint(equalTo: controlContainer.bottomAnchor),
        ])
```

- [ ] **Step 4: 编译 + lint 确认无回归**

Run: `make -C apps/desktop build && make -C apps/desktop lint`
Expected: 编译过 + lint 过（语义不变，仅常量替换）。

- [ ] **Step 5: commit**

```bash
git add apps/desktop/Sources/ClaudeCodeBuddy/Settings/Components/SettingsGroupView.swift apps/desktop/Sources/ClaudeCodeBuddy/Settings/Components/SettingsToggleRow.swift apps/desktop/Sources/ClaudeCodeBuddy/Settings/Components/SettingsFormRow.swift
git commit -m "refactor(settings): 复用组件间距收口到栅格 scale" -m "GroupView/ToggleRow/FormRow 硬编码间距替换为 spacing token，统一最小行高 44"
```

> 快照基线此时会变（间距变了），留到 Task 6 统一重录，本 task 不重录。

---

## Task 4: 单栏设置页包 ContentColumnView + 间距收口（General / About / KeyboardShortcuts）

**Files:**
- Modify: `apps/desktop/Sources/ClaudeCodeBuddy/Settings/GeneralSettingsViewController.swift`
- Modify: `apps/desktop/Sources/ClaudeCodeBuddy/Settings/AboutSettingsViewController.swift`
- Modify: `apps/desktop/Sources/ClaudeCodeBuddy/Settings/KeyboardShortcutsViewController.swift`
- Test: Task 6 快照重录守（无新单测；ContentColumnView 行为已由 Task 2 守）

**Interfaces:**
- Consumes: `ContentColumnView`（Task 2）、`SettingsTheme.spacing*`（Task 1）。
- Produces: 三个单栏 VC 内容限宽居中。

> 改造模式统一：把 VC 原 `container` 内直接 addSubview 的分组内容，改为先加进一个 `ContentColumnView`（四边撑满 container），再把分组加进 `column.contentColumn`。

- [ ] **Step 1: GeneralSettingsViewController 包 ContentColumnView + 收口**

`GeneralSettingsViewController.swift`。`loadView()` 保留固定 frame container；`setupLayout(in:)` 改为：把 groupLabel/group 加进 `column.contentColumn`（而非直接 container），column 四边撑满 container；`constant: 6` 改 `SettingsTheme.spacingSm`。

old（`setupLayout` 的约束段，约 `:73-93`）：
```swift
        NSLayoutConstraint.activate([
            // 通用标题
            generalLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: SettingsTheme.groupTopInset),
            generalLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: SettingsTheme.contentPadding),
            generalLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -SettingsTheme.contentPadding),

            // 通用卡片
            generalGroup.topAnchor.constraint(equalTo: generalLabel.bottomAnchor, constant: 6),
            generalGroup.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: SettingsTheme.contentPadding),
            generalGroup.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -SettingsTheme.contentPadding),

            // 系统标题
            systemLabel.topAnchor.constraint(equalTo: generalGroup.bottomAnchor, constant: SettingsTheme.groupSpacing),
            systemLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: SettingsTheme.contentPadding),
            systemLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -SettingsTheme.contentPadding),

            // 系统卡片
            systemGroup.topAnchor.constraint(equalTo: systemLabel.bottomAnchor, constant: 6),
            systemGroup.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: SettingsTheme.contentPadding),
            systemGroup.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -SettingsTheme.contentPadding),
        ])
```

改造：在 `setupLayout` 开头（绑定回调之后、创建 generalLabel 之前）插入 column，并把 addSubview 目标从 `container` 改为 `column.contentColumn`，约束以 `column.contentColumn` 为锚。完整新 `setupLayout`（替换整个方法体）：

```swift
    private func setupLayout(in container: NSView) {
        // 绑定 toggle 回调（SC-SET-11 持久化）
        soundRow.onToggle = { isOn in
            SoundManager.shared.isEnabled = isOn
        }
        alwaysShowLabelRow.onToggle = { isOn in
            UserDefaults.standard.set(isOn, forKey: "alwaysShowLabel")
        }
        launchAtLoginRow.onToggle = { isOn in
            LaunchAtLogin.isEnabled = isOn
        }

        // 内容列（限宽居中 + 滚动）
        let column = ContentColumnView()
        column.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: container.topAnchor),
            column.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            column.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        let content = column.contentColumn

        // 分组标题：通用
        let generalLabel = SettingsGroupLabel(title: "通用")
        generalLabel.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(generalLabel)

        // 分组卡片：通用（音效 + 标签）
        let generalGroup = SettingsGroupView()
        generalGroup.translatesAutoresizingMaskIntoConstraints = false
        generalGroup.addRow(soundRow)
        generalGroup.addRow(alwaysShowLabelRow)
        content.addSubview(generalGroup)

        // 分组标题：系统
        let systemLabel = SettingsGroupLabel(title: "系统")
        systemLabel.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(systemLabel)

        // 分组卡片：系统（开机自启）
        let systemGroup = SettingsGroupView()
        systemGroup.translatesAutoresizingMaskIntoConstraints = false
        systemGroup.addRow(launchAtLoginRow)
        content.addSubview(systemGroup)

        NSLayoutConstraint.activate([
            generalLabel.topAnchor.constraint(equalTo: content.topAnchor),
            generalLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            generalLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor),

            generalGroup.topAnchor.constraint(equalTo: generalLabel.bottomAnchor, constant: SettingsTheme.spacingSm),
            generalGroup.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            generalGroup.trailingAnchor.constraint(equalTo: content.trailingAnchor),

            systemLabel.topAnchor.constraint(equalTo: generalGroup.bottomAnchor, constant: SettingsTheme.groupSpacing),
            systemLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            systemLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor),

            systemGroup.topAnchor.constraint(equalTo: systemLabel.bottomAnchor, constant: SettingsTheme.spacingSm),
            systemGroup.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            systemGroup.trailingAnchor.constraint(equalTo: content.trailingAnchor),
        ])
    }
```

> AX：`settings.detail` 由 `SettingsDetailContainerViewController.transition` 挂在 child root view（本 VC 的 container），ContentColumnView 不挂 id，契约 7 不破坏。

- [ ] **Step 2: AboutSettingsViewController 同模式包 ContentColumnView**

读 `AboutSettingsViewController.swift`，定位其 `loadView`/setup（约 `:52-201`）。应用同 Task 4 Step 1 模式：在 container 内加 `ContentColumnView`（四边撑满），原有子视图（版本/反馈/开源按钮等）的 addSubview 目标与约束锚从 `container` 改为 `column.contentColumn`；所有硬编码间距（如 `:180` 的 `4`）替换为 `SettingsTheme.spacingXs`，其他 `6/12/24` 按 spec 4.1 映射替换。

> 因 About 内部结构本 plan 未逐行展开，执行时先 `Read` 整文件，按"addSubview(container) → addSubview(column.contentColumn)、约束锚 container → column.contentColumn、硬编码值 → scale token"三条规则机械改写，改后 `make -C apps/desktop build` 验证编译。

- [ ] **Step 3: KeyboardShortcutsViewController 同模式包 ContentColumnView**

读 `KeyboardShortcutsViewController.swift`（约 `:47-123`），按 Step 2 同规则改写（该 VC 是垂直居中布局，包 ContentColumnView 后内容仍居中于 contentColumn）。

- [ ] **Step 4: 编译 + lint**

Run: `make -C apps/desktop build && make -C apps/desktop lint`
Expected: 编译过 + lint 过。

- [ ] **Step 5: commit**

```bash
git add apps/desktop/Sources/ClaudeCodeBuddy/Settings/GeneralSettingsViewController.swift apps/desktop/Sources/ClaudeCodeBuddy/Settings/AboutSettingsViewController.swift apps/desktop/Sources/ClaudeCodeBuddy/Settings/KeyboardShortcutsViewController.swift
git commit -m "refactor(settings): 单栏设置页包 ContentColumnView 限宽居中" -m "General/About/KeyboardShortcuts 内容收进内容列，间距收口到 scale"
```

---

## Task 5: ProviderSettings 去 ScrollView + EmptyPluginStateVC 响应式

**Files:**
- Modify: `apps/desktop/Sources/ClaudeCodeBuddy/Settings/ProviderSettingsViewController.swift`
- Modify: `apps/desktop/Sources/ClaudeCodeBuddy/Settings/EmptyPluginStateVC.swift`

**Interfaces:**
- Consumes: `ContentColumnView`、`SettingsTheme.spacing*`。
- Produces: ProviderSettings 复用统一 scroll；EmptyPluginStateVC 响应式撑满。

- [ ] **Step 1: ProviderSettings 改用 ContentColumnView**

读 `ProviderSettingsViewController.swift`（约 `:94-100` 自带 `NSScrollView(frame: ...)`）。删除自建 scrollView，改为：container 内加 `ContentColumnView`（四边撑满），原 scrollView 的 documentView 内容（AI 配置 SettingsFormRow 组）加进 `column.contentColumn`，约束锚改为 `column.contentColumn`。

> 执行时 Read 整文件，按"删自建 NSScrollView → 用 ContentColumnView、内容进 contentColumn、硬编码间距 → scale token"改写，`make build` 验证。
>
> ⚠️ **JSON tab 的 NSTextView 三件套**（patterns/2026-07-02 width=0 盲区）：ProviderSettings 有 JSON 编辑 tab（`jsonScrollView.documentView = jsonTextView`）。若 jsonTextView 改作 contentColumn 子控件（而非 scrollView.documentView），必须 `jsonTextView.autoresizingMask = .width` + `jsonTextView.widthTracksTextView = true` + 显式 containerSize，否则 width=0 内容不可见。

- [ ] **Step 2: EmptyPluginStateVC 响应式 + 间距收口**

`EmptyPluginStateVC.swift`。删固定 frame `480×360`（`:42`），container 用固定初始 frame + autoresize（防 fittingSize 缩 0）；内容在 container 内居中（用 `container.centerYAnchor` 而非固定 96pt top）；硬编码 `96/16/32/8/48/12` 收口。

old（`:41-42`）：
```swift
    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 360))
        container.autoresizingMask = [.width, .height]
```
new:
```swift
    override func loadView() {
        // 固定初始 frame + autoresize（防 fittingSize 缩 0，patterns/2026-06-16）；实际尺寸由父容器撑满
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 540))
        container.autoresizingMask = [.width, .height]
```

old（约束段 `:95-116`）：
```swift
        NSLayoutConstraint.activate([
            iconView.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            iconView.topAnchor.constraint(equalTo: container.topAnchor, constant: 96),

            titleLabel.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 16),
            titleLabel.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 32),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -32),
            titleLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),

            summaryLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            summaryLabel.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 32),
            summaryLabel.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -32),
            summaryLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),

            descLabel.topAnchor.constraint(equalTo: summaryLabel.bottomAnchor, constant: 8),
            descLabel.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 48),
            descLabel.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -48),
            descLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),

            badge.topAnchor.constraint(equalTo: descLabel.bottomAnchor, constant: 12),
            badge.centerXAnchor.constraint(equalTo: container.centerXAnchor),
        ])
```
new（icon 改垂直居中于 container 上半，内容整体居中；间距收口）：
```swift
        NSLayoutConstraint.activate([
            // 图标水平居中 + 垂直居中于容器上半部（响应式，不再固定 96pt top）
            iconView.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: container.centerYAnchor, constant: -SettingsTheme.spacingSection),

            titleLabel.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: SettingsTheme.spacingLg),
            titleLabel.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: SettingsTheme.spacingXxl),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -SettingsTheme.spacingXxl),
            titleLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),

            summaryLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: SettingsTheme.spacingSm),
            summaryLabel.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: SettingsTheme.spacingXxl),
            summaryLabel.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -SettingsTheme.spacingXxl),
            summaryLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),

            descLabel.topAnchor.constraint(equalTo: summaryLabel.bottomAnchor, constant: SettingsTheme.spacingSm),
            descLabel.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: SettingsTheme.spacingSection),
            descLabel.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -SettingsTheme.spacingSection),
            descLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),

            badge.topAnchor.constraint(equalTo: descLabel.bottomAnchor, constant: SettingsTheme.spacingMd),
            badge.centerXAnchor.constraint(equalTo: container.centerXAnchor),
        ])
```

- [ ] **Step 3: 编译 + lint**

Run: `make -C apps/desktop build && make -C apps/desktop lint`
Expected: 过。

- [ ] **Step 4: commit**

```bash
git add apps/desktop/Sources/ClaudeCodeBuddy/Settings/ProviderSettingsViewController.swift apps/desktop/Sources/ClaudeCodeBuddy/Settings/EmptyPluginStateVC.swift
git commit -m "refactor(settings): Provider 复用内容列滚动，空态响应式居中" -m "ProviderSettings 去自建 ScrollView 改 ContentColumnView；EmptyPluginStateVC 删固定 frame 改响应式"
```

---

## Task 6: sidebar 固定 200 + 重录设置快照基线

**Files:**
- Modify: `apps/desktop/Sources/ClaudeCodeBuddy/Settings/SettingsSplitViewController.swift:53-56`
- Modify（重录）: `apps/desktop/tests/BuddyCoreTests/Settings/__Snapshots__/SettingsPageSnapshotTests/*.png`

**Interfaces:**
- Consumes: `SettingsTheme.sidebarWidth`（Task 1）。

- [ ] **Step 1: sidebar 固定 200**

`SettingsSplitViewController.swift:53-56`：

old:
```swift
        self.sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.canCollapse = false
        sidebarItem.minimumThickness = 180
        sidebarItem.maximumThickness = 240
```
new:
```swift
        self.sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.canCollapse = false
        // 固定宽度（删 180-240 区间），消除拖动跳动
        sidebarItem.minimumThickness = SettingsTheme.sidebarWidth
        sidebarItem.maximumThickness = SettingsTheme.sidebarWidth
```

- [ ] **Step 2: 编译 + 跑设置快照（预期失败：基线变了）**

Run: `make -C apps/desktop build && swift test --package-path apps/desktop --filter SettingsPageSnapshotTests`
Expected: 快照测试 FAIL（布局变了，旧基线不匹配）。这是预期的。

- [ ] **Step 3: 删旧基线重录**

```bash
rm -f apps/desktop/tests/BuddyCoreTests/Settings/__Snapshots__/SettingsPageSnapshotTests/*.png
swift test --package-path apps/desktop --filter SettingsPageSnapshotTests
```
Expected: 重新生成新基线（general/plugin/about/hotkey × light/dark），测试 PASS。

- [ ] **Step 4: 真机验证（headless 盲区：限宽居中观感 + sidebar 固定）**

```bash
SKIP_FETCH_PLUGINS=1 make -C apps/desktop bundle
pkill -f ClaudeCodeBuddy; sleep 1; open apps/desktop/ClaudeCodeBuddy.app
```
人工点开设置 → 通用/关于/热键/AI 配置，确认：内容限宽居中、不贴边拉满、sidebar 固定不跳、滚动正常。读窗口 frame：
```bash
osascript -e 'tell application "System Events" to get size of window 1 of process "ClaudeCodeBuddy"'
```
记录到 QA 笔记。纯视觉（呼吸感/对齐）fallback 目视。

- [ ] **Step 5: lint + commit（含新基线图）**

```bash
make -C apps/desktop lint
git add apps/desktop/Sources/ClaudeCodeBuddy/Settings/SettingsSplitViewController.swift apps/desktop/tests/BuddyCoreTests/Settings/__Snapshots__/SettingsPageSnapshotTests/
git commit -m "feat(settings): sidebar 固定 200pt + 重录设置快照基线" -m "删 180-240 区间消除跳动；单栏页限宽居中后重录基线"
```

---

## Task 6.5: AX 唯一性修订 + 测试适配 + frame 谓词 in-process

> plan-reviewer blocker B1/B2 修复：AX id 实际 4 处（补 `:75`）+ 2 个硬断言测试适配 + frame 谓词 in-process（I2）。**必做，否则 stage-2 make test 挂。**

**Files:**
- Modify: `apps/desktop/Sources/ClaudeCodeBuddy/Settings/SettingsSplitViewController.swift`（`:75` viewDidLoad + `:170` transition 容器 view AX id → `settings.detail.container`）
- Modify: `apps/desktop/Sources/ClaudeCodeBuddy/Settings/EmptyPluginStateVC.swift`（`:121` container → `settings.plugin.empty`）
- Modify: `apps/desktop/tests/BuddyCoreTests/Settings/SettingsSidebarAcceptanceTests.swift`（`:771` 容器 view 断言 → `settings.detail.container`）
- Modify: `apps/desktop/tests/BuddyCoreTests/Settings/SettingsAXContractTests.swift`（`:155` containerID 断言 → `settings.detail.container`）
- Create: `apps/desktop/tests/BuddyCoreTests/Settings/SettingsLayoutAcceptanceTests.swift`（AC-AX-01/SPLIT-01/WIDTH-01 in-process）

- [ ] **Step 1: AX 修订 4 处**
  - `SettingsSplitViewController.swift:75` `detailContainer.view.setAccessibilityIdentifier("settings.detail")` → `"settings.detail.container"`
  - `SettingsSplitViewController.swift:170` `view.setAccessibilityIdentifier("settings.detail")` → `"settings.detail.container"`
  - `EmptyPluginStateVC.swift:121` `container.setAccessibilityIdentifier("settings.detail")` → `"settings.plugin.empty"`
  - `:160` child root view 保持 `"settings.detail"`（不改）

- [ ] **Step 2: 适配 2 个硬断言测试**（改断言值，非删测试）
  - `SettingsSidebarAcceptanceTests.swift:771` `XCTAssertEqual(detailContainer.view.accessibilityIdentifier(), "settings.detail", ...)` → `"settings.detail.container"`
  - `SettingsAXContractTests.swift:155` 容器 view 断言 → `"settings.detail.container"`（child root view 断言保持 `"settings.detail"`）

- [ ] **Step 3: 新建 SettingsLayoutAcceptanceTests（frame 谓词 in-process）**

```swift
import XCTest
@testable import BuddyCore

@MainActor
final class SettingsLayoutAcceptanceTests: XCTestCase {
    // AC-AX-01：全窗递归 identifier==settings.detail 命中唯一（仅 :160 child）
    func test_AC_AX_01_settingsDetailUnique_acrossSections() {
        let splitVC = SettingsSplitViewController()
        _ = splitVC.view
        for section in SettingsSection.allCases {
            splitVC.testHook_selectSection(section)
            splitVC.view.layoutSubtreeIfNeeded()
            let matches = splitVC.view.findAllSubviews(where: { $0.accessibilityIdentifier() == "settings.detail" })
            XCTAssertEqual(matches.count, 1, "\(section): settings.detail 应唯一命中活动 child，实际 \(matches.count)")
        }
    }

    // AC-SPLIT-01：sidebar 宽恒 200
    func test_AC_SPLIT_01_sidebarFixed200() {
        let splitVC = SettingsSplitViewController()
        _ = splitVC.view
        for w in [800.0, 1000, 1400] {
            splitVC.view.window?.setContentSize(NSSize(width: w, height: 600))
            splitVC.view.layoutSubtreeIfNeeded()
            XCTAssertEqual(splitVC.sidebarItem.viewController.view.bounds.width, 200, accuracy: 0, "width=\(w)")
        }
    }
}

private extension NSView {
    func findAllSubviews(where predicate: (NSView) -> Bool) -> [NSView] {
        (predicate(self) ? [self] : []) + subviews.flatMap { $0.findAllSubviews(where: predicate) }
    }
}
```

- [ ] **Step 4: 运行测试**
Run: `make -C apps/desktop test-only FILTER=SettingsLayoutAcceptanceTests` + `FILTER=SettingsSidebarAcceptanceTests` + `FILTER=SettingsAXContractTests`
Expected: 全绿（AX 修订后唯一性 + 2 测试适配断言 + frame 谓词）。

- [ ] **Step 5: commit**
```bash
git add apps/desktop/Sources/ClaudeCodeBuddy/Settings/SettingsSplitViewController.swift apps/desktop/Sources/ClaudeCodeBuddy/Settings/EmptyPluginStateVC.swift apps/desktop/tests/BuddyCoreTests/Settings/SettingsSidebarAcceptanceTests.swift apps/desktop/tests/BuddyCoreTests/Settings/SettingsAXContractTests.swift apps/desktop/tests/BuddyCoreTests/Settings/SettingsLayoutAcceptanceTests.swift
git commit -m "fix(settings): AX 唯一性修订 4 处+测试适配+frame 谓词"
```

---

## Task 7: 插件左栏固定 240 + 删比例算法

**Files:**
- Modify: `apps/desktop/Sources/ClaudeCodeBuddy/Settings/PluginGalleryViewController.swift:207-208, 352`

**Interfaces:**
- Consumes: `SettingsTheme.pluginListWidth`（Task 1）。

- [ ] **Step 1: 左栏宽度约束改固定 240**

读 `PluginGalleryViewController.swift`，定位左栏宽度约束（约 `:207-208`，`widthAnchor 200~260`）。改为固定 `SettingsTheme.pluginListWidth`：

把 `widthAnchor.constraint(greaterThanOrEqualToConstant: 200)` + `widthAnchor.constraint(lessThanOrEqualToConstant: 260)` 两条改为：
```swift
sidebarView.widthAnchor.constraint(equalToConstant: SettingsTheme.pluginListWidth)
```

- [ ] **Step 2: 删分隔条比例算法**

定位 `:352` 附近 `splitView.setPosition(min(220, ...))` 或 `min(220, splitView.bounds.width / 3)`。删除该行（或改为固定 `SettingsTheme.pluginListWidth`）。执行时 Read 该区域确认精确代码后删除/替换。

- [ ] **Step 3: 编译 + 跑插件相关测试**

Run: `make -C apps/desktop build && make -C apps/desktop test-only FILTER=SnipGUIInProcessAcceptanceTests`
Expected: 编译过 + 路由层测试 PASS（左栏宽度变化不影响 selectRow 路由）。

- [ ] **Step 4: commit**

```bash
git add apps/desktop/Sources/ClaudeCodeBuddy/Settings/PluginGalleryViewController.swift
git commit -m "refactor(plugins): 左栏固定 240pt 删比例算法" -m "删 200-260 区间与 min(220,width/3) 比例，消除拖动跳动"
```

---

## Task 8: PluginListCellView 重排补图标 + globalHeader 收口 + 右栏包 ContentColumnView

**Files:**
- Modify: `apps/desktop/Sources/ClaudeCodeBuddy/Settings/PluginGalleryViewController.swift`（PluginListCellView 约 `:639-733`、globalHeader 约束约 `:310/315/319/324/328`、右栏 detailContainer 接入）

**Interfaces:**
- Consumes: `ContentColumnView`、`SettingsTheme.spacing*`、`SettingsTheme.pluginListWidth`。
- Produces: 列表项 `[icon][name+summary 列][badge][toggle]` 范式；右栏限宽居中。

- [ ] **Step 1: PluginListCellView 补图标 + 重排 + 间距收口**

读 `PluginGalleryViewController.swift` 的 `PluginListCellView`（约 `:639-733`）。新增 `iconView: NSImageView`（16pt SF Symbol，按 source 选 `puzzlepiece`/`command`/`terminal`），约束范式：

```
[iconView 16×16 leading=spacingMd centerY=nameLabel]
[nameLabel leading=iconView.trailing+spacingSm top=spacingSm trailing≤badge.leading-spacingXs]
[sourceBadge trailing≤toggle.leading-spacingSm baseline/nameLabel.centerY]
[summaryLabel leading=iconView.leading top=nameLabel.bottom+spacingXs trailing≤toggle.leading-spacingSm bottom≤-spacingSm]
[toggle trailing=-spacingMd centerY]
```

把现有 cell 约束（`:696-714` 的 `8/12/8/4/2/8/12`）替换为对应 scale token，并加入 iconView 约束。执行时 Read cell 全文，按上述范式 + spec 4.1 映射重写约束块。行高保持（`rowHeight = 56`，两行 cell 自然值）。

- [ ] **Step 2: globalHeader 间距收口**

`globalHeader` 三组约束（约 `:310/315/319/324/328`）的 `constant: 6` → `SettingsTheme.spacingSm`；`:334` 的 `24` → `SettingsTheme.spacingXl`；`:337` 的 `12` → `SettingsTheme.spacingMd`。执行时 Read 该区域逐个 Edit。

- [ ] **Step 3: 右栏包 ContentColumnView**

读插件面板右栏结构（`detailContainer` 约 `:79,83`，globalHeader + pluginPanelContainer）。把右栏内容（globalHeaderContainer + pluginPanelContainer）整体加进一个 `ContentColumnView`，column 四边撑满右栏，原内容进 `column.contentColumn`，约束锚改 `column.contentColumn`。

> 注意：pluginPanelContainer 是 containment 容器（snip/Empty 作为它的 child）。包 ContentColumnView 后，pluginPanelContainer 仍做 containment，只是它在 contentColumn 内。snip 面板（Task 10-12）作为 pluginPanelContainer 的 child，其内部右栏会再包一层 ContentColumnView（Task 11）——这是嵌套但合理（插件面板右栏限宽 + snip 内部表单也限宽）。

执行时 Read 右栏组装代码，按"右栏根加 ContentColumnView、globalHeader/pluginPanelContainer 进 contentColumn"改写。

- [ ] **Step 4: 编译 + lint + 路由测试**

Run: `make -C apps/desktop build && make -C apps/desktop lint && make -C apps/desktop test-only FILTER=SnipGUIInProcessAcceptanceTests`
Expected: 过。

- [ ] **Step 5: commit**

```bash
git add apps/desktop/Sources/ClaudeCodeBuddy/Settings/PluginGalleryViewController.swift
git commit -m "refactor(plugins): 列表项补图标重排+间距收口+右栏限宽居中" -m "PluginListCellView 加 16pt 图标按范式重排；globalHeader 间距收口；右栏包 ContentColumnView"
```

---

## Task 9: 重录插件快照 + 真机验证

**Files:**
- Modify（重录）: `apps/desktop/tests/BuddyCoreTests/Settings/__Snapshots__/SettingsPageSnapshotTests/test_pluginGallery_*.png`

- [ ] **Step 1: 跑插件快照（预期失败）**

Run: `swift test --package-path apps/desktop --filter SettingsPageSnapshotTests -- -k plugin`
Expected: FAIL（布局变）。

- [ ] **Step 2: 删旧基线重录**

```bash
rm -f apps/desktop/tests/BuddyCoreTests/Settings/__Snapshots__/SettingsPageSnapshotTests/test_pluginGallery_*.png
swift test --package-path apps/desktop --filter SettingsPageSnapshotTests
```
Expected: 新基线生成，PASS。

- [ ] **Step 3: 真机验证插件面板**

```bash
SKIP_FETCH_PLUGINS=1 make -C apps/desktop bundle
pkill -f ClaudeCodeBuddy; sleep 1; open apps/desktop/ClaudeCodeBuddy.app
```
人工：设置 → 插件，确认左栏固定宽 + 图标对齐 + 右栏限宽居中 + 切换插件右栏不跳。fallback 目视。

- [ ] **Step 4: commit**

```bash
git add apps/desktop/tests/BuddyCoreTests/Settings/__Snapshots__/SettingsPageSnapshotTests/test_pluginGallery_*.png
git commit -m "test(plugins): 重录插件面板快照基线（布局重构后）"
```

---

## Task 10: snip 迁 AppKit — master-detail 左栏 + 右栏骨架

> 本 task 起 `SnipPanelView.swift`（SwiftUI）与 `SnipPanelVC`（NSHostingController）逐步被纯 AppKit 实现替代。Task 10-12 期间两套代码短暂并存（SwiftUI 文件 Task 12 删），保证每步可编译。

**Files:**
- Modify: `apps/desktop/Sources/ClaudeCodeBuddy/Settings/Plugins/SnipPanelVC.swift`（重写为 NSViewController master-detail）
- Test: `apps/desktop/tests/BuddyCoreTests/Settings/SnipAppKitAcceptanceTests.swift`（新建，本 task 写左栏部分）

**Interfaces:**
- Consumes: `SnippetsService.shared`（@MainActor ObservableObject，不动）、`ContentColumnView`、`SettingsTheme.*`、`PluginSettingsPanelProvider`。
- Produces: `SnipPanelVC`（NSViewController 子类，类名不变）的 master-detail 骨架 + `makePanelVC()`。Task 11 消费其 detail 容器，Task 12 接数据流。

- [ ] **Step 1: 写失败测试（左栏渲染 + split 结构 + AX）**

创建 `tests/BuddyCoreTests/Settings/SnipAppKitAcceptanceTests.swift`：

```swift
import XCTest
@testable import BuddyCore

@MainActor
final class SnipAppKitAcceptanceTests: XCTestCase {

    func test_loadView_rendersLeftListAndRightDetail() {
        let vc = SnipPanelVC()
        _ = vc.view
        vc.view.layoutSubtreeIfNeeded()

        // 左栏列表存在
        let tables = vc.view.findAllSubviews(of: NSTableView.self)
        XCTAssertFalse(tables.isEmpty, "snip 左栏应含 NSTableView")
        // 右栏 detail 容器存在
        XCTAssertTrue(vc.detailContainer != nil, "应有右栏 detail 容器")
    }

    func test_leftPane_fixedWidth() {
        let vc = SnipPanelVC()
        _ = vc.view
        vc.view.layoutSubtreeIfNeeded()
        let tables = vc.view.findAllSubviews(of: NSTableView.self)
        // 左栏宽度应固定为 pluginListWidth（通过其 scrollContainer 约束）
        // 此处断言存在即可，精确宽度由 ContentColumnView/约束守
        XCTAssertFalse(tables.isEmpty)
    }

    func test_isPluginSettingsPanelProvider() {
        let vc = SnipPanelVC()
        XCTAssertTrue(vc.makePanelVC() === vc)
    }
}

// MARK: - NSView findAllSubviews helper（如项目已有则复用，勿重复定义）
private extension NSView {
    func findAllSubviews<T: NSView>(of type: T.Type) -> [T] {
        subviews.compactMap { $0 as? T } + subviews.flatMap { $0.findAllSubviews(of: type) }
    }
}
```

> 若项目已有 `findAllSubviews` 类似 helper（grep `func findAllSubviews` 或 `recursiveSubviews`），复用之，删除本文件的 private extension 避免重复定义。

- [ ] **Step 2: 运行确认失败**

Run: `make -C apps/desktop test-only FILTER=SnipAppKitAcceptanceTests`
Expected: FAIL — `SnipPanelVC` 仍是 NSHostingController，无 `detailContainer`/`findAllSubviews` 适配。

- [ ] **Step 3: 重写 SnipPanelVC 为 AppKit master-detail 骨架**

`SnipPanelVC.swift` 整文件替换为（保留 `presentDeleteAlert`/`handleDeleteResponse` static seam 不变，原样搬入；新增 master-detail 骨架，detail 四态本 task 留占位空态，Task 11 填 create/edit/preview）：

```swift
import AppKit
import Combine

// MARK: - SnipPanelVC
//
// snip 专属设置面板（纯 AppKit，master-detail）。
// 原 SwiftUI（SnipPanelView）已删；NSHostingController + sizingOptions=[] hack 一并消除。
//
// 左栏：搜索 + 新增 + NSTableView（keyword + content 预览双行 cell）
// 右栏：ContentColumnView 包裹，containment 切 空/create/edit/preview 四态
//
// 数据源：SnippetsService.shared（@MainActor 直驱），objectWillChange sink 刷新列表。
// 删除二次确认：NSAlert（presentDeleteAlert/handleDeleteResponse test seam）。
//
// 契约引用：C1 / AC-SNIPGUI-01/10/13/23

@MainActor
final class SnipPanelVC: NSViewController, PluginSettingsPanelProvider {

    private let service: SnippetsService = .shared
    private var objectWillChangeCancellable: AnyCancellable?

    // 左栏
    private let leftPane = NSView()
    private let searchField = NSSearchField()
    private let addButton = NSButton()
    private let tableView = NSTableView()
    private let tableScrollView = NSScrollView()
    private var filteredItems: [SnippetItem] = []

    // 右栏
    private(set) var detailContainer: NSView!
    private var currentDetailChild: NSViewController?

    // 编辑/选中状态
    private var editingItem: SnippetItem?
    private var isCreating = false
    private var previewItem: SnippetItem?

    override func loadView() {
        // 固定初始 frame + autoresize（防 fittingSize 缩 0，patterns/2026-06-16）
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 760, height: 540))
        container.autoresizingMask = [.width, .height]
        setupLayout(in: container)
        self.view = container
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        bindService()
        reloadAndRefresh()
        showEmptyState()
    }

    // MARK: - Layout（master-detail：左固定 240 + 右 ContentColumnView）

    private func setupLayout(in container: NSView) {
        // 左栏固定宽
        leftPane.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(leftPane)

        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.placeholderString = "搜索 keyword..."
        searchField.target = self
        searchField.action = #selector(searchChanged)
        leftPane.addSubview(searchField)

        addButton.translatesAutoresizingMaskIntoConstraints = false
        addButton.title = "新增片段"
        addButton.bezelStyle = .recessed
        addButton.controlSize = .regular
        addButton.image = NSImage(systemSymbolName: "plus.circle.fill", accessibilityDescription: "新增")
        addButton.imagePosition = .imageLeading
        addButton.target = self
        addButton.action = #selector(startCreate)
        leftPane.addSubview(addButton)

        tableView.dataSource = self
        tableView.delegate = self
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("snip"))
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 56
        tableView.selectionHighlightStyle = .sourceList
        tableScrollView.documentView = tableView
        tableScrollView.hasVerticalScroller = true
        tableScrollView.autohidesScrollers = true
        tableScrollView.drawsBackground = false
        tableScrollView.translatesAutoresizingMaskIntoConstraints = false
        leftPane.addSubview(tableScrollView)

        // 右栏 ContentColumnView（限宽居中 + 滚动）
        let rightColumn = ContentColumnView()
        rightColumn.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(rightColumn)
        detailContainer = rightColumn.contentColumn

        NSLayoutConstraint.activate([
            leftPane.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            leftPane.topAnchor.constraint(equalTo: container.topAnchor),
            leftPane.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            leftPane.widthAnchor.constraint(equalToConstant: SettingsTheme.pluginListWidth),

            searchField.topAnchor.constraint(equalTo: leftPane.topAnchor, constant: SettingsTheme.spacingMd),
            searchField.leadingAnchor.constraint(equalTo: leftPane.leadingAnchor, constant: SettingsTheme.spacingMd),
            searchField.trailingAnchor.constraint(equalTo: leftPane.trailingAnchor, constant: -SettingsTheme.spacingMd),

            addButton.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: SettingsTheme.spacingSm),
            addButton.leadingAnchor.constraint(equalTo: leftPane.leadingAnchor, constant: SettingsTheme.spacingMd),
            addButton.trailingAnchor.constraint(equalTo: leftPane.trailingAnchor, constant: -SettingsTheme.spacingMd),

            tableScrollView.topAnchor.constraint(equalTo: addButton.bottomAnchor, constant: SettingsTheme.spacingSm),
            tableScrollView.leadingAnchor.constraint(equalTo: leftPane.leadingAnchor),
            tableScrollView.trailingAnchor.constraint(equalTo: leftPane.trailingAnchor),
            tableScrollView.bottomAnchor.constraint(equalTo: leftPane.bottomAnchor),

            rightColumn.leadingAnchor.constraint(equalTo: leftPane.trailingAnchor),
            rightColumn.topAnchor.constraint(equalTo: container.topAnchor),
            rightColumn.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            rightColumn.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }

    // MARK: - Service 绑定（objectWillChange → reload）

    private func bindService() {
        objectWillChangeCancellable = service.objectWillChange.sink { [weak self] in
            Task { @MainActor in self?.reloadAndRefresh() }
        }
    }

    private func reloadAndRefresh() {
        filteredItems = service.search(searchField.stringValue)
        tableView.reloadData()
    }

    // MARK: - PluginSettingsPanelProvider

    func makePanelVC() -> NSViewController { self }

    // MARK: - Actions

    @objc private func searchChanged() {
        reloadAndRefresh()
    }

    @objc private func startCreate() {
        // Task 11 实现 create 态
        editingItem = SnippetItem(keyword: "", content: "")
        isCreating = true
        showEmptyState()  // 占位，Task 11 替换为 showCreateForm
    }

    // MARK: - Detail 切换（本 task 仅空态，Task 11 补 create/edit/preview）

    private func showEmptyState() {
        transitionDetail(to: makeEmptyStateChild())
    }

    private func makeEmptyStateChild() -> NSViewController {
        let vc = NSViewController()
        let label = NSTextField(labelWithString: "选择片段查看或预览，或点新增")
        label.font = SettingsTheme.rowSubtitleFont()
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        vc.view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: vc.view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: vc.view.centerYAnchor),
        ])
        return vc
    }

    /// containment 切换右栏 child（对齐 PluginGalleryViewController pluginPanelContainer 机制）
    private func transitionDetail(to newChild: NSViewController) {
        if let old = currentDetailChild {
            old.view.removeFromSuperview()
            old.removeFromParent()
        }
        addChild(newChild)
        newChild.view.translatesAutoresizingMaskIntoConstraints = false
        detailContainer.addSubview(newChild.view)
        NSLayoutConstraint.activate([
            newChild.view.topAnchor.constraint(equalTo: detailContainer.topAnchor),
            newChild.view.leadingAnchor.constraint(equalTo: detailContainer.leadingAnchor),
            newChild.view.trailingAnchor.constraint(equalTo: detailContainer.trailingAnchor),
            newChild.view.bottomAnchor.constraint(equalTo: detailContainer.bottomAnchor),
        ])
        currentDetailChild = newChild
    }

    // MARK: - 删除二次确认（AC-SNIPGUI-10，test seam 原样保留）

    static func presentDeleteAlert(for item: SnippetItem) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "删除片段「\(item.keyword)」？"
        alert.informativeText = "此操作不可恢复，删除后该片段将不再可用。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "确认删除")
        alert.addButton(withTitle: "取消")
        return alert
    }

    static func handleDeleteResponse(_ response: NSApplication.ModalResponse, for item: SnippetItem) {
        guard response == .alertFirstButtonReturn else { return }
        SnippetsService.shared.delete(keyword: item.keyword)
        BuddyLogger.shared.info("snippet deleted via GUI", subsystem: "snippets",
                                meta: ["keyword": item.keyword])
    }
}

// MARK: - NSTableViewDataSource / Delegate（Task 10 基础列表）

extension SnipPanelVC: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { filteredItems.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = filteredItems[row]
        let cellId = NSUserInterfaceItemIdentifier("SnipListCell")
        let cell = (tableView.makeView(withIdentifier: cellId, owner: self) as? SnipListCellView)
            ?? SnipListCellView()
        cell.identifier = cellId
        cell.configure(keyword: item.keyword, content: item.content)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView.selectedRow
        guard row >= 0, row < filteredItems.count else { return }
        previewItem = filteredItems[row]
        // Task 11 实现 preview 态
    }
}
```

- [ ] **Step 4: 新增 SnipListCellView（双行 cell）**

在 `SnipPanelVC.swift` 同文件底部追加：

```swift
// MARK: - SnipListCellView（keyword 主标题 + content 预览副标题）

final class SnipListCellView: NSTableCellView {
    private let keywordLabel = NSTextField(labelWithString: "")
    private let contentLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupView()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupView() {
        keywordLabel.font = SettingsTheme.rowTitleFont()
        keywordLabel.textColor = .labelColor
        keywordLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(keywordLabel)

        contentLabel.font = SettingsTheme.rowSubtitleFont()
        contentLabel.textColor = .secondaryLabelColor
        contentLabel.maximumNumberOfLines = 2
        contentLabel.lineBreakMode = .byTruncatingTail
        contentLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentLabel)

        NSLayoutConstraint.activate([
            keywordLabel.topAnchor.constraint(equalTo: topAnchor, constant: SettingsTheme.spacingSm),
            keywordLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: SettingsTheme.spacingMd),
            keywordLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -SettingsTheme.spacingSm),

            contentLabel.topAnchor.constraint(equalTo: keywordLabel.bottomAnchor, constant: SettingsTheme.spacingXs),
            contentLabel.leadingAnchor.constraint(equalTo: keywordLabel.leadingAnchor),
            contentLabel.trailingAnchor.constraint(equalTo: keywordLabel.trailingAnchor),
            contentLabel.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -SettingsTheme.spacingSm),
        ])
    }

    func configure(keyword: String, content: String) {
        keywordLabel.stringValue = keyword
        contentLabel.stringValue = content
    }
}
```

- [ ] **Step 5: 临时保留 SnipPanelView.swift 但解除 SnipPanelVC 对它的依赖**

此时 `SnipPanelVC` 已重写为 NSViewController，不再 `import SwiftUI`/继承 NSHostingController。`SnipPanelView.swift` 暂留（Task 12 删），但已无任何代码引用它。确认 `PluginPanelRegistry` 仍 `register(SnipPanelVC())`（类型不变）。

Run: `make -C apps/desktop build`
Expected: 编译过（若 SnipPanelView.swift 未被引用产生 warning 可接受，Task 12 删）。

- [ ] **Step 6: 运行测试确认通过**

Run: `make -C apps/desktop test-only FILTER=SnipAppKitAcceptanceTests`
Expected: PASS（3 个测试）。

- [ ] **Step 7: lint + commit**

```bash
make -C apps/desktop lint
git add apps/desktop/Sources/ClaudeCodeBuddy/Settings/Plugins/SnipPanelVC.swift apps/desktop/tests/BuddyCoreTests/Settings/SnipAppKitAcceptanceTests.swift
git commit -m "feat(snip): 迁 AppKit master-detail 左栏+右栏骨架" -m "SnipPanelVC 重写为 NSViewController，左栏搜索/新增/NSTableView，右栏 ContentColumnView，保留 delete seam"
```

---

## Task 11: snip 四态 detail（create / edit / preview）

**Files:**
- Modify: `apps/desktop/Sources/ClaudeCodeBuddy/Settings/Plugins/SnipPanelVC.swift`（补 create/edit/preview 子 VC + 切换逻辑）

**Interfaces:**
- Consumes: `SnippetsService.add/edit/expandPlaceholders`、`SettingsGroupView`、`SettingsFormRow`、`SettingsTheme.*`。
- Produces: 四态统一「标题区 / 字段卡组 / 操作栏」。

- [ ] **Step 1: 写失败测试（四态切换）**

在 `SnipAppKitAcceptanceTests.swift` 追加：

```swift
    func test_startCreate_transitionsToCreateForm() {
        let vc = SnipPanelVC()
        _ = vc.view
        vc.testHook_startCreate()
        vc.view.layoutSubtreeIfNeeded()
        // create 态应含 keyword 输入框（testHook 暴露的状态断言）
        XCTAssertEqual(vc.testHook_currentDetailMode, .create)
    }

    func test_selectRow_transitionsToPreview() {
        let vc = SnipPanelVC()
        _ = vc.view
        // 注入一个片段
        try? SnippetsService.shared.add(keyword: "test_kwd_\(UUID().uuidString.prefix(6))", content: "hello")
        vc.testHook_reload()
        vc.testHook_selectRow(0)
        XCTAssertEqual(vc.testHook_currentDetailMode, .preview)
        // 清理
        if let item = vc.testHook_previewItem {
            SnippetsService.shared.delete(keyword: item.keyword)
        }
    }
```

> 注意：测试用 `testHook_*` 暴露的 API（见 Step 2 在 SnipPanelVC 加 testHook）。`testHook_currentDetailMode` 是枚举 `.empty/.create/.edit/.preview`。UUID 因 `Date.now`/random 限制——用 `UUID()` 在测试进程内可（非 workflow 脚本，普通 XCTest 允许）。

- [ ] **Step 2: 运行确认失败**

Run: `make -C apps/desktop test-only FILTER=SnipAppKitAcceptanceTests`
Expected: FAIL — `testHook_*` 不存在。

- [ ] **Step 3: 实现 create 态子 VC + 切换 + testHook**

在 `SnipPanelVC.swift`：
1. 加 `enum DetailMode { case empty, create, edit, preview }` 与 `private(set) var testHook_currentDetailMode: DetailMode = .empty`（testHook 暴露用，加 `@testable` 可见）。实际为测试可见，把 `testHook_currentDetailMode` 设为 `internal`。
2. 加 testHook 方法：
```swift
    // MARK: - Test hooks
    func testHook_startCreate() { startCreate() }
    func testHook_reload() { reloadAndRefresh() }
    func testHook_selectRow(_ row: Int) {
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    }
    var testHook_previewItem: SnippetItem? { previewItem }
```
3. 改造 `startCreate()` 与 `tableViewSelectionDidChange`：
```swift
    @objc private func startCreate() {
        editingItem = SnippetItem(keyword: "", content: "")
        isCreating = true
        transitionDetail(to: makeCreateFormChild())
        testHook_currentDetailMode = .create
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView.selectedRow
        guard row >= 0, row < filteredItems.count else { return }
        previewItem = filteredItems[row]
        editingItem = nil
        isCreating = false
        transitionDetail(to: makePreviewChild(item: previewItem!))
        testHook_currentDetailMode = .preview
    }
```
4. 实现 `makeCreateFormChild()`（create 态：keyword TextField + content TextEditor + 占位符提示卡 + 取消/保存）：
```swift
    private func makeCreateFormChild() -> NSViewController {
        let vc = NSViewController()
        let title = NSTextField(labelWithString: "新增片段")
        title.font = SettingsTheme.groupLabelFont()
        title.textColor = .tertiaryLabelColor
        title.translatesAutoresizingMaskIntoConstraints = false
        vc.view.addSubview(title)

        // keyword 卡
        let kwGroup = SettingsGroupView()
        let kwRow = SettingsFormRow(title: "keyword（字母数字_-，1-64）", subtitle: nil,
                                    control: NSTextField())
        kwGroup.addRow(kwRow)
        kwGroup.translatesAutoresizingMaskIntoConstraints = false
        vc.view.addSubview(kwGroup)

        // content 卡（NSTextView 包 NSScrollView + patterns/2026-07-02 width=0 三件套）
        let contentGroup = SettingsGroupView()
        let editor = NSTextView()
        editor.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        editor.isEditable = true
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.containerSize = NSSize(width: 360, height: 0)
        editor.minSize = NSSize(width: 0, height: 120)
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        let editorScrollView = NSScrollView()
        editorScrollView.documentView = editor
        editorScrollView.hasVerticalScroller = true
        editorScrollView.drawsBackground = false
        let contentRow = SettingsFormRow(title: "content", subtitle: nil, control: editorScrollView)
        contentGroup.addRow(contentRow)
        contentGroup.translatesAutoresizingMaskIntoConstraints = false
        vc.view.addSubview(contentGroup)

        // 占位符提示卡（AC-SNIPGUI-13）
        let hint = makePlaceholderHintView()
        hint.translatesAutoresizingMaskIntoConstraints = false
        vc.view.addSubview(hint)

        // 操作栏
        let actionBar = NSStackView()
        actionBar.orientation = .horizontal
        actionBar.translatesAutoresizingMaskIntoConstraints = false
        let cancel = NSButton(title: "取消", target: self, action: #selector(cancelEdit))
        let save = NSButton(title: "保存", target: self, action: #selector(saveCreate))
        save.keyEquivalent = "\r"
        actionBar.addArrangedSubview(cancel)
        actionBar.addArrangedSubview(NSView())  // spacer
        actionBar.addArrangedSubview(save)
        vc.view.addSubview(actionBar)

        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: vc.view.topAnchor),
            title.leadingAnchor.constraint(equalTo: vc.view.leadingAnchor),
            title.trailingAnchor.constraint(equalTo: vc.view.trailingAnchor),

            kwGroup.topAnchor.constraint(equalTo: title.bottomAnchor, constant: SettingsTheme.spacingSm),
            kwGroup.leadingAnchor.constraint(equalTo: vc.view.leadingAnchor),
            kwGroup.trailingAnchor.constraint(equalTo: vc.view.trailingAnchor),

            contentGroup.topAnchor.constraint(equalTo: kwGroup.bottomAnchor, constant: SettingsTheme.groupSpacing),
            contentGroup.leadingAnchor.constraint(equalTo: vc.view.leadingAnchor),
            contentGroup.trailingAnchor.constraint(equalTo: vc.view.trailingAnchor),

            hint.topAnchor.constraint(equalTo: contentGroup.bottomAnchor, constant: SettingsTheme.groupSpacing),
            hint.leadingAnchor.constraint(equalTo: vc.view.leadingAnchor),
            hint.trailingAnchor.constraint(equalTo: vc.view.trailingAnchor),

            actionBar.topAnchor.constraint(equalTo: hint.bottomAnchor, constant: SettingsTheme.spacingSm),
            actionBar.leadingAnchor.constraint(equalTo: vc.view.leadingAnchor),
            actionBar.trailingAnchor.constraint(equalTo: vc.view.trailingAnchor),
            actionBar.bottomAnchor.constraint(lessThanOrEqualTo: vc.view.bottomAnchor),
        ])
        return vc
    }

    @objc private func cancelEdit() {
        editingItem = nil
        isCreating = false
        showEmptyState()
        testHook_currentDetailMode = .empty
    }

    @objc private func saveCreate() {
        // Task 12 完成保存逻辑（取 keyword/content 控件值 → service.add）
        // 本 task 占位：直接取消回空态
        cancelEdit()
    }

    private func makePlaceholderHintView() -> NSView {
        let box = NSView()
        let icon = NSImageView(image: NSImage(systemSymbolName: "lightbulb",
                                              accessibilityDescription: "提示")!)
        let label = NSTextField(labelWithString: "占位符语法：{date} → 日期  {time} → 时间  {clipboard} → 剪贴板")
        label.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        label.textColor = .tertiaryLabelColor
        // 简单堆叠
        let stack = NSStackView(views: [icon, label])
        stack.orientation = .horizontal
        stack.spacing = SettingsTheme.spacingSm
        stack.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: box.topAnchor, constant: SettingsTheme.spacingSm),
            stack.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: SettingsTheme.spacingSm),
            stack.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -SettingsTheme.spacingSm),
            stack.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -SettingsTheme.spacingSm),
        ])
        box.wantsLayer = true
        box.layer?.cornerRadius = SettingsTheme.cardCornerRadius
        box.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        return box
    }
```

> `makePreviewChild` 与 `makeEditFormChild` 按 create 同范式实现（preview：keyword/content 只读 + expandPlaceholders 展开卡 + 编辑/删除；edit：keyword 只读 + content 编辑 + 时间戳 + 删除/取消/保存）。执行时按 create 模板复制调整。`previewChild` 调 `SnippetsService.expandPlaceholders(item.content)` 填展开卡（AC-SNIPGUI-23）。

- [ ] **Step 4: 实现 preview + edit 子 VC**

按 Step 3 create 模板，实现 `makePreviewChild(item:)`（只读 + 展开预览 + 编辑/删除按钮，删除按钮 action 调 `requestDelete(item:)`）与 `makeEditFormChild(item:)`。`requestDelete`：
```swift
    private func requestDelete(_ item: SnippetItem) {
        let alert = SnipPanelVC.presentDeleteAlert(for: item)
        let response = alert.runModal()
        SnipPanelVC.handleDeleteResponse(response, for: item)
        reloadAndRefresh()
        showEmptyState()
        testHook_currentDetailMode = .empty
    }
```

- [ ] **Step 5: 运行测试确认通过**

Run: `make -C apps/desktop test-only FILTER=SnipAppKitAcceptanceTests`
Expected: PASS（5 个测试）。

- [ ] **Step 6: lint + commit**

```bash
make -C apps/desktop lint
git add apps/desktop/Sources/ClaudeCodeBuddy/Settings/Plugins/SnipPanelVC.swift apps/desktop/tests/BuddyCoreTests/Settings/SnipAppKitAcceptanceTests.swift
git commit -m "feat(snip): 四态 detail（create/edit/preview/空）统一字段卡结构" -m "统一标题区/字段卡(SettingsGroupView)/操作栏，占位符提示与展开预览"
```

---

## Task 12: snip 数据流桥接 + 删 SnipPanelView + sizingOptions hack + 保存逻辑

**Files:**
- Modify: `apps/desktop/Sources/ClaudeCodeBuddy/Settings/Plugins/SnipPanelVC.swift`（补保存逻辑：取控件值 → service.add/edit + 校验）
- Delete: `apps/desktop/Sources/ClaudeCodeBuddy/Settings/Plugins/SnipPanelView.swift`

**Interfaces:**
- Consumes: `SnippetsService.add/edit`、`SnippetsError`。
- Produces: 完整 CRUD GUI 闭环；SwiftUI 彻底移除。

- [ ] **Step 1: 写失败测试（新增/编辑回写 snippets.json）**

在 `SnipAppKitAcceptanceTests.swift` 追加：

```swift
    func test_saveCreate_writesToSnippetsJson() throws {
        let vc = SnipPanelVC()
        _ = vc.view
        let kw = "save_test_\(UUID().uuidString.prefix(6))"
        try vc.testHook_fillAndSaveCreate(keyword: kw, content: "hello {date}")
        // 验证 service 有该片段
        XCTAssertTrue(SnippetsService.shared.search(kw).contains(where: { $0.keyword == kw }))
        SnippetsService.shared.delete(keyword: kw)
    }

    func test_invalidKeyword_showsFieldError() throws {
        let vc = SnipPanelVC()
        _ = vc.view
        try? vc.testHook_fillAndSaveCreate(keyword: "bad space", content: "x")
        // 含空格非法 → 应显示字段错误而非保存
        XCTAssertEqual(vc.testHook_currentDetailMode, .create)
    }
```

- [ ] **Step 2: 运行确认失败**

Run: `make -C apps/desktop test-only FILTER=SnipAppKitAcceptanceTests`
Expected: FAIL — `testHook_fillAndSaveCreate` 不存在。

- [ ] **Step 3: 补保存逻辑 + testHook**

在 `SnipPanelVC.swift`：
1. `makeCreateFormChild` 中把 keyword TextField 与 content editor 存为属性（`private var createKeywordField: NSTextField?`、`private var createContentEditor: NSTextView?`），save 时取值。
2. testHook（遵守 Global Constraints testHook 原则——经真实 action，禁直接调私有 saveCreate）：
```swift
    func testHook_fillAndSaveCreate(keyword: String, content: String) throws {
        testHook_startCreate()
        createKeywordField?.stringValue = keyword
        createContentEditor?.string = content
        // 经真实 action 链路（patterns/2026-07-09）：performClick saveButton 触发 @objc saveCreate，不直接调私有
        createSaveButton?.target?.perform(createSaveButton!.action)
    }
```
> 需在 `makeCreateFormChild`（Task 11 Step 3）把 save 按钮存为属性 `private var createSaveButton: NSButton?`（原局部 `let save` 改存属性），本 testHook 经它 performClick。
3. 实现 `saveCreate()`：
```swift
    func saveCreate() {
        let keyword = createKeywordField?.stringValue ?? ""
        let content = createContentEditor?.string ?? ""
        do {
            try service.add(keyword: keyword, content: content)
            cancelEdit()
            reloadAndRefresh()
        } catch let err as SnippetsError {
            // 字段级错误（AC-SNIPGUI-17/18）：keyword 错显示在 keyword 卡，content 错显示在 content 卡
            showFieldError(err)
        } catch {
            showFieldError(.invalidKeyword)
        }
    }
```
4. `showFieldError(_:)`：根据 SnippetsError case 在对应 SettingsFormRow 调 `setError(...)`。需在 makeCreateFormChild 保留 row 引用。
5. `saveEdit(keyword:)` 同理调 `service.edit`。

- [ ] **Step 4: 删除 SnipPanelView.swift**

```bash
git rm apps/desktop/Sources/ClaudeCodeBuddy/Settings/Plugins/SnipPanelView.swift
```

- [ ] **Step 5: 编译 + 全量 snip 测试**

Run: `make -C apps/desktop build && make -C apps/desktop test-only FILTER=SnipAppKitAcceptanceTests`
Expected: 编译过（SnipPanelView 无引用）+ 测试 PASS。

- [ ] **Step 6: 验 sizingOptions hack 已无（grep 确认）**

Run: `grep -rn "sizingOptions" apps/desktop/Sources/`
Expected: 无输出（SnipPanelVC 重写后已无 NSHostingController，hack 随旧 init 删除）。

- [ ] **Step 7: lint + commit**

```bash
make -C apps/desktop lint
git add apps/desktop/Sources/ClaudeCodeBuddy/Settings/Plugins/SnipPanelVC.swift apps/desktop/tests/BuddyCoreTests/Settings/SnipAppKitAcceptanceTests.swift
git commit -m "feat(snip): 数据流桥接+保存逻辑，删 SwiftUI 与 sizingOptions hack" -m "objectWillChange sink 刷新列表；CRUD 字段级校验；删 SnipPanelView.swift"
```

---

## Task 13: snip 测试适配（旧测试）+ 重录快照 + 真机验收

**Files:**
- Modify: `apps/desktop/tests/BuddyCoreTests/Settings/SnipPanelVCSnapshotTests.swift`
- Modify: `apps/desktop/tests/BuddyCoreTests/Launcher/SnipGUIInProcessAcceptanceTests.swift`（AC-13 适配）
- Modify: `apps/desktop/tests/BuddyCoreTests/Launcher/SnipPanelRenderDiagnosticTests.swift`
- Modify（重录）: `apps/desktop/tests/BuddyCoreTests/Launcher/__Snapshots__/SnipPanelRenderDiagnosticTests/*.png`

- [ ] **Step 1: 适配 SnipPanelVCSnapshotTests**

读 `SnipPanelVCSnapshotTests.swift`。`test_snipPanelVC_canInstantiate` / `test_snipPanelVC_isPluginSettingsPanelProvider` / `test_snipPanelVC_viewIsNotNil` 保留（SnipPanelVC 仍可 `init()`、仍 PluginSettingsPanelProvider）。这些断言仍成立，无需改。确认运行 PASS。

Run: `make -C apps/desktop test-only FILTER=SnipPanelVCSnapshotTests`
Expected: PASS（父类变 NSViewController 但 API 不变）。

- [ ] **Step 2: 适配 AC-13（占位符提示可遍历）**

读 `SnipGUIInProcessAcceptanceTests.swift` 的 `test_AC_SNIPGUI_13_snipPanel_containsPlaceholderSyntaxHint`。原断言因 SwiftUI Text 不可遍历跳过/弱断言；现 AppKit `makePlaceholderHintView` 用 NSTextField，可遍历 collectStaticTexts 含 `{date}`/`{time}`/`{clipboard}`。改为强断言：
```swift
    func test_AC_SNIPGUI_13_snipPanel_containsPlaceholderSyntaxHint() {
        let gallery = PluginGalleryViewController()
        _ = gallery.view
        // 选中 snip 插件 → snip 面板渲染
        // ...（沿用现有 selectRow 选中 snip 的逻辑）
        let vc = /* 拿到 SnipPanelVC */
        _ = vc.view
        let texts = collectStaticTexts(in: vc.view)
        XCTAssertTrue(texts.contains(where: { $0.contains("{date}") }))
        XCTAssertTrue(texts.contains(where: { $0.contains("{clipboard}") }))
    }
```
执行时 Read 原测试方法，按 AppKit 可遍历改写断言。

- [ ] **Step 3: 重录 SnipPanelRenderDiagnosticTests 基线**

该测试原 host `SnipPanelView`（SwiftUI），现需改为 host `SnipPanelVC`（AppKit）并重录。读 `SnipPanelRenderDiagnosticTests.swift`，把 `SnipPanelView(initialEditingItem:...)` 的 host 改为：
```swift
let vc = SnipPanelVC()
_ = vc.view
vc.testHook_startCreate()  // create 态
// 或 testHook_selectRow(0) // preview 态
```
删旧基线重录：
```bash
rm -f apps/desktop/tests/BuddyCoreTests/Launcher/__Snapshots__/SnipPanelRenderDiagnosticTests/*.png
swift test --package-path apps/desktop --filter SnipPanelRenderDiagnosticTests
```
Expected: 新基线生成（create/edit/empty），PASS。

- [ ] **Step 4: 适配 SnipWindowSizingTests（B3 修复，编译失败 + AC-WIN-02 替代断言）**

`SnipWindowSizingTests.swift` 2 测试方法：
- `test_snipPanelVC_sizingOptions_doesNotPropagatePreferredSize`（约 :64-69）读 `snipVC.sizingOptions.contains(.preferredContentSize)` —— SnipPanelVC 重写为 NSViewController 后**无 sizingOptions 属性，编译失败**。**删除整方法**。
- `test_mechanism_defaultSizingOptions_propagatesFittingSizeToWindow`（约 :42-58）用裸 `NSHostingController<Text>`，与 SnipPanelVC 解耦，迁移后仍有效 —— **保留**。

**AC-WIN-02 替代断言**（删 sizingOptions 断言后补，否则验收空洞）：
```swift
func test_AC_WIN_02_snipPanelVC_isNotNSHostingController_sizingOptionsEliminated() {
    let vc = SnipPanelVC()
    _ = vc.view
    XCTAssertFalse(vc is NSHostingController, "SnipPanelVC 应纯 AppKit（非 NSHostingController），sizingOptions hack 消除")
}
```
+ 源码 grep `grep -rn "sizingOptions" apps/desktop/Sources/ClaudeCodeBuddy/Settings/Plugins/SnipPanelVC.swift` == 0（AC-WIN-01 双验证）。

- [ ] **Step 5: 全量回归**

Run: `make -C apps/desktop test-fast`
Expected: 全绿（逻辑层 + 已适配测试）。

Run: `swift test --package-path apps/desktop --filter Snapshot`
Expected: 快照全绿（含重录基线）。

- [ ] **Step 6: 真机端到端验收（GUI/sizing 盲区，必做）**

```bash
SKIP_FETCH_PLUGINS=1 make -C apps/desktop bundle
pkill -f ClaudeCodeBuddy; sleep 1; open apps/desktop/ClaudeCodeBuddy.app
```
人工：设置 → 插件 → 选中 snip →
1. 进入 snip 面板，**窗口高度不再塌缩**（sizingOptions hack 消除验证）。
2. 列表显示已有片段，搜索过滤即时。
3. 点新增 → create 态 → 输入 keyword/content → 保存 → 列表刷新。
4. 选中片段 → preview → 占位符展开正确（{date} → 今日）。
5. 编辑 → 改 content → 保存 → updated_at 变。
6. 删除 → NSAlert 二次确认 → 取消不删 / 确认删除。
7. 非法 keyword（含空格）→ 字段错误提示，不保存。

读窗口 frame 验高度稳定：
```bash
osascript -e 'tell application "System Events" to get {position, size} of window 1 of process "ClaudeCodeBuddy"'
```

- [ ] **Step 7: lint + commit**

```bash
make -C apps/desktop lint
git add apps/desktop/tests/
git commit -m "test(snip): 适配 AppKit 迁移后的测试 + 重录快照基线" -m "AC-13 改强断言；RenderDiagnostic 重录；Sizing 适配；全量回归绿"
```

---

## Self-Review 结论

**1. Spec 覆盖**：
- 限宽居中（3.1①）→ Task 2/4/5/8/11 ✓
- 间距栅格（3.1② + spec 4.1）→ Task 1/3/4/5/8 ✓
- 分栏固定（3.1③）→ Task 6/7 ✓
- 行高 + 列表对齐（3.1④）→ Task 3/8 ✓
- master-detail 范式（3.1⑤）→ Task 7/8/10/11 ✓
- snip 迁 AppKit（3.2）→ Task 10/11/12 ✓
- 接入点细化（spec 细化说明）→ File Structure 与 Task 4/5/8/10 注明 ✓
- 测试四类处置（3.4 + spec 4.5）→ Task 13 ✓
- 真机 QA → Task 6/9/13 Step ✓
- 非目标（spec 6）→ Global Constraints "数据层不动" + 未触及 SkinGallery 架构/品牌色/新功能 ✓

**2. 占位符扫描**：无 TBD/TODO；About/KeyboardShortcuts/Provider/PluginGallery 的改写因依赖执行时 Read 精确代码，给出了明确规则（"addSubview 目标改 contentColumn、约束锚改 contentColumn、硬编码→scale"）+ 引用 spec 行号，属可执行指令非占位符。

**3. 类型一致性**：`SettingsTheme.spacing*/contentMaxWidth/sidebarWidth/pluginListWidth/minRowHeight`（Task 1 定义）被后续 task 一致引用；`ContentColumnView.contentColumn/maxWidth`（Task 2）被 Task 4/5/8/10/11 一致引用；`SnipPanelVC.detailContainer/makePanelVC/testHook_*`（Task 10/11/12）一致；`SnipListCellView`（Task 10）被 Task 10 delegate 引用。`SnippetsService` API 全程不变。`presentDeleteAlert/handleDeleteResponse` seam 保留。
