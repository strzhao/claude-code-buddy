import AppKit

class SessionRowView: NSView {

    var onClick: (() -> Void)?

    private let hoverBackground = NSView()

    init(session: SessionInfo) {
        super.init(frame: NSRect(x: 0, y: 0, width: 320, height: 76))

        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 76).isActive = true
        wantsLayer = true

        // Hover background (rounded, inset)
        hoverBackground.wantsLayer = true
        hoverBackground.layer?.cornerRadius = 6
        hoverBackground.translatesAutoresizingMaskIntoConstraints = false
        hoverBackground.isHidden = true
        addSubview(hoverBackground)

        // Color dot with glow
        let dot = NSView(frame: .zero)
        dot.wantsLayer = true  // Must be set before accessing layer properties
        dot.layer?.backgroundColor = session.color.nsColor.cgColor
        dot.layer?.cornerRadius = 5
        dot.layer?.shadowColor = session.color.nsColor.cgColor
        dot.layer?.shadowRadius = 3
        dot.layer?.shadowOpacity = 0.4
        dot.layer?.shadowOffset = .zero
        dot.translatesAutoresizingMaskIntoConstraints = false
        addSubview(dot)

        // Label
        let label = NSTextField(labelWithString: session.label)
        label.font = .boldSystemFont(ofSize: 13)
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        // State badge with semantic color
        let state = NSTextField(labelWithString: session.state.rawValue)
        state.font = .systemFont(ofSize: 10)
        switch session.state {
        case .idle:              state.textColor = .tertiaryLabelColor
        case .thinking:          state.textColor = .systemBlue
        case .toolUse:           state.textColor = .systemGreen
        case .permissionRequest: state.textColor = .systemOrange
        case .eating:            state.textColor = .systemPurple
        case .taskComplete:      state.textColor = .systemTeal
        }
        state.setContentCompressionResistancePriority(.required, for: .horizontal)
        state.setContentHuggingPriority(.required, for: .horizontal)
        state.translatesAutoresizingMaskIntoConstraints = false
        addSubview(state)

        // CWD with smart abbreviation
        let displayCwd: String
        if let cwdPath = session.cwd {
            let home = NSHomeDirectory()
            let components = cwdPath.split(separator: "/", omittingEmptySubsequences: true)
            if components.count > 3, let last = components.last {
                displayCwd = (cwdPath.hasPrefix(home) ? "~" : "") + "/\u{2026}/" + last
            } else {
                displayCwd = cwdPath.replacingOccurrences(of: home, with: "~")
            }
        } else {
            displayCwd = "—"
        }
        let cwd = NSTextField(labelWithString: displayCwd)
        cwd.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        cwd.textColor = .tertiaryLabelColor
        cwd.lineBreakMode = .byTruncatingTail
        cwd.translatesAutoresizingMaskIntoConstraints = false
        addSubview(cwd)

        // Stats line (third line)
        let statsText = Self.buildStatsText(session: session)
        let stats = NSTextField(labelWithString: statsText)
        stats.font = .systemFont(ofSize: 9)
        stats.textColor = .quaternaryLabelColor
        stats.lineBreakMode = .byTruncatingTail
        stats.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stats)

        NSLayoutConstraint.activate([
            // Hover background
            hoverBackground.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            hoverBackground.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            hoverBackground.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            hoverBackground.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),

            // Color dot
            dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 10),
            dot.heightAnchor.constraint(equalToConstant: 10),

            // Label (first line, left)
            label.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 10),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            label.trailingAnchor.constraint(lessThanOrEqualTo: state.leadingAnchor, constant: -8),

            // State badge (first line, right, baseline-aligned)
            state.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            state.firstBaselineAnchor.constraint(equalTo: label.firstBaselineAnchor),

            // CWD (second line)
            cwd.leadingAnchor.constraint(equalTo: label.leadingAnchor),
            cwd.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            cwd.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 3),

            // Stats (third line)
            stats.leadingAnchor.constraint(equalTo: label.leadingAnchor),
            stats.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            stats.topAnchor.constraint(equalTo: cwd.bottomAnchor, constant: 2),
        ])

        // Click gesture
        let click = NSClickGestureRecognizer(target: self, action: #selector(handleClick))
        addGestureRecognizer(click)
    }

    required init?(coder: NSCoder) { fatalError() }

    private static func buildStatsText(session: SessionInfo) -> String {
        var parts: [String] = []

        // Model (simplify name)
        if let model = session.model {
            let short = model
                .replacingOccurrences(of: "claude-", with: "")
                .replacingOccurrences(of: "-4-6", with: "-4")
                .replacingOccurrences(of: "-4-5", with: "-4.5")
            parts.append(short)
        }

        // Duration
        if let started = session.startedAt {
            let elapsed = Date().timeIntervalSince(started)
            if elapsed < 3600 {
                parts.append("\(Int(elapsed / 60))m")
            } else if elapsed < 86400 {
                parts.append("\(Int(elapsed / 3600))h")
            } else {
                let days = Int(elapsed / 86400)
                let hours = Int(elapsed.truncatingRemainder(dividingBy: 86400) / 3600)
                parts.append("\(days)d \(hours)h")
            }
        }

        // Tokens (in millions)
        if session.totalTokens > 0 {
            let millions = Double(session.totalTokens) / 1_000_000.0
            if millions >= 1.0 {
                parts.append(String(format: "%.1fM", millions))
            } else {
                parts.append(String(format: "%.1fM", millions))
            }
        }

        // Tool calls
        if session.toolCallCount > 0 {
            parts.append("\(session.toolCallCount) tools")
        }

        return parts.joined(separator: " · ")
    }

    @objc private func handleClick() {
        onClick?()
    }

    // Hover highlight
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        hoverBackground.layer?.backgroundColor = NSColor(white: 0.5, alpha: 0.08).cgColor
        hoverBackground.isHidden = false
    }

    override func mouseExited(with event: NSEvent) {
        hoverBackground.isHidden = true
    }
}
