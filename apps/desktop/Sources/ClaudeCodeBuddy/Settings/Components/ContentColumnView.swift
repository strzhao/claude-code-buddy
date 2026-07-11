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

            // 内容最小宽（防 NSSplitViewController 把 detail item 缩到 content fittingWidth 致右栏空白）：
            // ContentColumnView 是所有 section 右栏 + 插件画廊右栏的共享组件。给自身加 width≥contentMinWidth
            // 抬高 detail content fittingWidth，NSSplitViewController 据此 size detail item（不再挤压到 0）。
            // 320 ≤ 画廊右栏可用宽（window 800 - sidebar 200 - pluginList 240 = 360），不致 unsatisfiable。
            widthAnchor.constraint(greaterThanOrEqualToConstant: SettingsTheme.contentMinFloorWidth),
        ])
    }
}
