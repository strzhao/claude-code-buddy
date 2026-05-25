import AppKit

class SessionPopoverController: NSViewController {

    // Layout constants for dynamic popover height
    private static let popoverWidth: CGFloat = 320
    private static let rowHeight: CGFloat = 76
    private static let separatorGap: CGFloat = 3      // stackView.spacing + NSBox separator + spacing
    private static let chromeHeight: CGFloat = 93      // header + footer with safety margin
    private static let emptyStateHeight: CGFloat = 130
    private static let maxVisibleSessions = 6

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

    func updateSessions(_ sessions: [SessionInfo]) {
        self.sessions = sessions
        countLabel.stringValue = "\(sessions.count) sessions"

        // Toggle empty state
        emptyStateLabel.isHidden = !sessions.isEmpty
        scrollView.isHidden = sessions.isEmpty

        // Clear old rows
        stackView.arrangedSubviews.forEach { $0.removeFromSuperview() }

        // Add session rows with separators
        for (index, session) in sessions.enumerated() {
            let row = SessionRowView(session: session)
            row.alphaValue = 1.0
            row.onClick = { [weak self] in
                self?.onSessionClicked?(session)
            }
            stackView.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stackView.widthAnchor).isActive = true

            // Add separator between rows (not after last)
            if index < sessions.count - 1 {
                let separator = NSBox()
                separator.boxType = .separator
                separator.translatesAutoresizingMaskIntoConstraints = false
                stackView.addArrangedSubview(separator)
                NSLayoutConstraint.activate([
                    separator.leadingAnchor.constraint(equalTo: stackView.leadingAnchor, constant: 36),
                    separator.trailingAnchor.constraint(equalTo: stackView.trailingAnchor, constant: -16),
                ])
            }
        }
        preferredContentSize = NSSize(width: Self.popoverWidth, height: idealHeight(for: sessions.count))
    }

    @objc private func quitClicked() {
        onQuit?()
    }

    @objc private func settingsClicked() {
        onSettings?()
    }
}
