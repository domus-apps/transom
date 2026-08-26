import AppKit
import Carbon.HIToolbox

/* First-run onboarding: what Transom is, what cursor-aware brightness
   looks like, the keys, and the Accessibility permission gate (the
   brightness keys are intercepted with an event tap, which macOS allows
   only for trusted apps). The window has no close button and refuses
   every close attempt — the only way out is granting access and clicking
   Start, and completion is persisted only at that click, so quitting (or
   force-quitting) mid-onboarding brings the onboarding back on the next
   launch. */
final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
    private let onComplete: () -> Void
    private var pollTimer: Timer?

    private let statusLabel = NSTextField(labelWithString: "")
    private lazy var requestButton = NSButton(
        title: "Request Accessibility Access", target: self,
        action: #selector(requestAccess))
    private lazy var settingsLink = NSButton(
        title: "Open Privacy & Security Settings…", target: self,
        action: #selector(openSystemSettings))
    private lazy var startButton = NSButton(
        title: "Start Using Transom", target: self, action: #selector(start))

    init(onComplete: @escaping () -> Void) {
        self.onComplete = onComplete

        /* No .closable: the traffic-light close button never appears. */
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 596),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false

        super.init(window: window)
        window.delegate = self
        window.contentView = makeContent()
        window.center()

        refreshPermissionState()
        /* Permission grants don't notify; polling once a second is the
           standard idiom (the System Settings toggle takes effect live). */
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) {
            [weak self] _ in
            self?.refreshPermissionState()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /* The gate: no closing until onboarding is completed via start(). */
    func windowShouldClose(_ sender: NSWindow) -> Bool { false }

    // MARK: - Content

    private func makeContent() -> NSView {
        let title = NSTextField(labelWithString: "Welcome to Transom")
        title.font = .systemFont(ofSize: 30, weight: .bold)

        let intro = NSTextField(
            wrappingLabelWithString:
                "Transom makes the brightness keys cursor-aware: they adjust "
                + "whichever display your pointer is on — external displays "
                + "included — with a native-looking indicator drawn right there.")
        intro.font = .systemFont(ofSize: 14)
        intro.textColor = .secondaryLabelColor
        intro.alignment = .center
        intro.preferredMaxLayoutWidth = 470

        let illustration = OnboardingIllustrationView()
        illustration.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            illustration.widthAnchor.constraint(equalToConstant: 480),
            illustration.heightAnchor.constraint(equalToConstant: 200),
        ])

        let shortcutRow = NSStackView(
            views: [
                labelView("Press"),
                keycap("F1"), labelView("or"), keycap("F2"),
                labelView("— the display under your cursor responds"),
            ])
        shortcutRow.orientation = .horizontal
        shortcutRow.spacing = 6

        statusLabel.font = .systemFont(ofSize: 13)
        requestButton.bezelStyle = .rounded
        requestButton.keyEquivalent = "\r"
        settingsLink.isBordered = false
        settingsLink.contentTintColor = .linkColor
        settingsLink.font = .systemFont(ofSize: 12)

        let permissionBox = NSStackView(
            views: [statusLabel, requestButton, settingsLink])
        permissionBox.orientation = .vertical
        permissionBox.alignment = .centerX
        permissionBox.spacing = 8

        startButton.bezelStyle = .rounded
        startButton.controlSize = .large

        let stack = NSStackView(
            views: [title, intro, illustration, shortcutRow, permissionBox, startButton])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 16
        stack.setCustomSpacing(10, after: title)
        stack.setCustomSpacing(22, after: intro)
        stack.setCustomSpacing(24, after: shortcutRow)
        stack.setCustomSpacing(20, after: permissionBox)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 44),
            stack.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            stack.bottomAnchor.constraint(
                lessThanOrEqualTo: container.bottomAnchor, constant: -32),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 500),
        ])
        return container
    }

    private func labelView(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 14)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func keycap(_ symbol: String) -> NSView {
        KeycapView(symbol: symbol)
    }

    // MARK: - Permission gate

    private func refreshPermissionState() {
        let trusted = AXIsProcessTrusted()
        statusLabel.stringValue =
            trusted
            ? "✓ Accessibility access granted"
            : "Transom needs Accessibility access to intercept the brightness keys."
        statusLabel.textColor = trusted ? .systemGreen : .labelColor
        requestButton.isHidden = trusted
        settingsLink.isHidden = trusted
        startButton.isEnabled = trusted
        startButton.keyEquivalent = trusted ? "\r" : ""
    }

    @objc private func requestAccess() {
        /* The system prompt appears only on the very first ask; afterwards
           macOS stays silent, so the settings link below is the fallback. */
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    @objc private func openSystemSettings() {
        guard
            let url = URL(
                string:
                    "x-apple.systempreferences:com.apple.preference.security"
                    + "?Privacy_Accessibility")
        else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func start() {
        guard AXIsProcessTrusted() else { return }
        pollTimer?.invalidate()
        pollTimer = nil
        window?.delegate = nil
        onComplete()
        close()
    }
}

/* One keyboard key, drawn as a keycap. */
private final class KeycapView: NSView {
    private let symbol: String

    init(symbol: String) {
        self.symbol = symbol
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 34),
            heightAnchor.constraint(equalToConstant: 30),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func draw(_ dirtyRect: NSRect) {
        let body = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6)
        NSColor.quaternarySystemFill.setFill()
        body.fill()
        NSColor.separatorColor.setStroke()
        body.lineWidth = 1
        body.stroke()

        let text = NSAttributedString(
            string: symbol,
            attributes: [
                .font: NSFont.systemFont(ofSize: 15, weight: .medium),
                .foregroundColor: NSColor.labelColor,
            ])
        let size = text.size()
        text.draw(
            at: NSPoint(
                x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2))
    }
}

