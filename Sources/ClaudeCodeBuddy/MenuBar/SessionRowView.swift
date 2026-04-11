import AppKit

class SessionRowView: NSView {

    var onClick: (() -> Void)?

    init(session: SessionInfo) {
        super.init(frame: NSRect(x: 0, y: 0, width: 280, height: 44))

        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 44).isActive = true

        // Color dot
        let dot = NSView(frame: .zero)
        dot.wantsLayer = true
        dot.layer?.backgroundColor = session.color.nsColor.cgColor
        dot.layer?.cornerRadius = 5
        dot.translatesAutoresizingMaskIntoConstraints = false
        addSubview(dot)

        // Label
        let label = NSTextField(labelWithString: session.label)
        label.font = .boldSystemFont(ofSize: 12)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        // State badge
        let state = NSTextField(labelWithString: session.state.rawValue)
        state.font = .systemFont(ofSize: 10)
        state.textColor = .secondaryLabelColor
        state.translatesAutoresizingMaskIntoConstraints = false
        addSubview(state)

        // CWD
        let cwd = NSTextField(labelWithString: session.cwd ?? "—")
        cwd.font = .monospacedSystemFont(ofSize: 9, weight: .regular)
        cwd.textColor = .tertiaryLabelColor
        cwd.lineBreakMode = .byTruncatingMiddle
        cwd.translatesAutoresizingMaskIntoConstraints = false
        addSubview(cwd)

        NSLayoutConstraint.activate([
            dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 10),
            dot.heightAnchor.constraint(equalToConstant: 10),

            label.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 8),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 6),

            state.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            state.topAnchor.constraint(equalTo: topAnchor, constant: 6),

            cwd.leadingAnchor.constraint(equalTo: label.leadingAnchor),
            cwd.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            cwd.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 2),
        ])

        // Click gesture
        let click = NSClickGestureRecognizer(target: self, action: #selector(handleClick))
        addGestureRecognizer(click)
    }

    required init?(coder: NSCoder) { fatalError() }

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
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.5, alpha: 0.1).cgColor
    }

    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = nil
    }
}
