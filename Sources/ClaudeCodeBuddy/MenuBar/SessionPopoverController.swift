import AppKit

class SessionPopoverController: NSViewController {

    private var sessions: [SessionInfo] = []
    private let scrollView = NSScrollView()
    private let stackView = NSStackView()
    private let headerLabel = NSTextField(labelWithString: "Claude Code Buddy")
    private let countLabel = NSTextField(labelWithString: "0 sessions")
    private let footerLabel = NSTextField(labelWithString: "点击 session 跳转终端")

    var onSessionClicked: ((SessionInfo) -> Void)?
    var onQuit: (() -> Void)?

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 300))

        // Header
        headerLabel.font = .boldSystemFont(ofSize: 13)
        headerLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(headerLabel)

        countLabel.font = .systemFont(ofSize: 11)
        countLabel.textColor = .secondaryLabelColor
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(countLabel)

        // Stack view for session rows
        stackView.orientation = .vertical
        stackView.spacing = 2
        stackView.translatesAutoresizingMaskIntoConstraints = false

        scrollView.documentView = stackView
        scrollView.hasVerticalScroller = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        container.addSubview(scrollView)

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

        NSLayoutConstraint.activate([
            headerLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            headerLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),

            countLabel.centerYAnchor.constraint(equalTo: headerLabel.centerYAnchor),
            countLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),

            scrollView.topAnchor.constraint(equalTo: headerLabel.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: footerLabel.topAnchor, constant: -8),

            stackView.widthAnchor.constraint(equalTo: scrollView.widthAnchor),

            footerLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            footerLabel.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),

            quitButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            quitButton.centerYAnchor.constraint(equalTo: footerLabel.centerYAnchor),
        ])

        self.view = container
    }

    func updateSessions(_ sessions: [SessionInfo]) {
        self.sessions = sessions
        countLabel.stringValue = "\(sessions.count) sessions"

        // Clear old rows
        stackView.arrangedSubviews.forEach { $0.removeFromSuperview() }

        // Add session rows
        for session in sessions {
            let row = SessionRowView(session: session)
            row.alphaValue = session.state == .idle ? 0.7 : 1.0
            row.onClick = { [weak self] in
                self?.onSessionClicked?(session)
            }
            stackView.addArrangedSubview(row)
        }
    }

    @objc private func quitClicked() {
        onQuit?()
    }
}