/* A drawn "screenshot" of Transom in action: two displays, the cursor on
   the external one, and the brightness pill showing there. Drawn (not a
   bundled image) so it stays crisp at any backing scale and needs no
   resource plumbing. */
private final class OnboardingIllustrationView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let canvas = bounds

        // Backdrop in the app's amber
        let backdrop = NSBezierPath(roundedRect: canvas, xRadius: 12, yRadius: 12)
        NSGradient(
            starting: NSColor(srgbRed: 0.24, green: 0.15, blue: 0.05, alpha: 1),
            ending: NSColor(srgbRed: 0.12, green: 0.07, blue: 0.03, alpha: 1)
        )?.draw(in: backdrop, angle: -90)

        // Built-in display (dimmer, no cursor); external display (cursor
        // here, brighter, carrying the brightness pill)
        drawDisplay(NSRect(x: 46, y: 30, width: 150, height: 100), lit: false)
        let external = NSRect(x: 236, y: 22, width: 200, height: 128)
        drawDisplay(external, lit: true)

        drawCursor(at: NSPoint(x: external.midX + 30, y: external.midY - 12))

        // The brightness pill, top-right of the external display
        let pill = NSRect(
            x: external.maxX - 96, y: external.maxY - 34, width: 86, height: 24)
        let pillPath = NSBezierPath(roundedRect: pill, xRadius: 9, yRadius: 9)
        NSColor.white.withAlphaComponent(0.25).setFill()
        pillPath.fill()
        NSColor.white.withAlphaComponent(0.45).setStroke()
        pillPath.lineWidth = 1
        pillPath.stroke()

        // Sun dot + brightness track
        let sun = NSRect(x: pill.minX + 8, y: pill.midY - 4, width: 8, height: 8)
        NSColor.white.withAlphaComponent(0.9).setFill()
        NSBezierPath(ovalIn: sun).fill()
        let track = NSRect(x: pill.minX + 24, y: pill.midY - 2, width: 54, height: 4)
        NSColor.white.withAlphaComponent(0.25).setFill()
        NSBezierPath(roundedRect: track, xRadius: 2, yRadius: 2).fill()
        var fill = track
        fill.size.width = 36
        NSColor.white.setFill()
        NSBezierPath(roundedRect: fill, xRadius: 2, yRadius: 2).fill()
    }

    private func drawDisplay(_ frame: NSRect, lit: Bool) {
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 10
        shadow.shadowOffset = NSSize(width: 0, height: -4)
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.45)

        NSGraphicsContext.current?.saveGraphicsState()
        shadow.set()
        let body = NSBezierPath(roundedRect: frame, xRadius: 8, yRadius: 8)
        NSColor(white: 0.1, alpha: 1).setFill()
        body.fill()
        NSGraphicsContext.current?.restoreGraphicsState()

        // Screen glow: the lit display is visibly brighter
        let screen = NSBezierPath(
            roundedRect: frame.insetBy(dx: 5, dy: 5), xRadius: 5, yRadius: 5)
        NSGradient(
            starting: NSColor(srgbRed: 1, green: 0.78, blue: 0.35, alpha: lit ? 0.85 : 0.3),
            ending: NSColor(srgbRed: 0.9, green: 0.5, blue: 0.15, alpha: lit ? 0.6 : 0.2)
        )?.draw(in: screen, angle: -90)
    }

    private func drawCursor(at point: NSPoint) {
        let cursor = NSBezierPath()
        cursor.move(to: point)
        cursor.line(to: NSPoint(x: point.x, y: point.y - 15))
        cursor.line(to: NSPoint(x: point.x + 4.2, y: point.y - 11))
        cursor.line(to: NSPoint(x: point.x + 10.5, y: point.y - 11.5))
        cursor.close()
        NSColor.white.setFill()
        cursor.fill()
        NSColor.black.withAlphaComponent(0.6).setStroke()
        cursor.lineWidth = 1
        cursor.stroke()
    }
}
