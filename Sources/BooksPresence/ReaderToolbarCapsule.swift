import AppKit

/// A group of toolbar buttons on one capsule, sized as in Apple Books: 35 pt tall, about 37 pt a button. The capsule is
/// its own view rather than a system group so it reads the same on every SDK this app is built with.
@MainActor final class ReaderToolbarCapsule: NSView {
    private static let height: CGFloat = 35, buttonWidth: CGFloat = 37
    private let row: [NSButton]
    init(_ buttons: [NSButton]) {
        row = buttons
        super.init(frame: NSRect(x: 0, y: 0, width: CGFloat(buttons.count) * Self.buttonWidth, height: Self.height))
        wantsLayer = true
        layer?.cornerCurve = .continuous
        translatesAutoresizingMaskIntoConstraints = false
        // Fixed, so the toolbar centres the capsule in its band instead of stretching it.
        NSLayoutConstraint.activate([widthAnchor.constraint(equalToConstant: frame.width), heightAnchor.constraint(equalToConstant: frame.height)])
        buttons.forEach(addSubview)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var intrinsicContentSize: NSSize { NSSize(width: CGFloat(row.count) * Self.buttonWidth, height: Self.height) }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
        let width = bounds.width / CGFloat(max(1, row.count))
        for (index, button) in row.enumerated() { button.frame = NSRect(x: CGFloat(index) * width, y: 0, width: width, height: bounds.height) }
    }

    func apply(_ palette: ReaderPanelPalette) {
        // Measured: #131313 on a black page; on a white page the same white with a soft shadow.
        if palette.dark {
            layer?.backgroundColor = palette.nsInk.withAlphaComponent(0.08).cgColor
            layer?.shadowOpacity = 0
        } else {
            layer?.backgroundColor = palette.nsPanel.cgColor
            layer?.shadowColor = NSColor.black.cgColor; layer?.shadowOpacity = 0.1; layer?.shadowRadius = 8; layer?.shadowOffset = NSSize(width: 0, height: -1)
        }
    }
}
