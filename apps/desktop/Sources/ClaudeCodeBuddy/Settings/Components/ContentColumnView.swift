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
    let contentColumn = NSView()

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
        // documentView：宽度用 autoresizing 跟随 clipView（NSScrollView 自管）。
        // ⚠️ 不用 autolayout 钉 contentView.width——会与 NSScrollView 的 documentView 管理机制冲突
        // → documentView 塌缩 0×0 → contentColumn 0 高 → 整片白屏（patterns/2026-07-02 反模式）。
        // autopilot 2026-07-12 in-process bounds 真机实测：5 个用 ContentColumnView 的 section 均
        // documentView 0×0（skins 不用本组件故正常）。
        documentView.autoresizingMask = [.width]
        documentView.wantsLayer = true
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

            // contentColumn 限宽 + 居中 + 上下/左右留白（documentView width 由 autoresizingMask 管理，
            // height 由 layout() override 手动钉 scrollView 可视高——见下方）
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

            // 内容最小宽（防 detail 被缩到 content fittingWidth 致右栏空白）
            widthAnchor.constraint(greaterThanOrEqualToConstant: SettingsTheme.contentMinFloorWidth),
        ])
    }

    /// documentView 手动 frame：NSScrollView documentView 的 autolayout 约束不稳定（autopilot 2026-07-12
    /// 真机实测：documentView.heightAnchor ≥ scrollView.heightAnchor 无效 → documentView 0 高 → contentColumn
    /// 0 高 → 整片白屏；width/height/contentView 锚点均试过无效）。改手动钉 frame = scrollView 可视尺寸
    /// （宽跟 clipView 只竖滚，高 = scrollView 高防贴底）。contentColumn 在 documentView 内 autolayout 布局
    /// （钉四边 + 限宽居中），其 anchors 反映 documentView.frame，故 contentColumn 随之撑开。
    /// 已知限制：内容超高时 documentView 不随内容增高（不滚动）；大窗口（充满屏幕 ~1050 高）下设置内容
    /// 基本不超高，可接受。后续若需滚动，改动态算 documentView.frame.height = max(contentColumn 拟合高, scrollView 高)。
    override func layout() {
        super.layout()
        guard scrollView.bounds.height > 0 else { return }
        let clipWidth = scrollView.contentView.bounds.width
        let newFrame = NSRect(x: 0, y: 0, width: clipWidth, height: scrollView.bounds.height)
        if documentView.frame != newFrame {
            documentView.frame = newFrame
        }
    }
}
