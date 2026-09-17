import AppKit

class SessionPopoverController: NSViewController {

    // Layout constants for dynamic popover height
    private static let popoverWidth: CGFloat = 320
    private static let rowHeight: CGFloat = 76
    private static let separatorGap: CGFloat = 3      // stackView.spacing + NSBox separator + spacing
    private static let chromeHeight: CGFloat = 93      // header + footer with safety margin
    private static let emptyStateHeight: CGFloat = 130
    private static let maxVisibleSessions = 6
    private static let sectionHeaderHeight: CGFloat = 24   // 「后台任务 (N)」分组 header

    private func idealHeight(for count: Int) -> CGFloat {
        guard count > 0 else { return Self.emptyStateHeight }
        let visible = min(count, Self.maxVisibleSessions)
        return Self.chromeHeight + CGFloat(visible) * Self.rowHeight + CGFloat(visible - 1) * Self.separatorGap
    }

    private var sessions: [SessionInfo] = []
    private let scrollView = NSScrollView()
    private let stackView = NSStackView()
    private let headerLabel = NSTextField(labelWithString: "Claude Code Buddy")
    private let countLabel = NSTextField(labelWithString: "0 sessions")
    private let footerLabel = NSTextField(labelWithString: "Click session to switch terminal")
    private let emptyStateLabel = NSTextField(labelWithString: "No active sessions")

    var onSessionClicked: ((SessionInfo) -> Void)?
    var onQuit: (() -> Void)?
    var onSettings: (() -> Void)?

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 130))

        // Header
        headerLabel.font = .boldSystemFont(ofSize: 13)
        headerLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(headerLabel)

        countLabel.font = .systemFont(ofSize: 11)
        countLabel.textColor = .secondaryLabelColor
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(countLabel)

        // Header separator
        let headerSeparator = NSBox()
        headerSeparator.boxType = .separator
        headerSeparator.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(headerSeparator)

        // Stack view for session rows
        stackView.orientation = .vertical
        stackView.spacing = 1
        stackView.translatesAutoresizingMaskIntoConstraints = false

        scrollView.documentView = stackView
        scrollView.hasVerticalScroller = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        container.addSubview(scrollView)

        // Empty state
        emptyStateLabel.font = .systemFont(ofSize: 12)
        emptyStateLabel.textColor = .tertiaryLabelColor
        emptyStateLabel.alignment = .center
        emptyStateLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyStateLabel.isHidden = true
        container.addSubview(emptyStateLabel)

        // Footer separator
        let footerSeparator = NSBox()
        footerSeparator.boxType = .separator
        footerSeparator.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(footerSeparator)

        // Footer
        footerLabel.font = .systemFont(ofSize: 10)
        footerLabel.textColor = .tertiaryLabelColor
        footerLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(footerLabel)

        // Quit button
        let quitButton = NSButton(title: "Quit", target: self, action: #selector(quitClicked))
        quitButton.bezelStyle = .inline
        quitButton.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(quitButton)

        // Settings (gear) button
        let gearImage = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "Settings")
            ?? NSImage(named: NSImage.actionTemplateName)
            ?? NSImage()
        let settingsButton = NSButton(image: gearImage, target: self, action: #selector(settingsClicked))
        settingsButton.bezelStyle = .inline
        settingsButton.isBordered = false
        settingsButton.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(settingsButton)

        NSLayoutConstraint.activate([
            headerLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
            headerLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),

            countLabel.centerYAnchor.constraint(equalTo: headerLabel.centerYAnchor),
            countLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),

            headerSeparator.topAnchor.constraint(equalTo: headerLabel.bottomAnchor, constant: 12),
            headerSeparator.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            headerSeparator.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            scrollView.topAnchor.constraint(equalTo: headerSeparator.bottomAnchor, constant: 4),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: footerSeparator.topAnchor, constant: -4),

            stackView.widthAnchor.constraint(equalTo: scrollView.widthAnchor),

            emptyStateLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyStateLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),

            footerSeparator.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            footerSeparator.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            footerSeparator.bottomAnchor.constraint(equalTo: footerLabel.topAnchor, constant: -10),

            footerLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            footerLabel.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -14),

            settingsButton.trailingAnchor.constraint(equalTo: quitButton.leadingAnchor, constant: -8),
            settingsButton.centerYAnchor.constraint(equalTo: footerLabel.centerYAnchor),

            quitButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            quitButton.centerYAnchor.constraint(equalTo: footerLabel.centerYAnchor),
        ])

        self.view = container
        preferredContentSize = NSSize(width: Self.popoverWidth, height: Self.emptyStateHeight)
    }

    /// C-POPOVER-GROUP：固定顺序 = 交互组（lastActivity 降序）在前 + headless 组在后；
    /// 组间 header「后台任务 (N)」，N=0 不渲染；headless 行 ⚙ 且点击不触发 onSessionClicked。
    func updateSessions(_ sessions: [SessionInfo]) {
        self.sessions = sessions
        countLabel.stringValue = "\(sessions.count) sessions"

        // Toggle empty state
        emptyStateLabel.isHidden = !sessions.isEmpty
        scrollView.isHidden = sessions.isEmpty

        // Clear old rows
        stackView.arrangedSubviews.forEach { $0.removeFromSuperview() }

        let interactive = sessions
            .filter { !$0.isHeadless }
            .sorted { $0.lastActivity > $1.lastActivity }
        let headless = sessions
            .filter { $0.isHeadless }
            .sorted { $0.lastActivity > $1.lastActivity }

        var visibleRows = 0
        for session in interactive {
            appendRow(session, clickable: true)
            visibleRows += 1
        }

        if !headless.isEmpty {
            stackView.addArrangedSubview(makeHeadlessSectionHeader(count: headless.count))
            for session in headless {
                appendRow(session, clickable: false)
                visibleRows += 1
            }
        }

        let headerExtra: CGFloat = headless.isEmpty ? 0 : Self.sectionHeaderHeight
        preferredContentSize = NSSize(
            width: Self.popoverWidth,
            height: idealHeight(for: visibleRows) + headerExtra)
    }

    private func appendRow(_ session: SessionInfo, clickable: Bool) {
        let row = SessionRowView(session: session)
        row.alphaValue = 1.0
        if clickable {
            row.onClick = { [weak self] in
                self?.onSessionClicked?(session)
            }
        } else {
            row.onClick = nil   // C-HEADLESS-NO-TERMINAL：后台行点击不跳转（行内也无点击手势）
        }
        stackView.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: stackView.widthAnchor).isActive = true
    }

    /// 「后台任务 (N)」section header（AX id 供 in-process 断言绑定）
    private func makeHeadlessSectionHeader(count: Int) -> NSView {
        let container = NSView()
        let label = NSTextField(labelWithString: "后台任务 (\(count))")
        label.font = .boldSystemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.setAccessibilityIdentifier("popover-section-headless")
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        container.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            container.heightAnchor.constraint(equalToConstant: Self.sectionHeaderHeight),
        ])
        return container
    }

    @objc private func quitClicked() {
        onQuit?()
    }

    @objc private func settingsClicked() {
        onSettings?()
    }
}
