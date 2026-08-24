import AppKit

/* Replica of the macOS 26 brightness indicator, shown for redirected key
   presses. macOS only draws its own HUD (rendered by MenuBarAgent since
   Tahoe) for presses it handles itself, and the OSDManager private API that
   used to let apps summon it is a no-op now — so Transom draws its own,
   on the display whose brightness actually changed.

   The layout replicates the native indicator, measured from window
   captures of the real one: a 279×66 Liquid Glass pill under the menu bar
   at the top-right — display name on top, then a slider row of small/large
   sun icons flanking a 4pt bar with a row of 16 faint tick dots beneath.

   One panel is reused across displays and presses: a press moves/reveals
   it, updates the level instantly (autorepeat must not queue animations),
   and re-arms the fade-out. */
final class BrightnessHUD {
    private static let pillSize = NSSize(width: 279, height: 66)
    private static let cornerRadius: CGFloat = 26
    private static let contentInset: CGFloat = 16
    /* Native placement: flush with the menu bar's bottom edge plus a small
       gap, 16pt off the display's right edge. */
    private static let topMargin: CGFloat = 8
    private static let holdDuration: TimeInterval = 1.4
    private static let fadeDuration: TimeInterval = 0.5
    private static let entranceDuration: TimeInterval = 0.45
    private static let entranceScale: CGFloat = 0.85

    private var panel: NSPanel?
    private var glassView: NSGlassEffectView?
    private let titleLabel = NSTextField(labelWithString: "")
    private let trackView = TrackView()
    private var hideTimer: Timer?

    /* The panel is created invisible at launch, ordered in once, and then
       NEVER ordered out — hiding is always alpha-only. Every time the glass
       view (re)attaches to the window server it re-commits the stock
       material, clobbering the tuning for about half a second afterwards;
       keeping the window attached means the material tuned here holds for
       the app's lifetime and the very first key press already shows the
       final glass. */
    /* "Hidden" alpha: at exactly 0 the window server detaches the window
       and the next reveal re-commits stock material again — 1% keeps it
       attached while being imperceptible. */
    private static let hiddenAlpha: CGFloat = 0.01

    init() {
        let panel = makePanel()
        self.panel = panel
        panel.alphaValue = Self.hiddenAlpha
        panel.orderFrontRegardless()
        for delay in [0.7, 1.4] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.tuneGlassMaterial()
            }
        }
    }

    func show(value: Float, on display: CGDirectDisplayID) {
        guard
            let screen = NSScreen.screens.first(where: { candidate in
                (candidate.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                    as? NSNumber)?.uint32Value == display
            })
        else { return }

        let panel = self.panel ?? makePanel()
        self.panel = panel

        /* visibleFrame already excludes the menu bar, so maxY is right
           below it — where the native indicator sits. */
        let visible = screen.visibleFrame
        panel.setFrameOrigin(
            NSPoint(
                x: visible.maxX - Self.pillSize.width - Self.contentInset,
                y: visible.maxY - Self.pillSize.height - Self.topMargin
            ))

        titleLabel.stringValue = screen.localizedName
        trackView.value = value

        /* Fresh appearances get the native pop-in; a press while the HUD
           is still visible (autorepeat, or mid-fade) just snaps it back —
           via a zero-duration animator write, which replaces any in-flight
           fade-out where a plain alphaValue assignment would race it. */
        if panel.alphaValue <= Self.hiddenAlpha {
            animateEntrance(panel)
        } else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                panel.animator().alphaValue = 1
            }
        }
        panel.orderFrontRegardless()
        /* Re-applied on every show, twice more shortly after: the view
           re-commits its stock material to the render server around
           visibility changes (without touching the model values), so the
           tuning must land again after that commit has gone through. */
        tuneGlassMaterial()
        for delay in [0.3, 0.7] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.tuneGlassMaterial()
            }
        }

        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(
            withTimeInterval: Self.holdDuration, repeats: false
        ) { [weak self] _ in
            self?.fadeOut()
        }
    }

    /* The entrance: a fade riding a scale-up from the pill's center. A
       strongly decelerating cubic (easeOutQuint-like) — fast enough off the
       mark that autorepeat doesn't feel laggy, gliding to a stop with no
       overshoot. */
    private static let entranceEasing = CAMediaTimingFunction(
        controlPoints: 0.22, 1, 0.36, 1)

    private func animateEntrance(_ panel: NSPanel) {
        if let layer = panel.contentView?.layer {
            let centerX = Self.pillSize.width / 2
            let centerY = Self.pillSize.height / 2
            var from = CATransform3DMakeTranslation(centerX, centerY, 0)
            from = CATransform3DScale(from, Self.entranceScale, Self.entranceScale, 1)
            from = CATransform3DTranslate(from, -centerX, -centerY, 0)

            let scale = CABasicAnimation(keyPath: "transform")
            scale.fromValue = NSValue(caTransform3D: from)
            scale.toValue = NSValue(caTransform3D: CATransform3DIdentity)
            scale.duration = Self.entranceDuration
            scale.timingFunction = Self.entranceEasing
            layer.add(scale, forKey: "entrance")
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.entranceDuration
            context.timingFunction = Self.entranceEasing
            panel.animator().alphaValue = 1
        }
    }

    /* Alpha-only, and never quite to zero: ordering out or full
       transparency both reset the tuned material (see init). */
    private func fadeOut() {
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.fadeDuration
            panel.animator().alphaValue = Self.hiddenAlpha
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.pillSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        /* The native indicator casts no shadow — and the system shadow
           also paints a 1px dark contour on the window boundary, which
           would sit over the rim highlight. */
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        /* The glass material's scrim follows the appearance, but the native
           HUD adapts to its backdrop, not the system mode (its content stays
           white either way). The replica's colors were calibrated against
           captures of the real HUD under the light appearance, so pin it —
           otherwise dark mode would double-darken the glass. */
        panel.appearance = NSAppearance(named: .aqua)
        /* Above regular windows and the menu bar, visible over full-screen
           apps and on every Space — matching where the native HUD lives. */
        panel.level = .screenSaver
        panel.collectionBehavior = [
            .canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle,
        ]

        let content = NSView()

        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .white
        titleLabel.lineBreakMode = .byTruncatingTail

        let minSun = sunImageView("sun.min", pointSize: 11)
        let maxSun = sunImageView("sun.max", pointSize: 15)

        for view in [titleLabel, minSun, trackView, maxSun] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        /* The slider bar's centerline sits 41.5pt below the pill's top in
           the native indicator; TrackView puts the bar in its top 4pt, so
           its top anchors at 39.5 and the icons center on 41.5. */
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: content.topAnchor, constant: 11),
            titleLabel.leadingAnchor.constraint(
                equalTo: content.leadingAnchor, constant: Self.contentInset),
            titleLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: content.trailingAnchor, constant: -Self.contentInset),

            minSun.leadingAnchor.constraint(
                equalTo: content.leadingAnchor, constant: Self.contentInset),
            minSun.centerYAnchor.constraint(equalTo: content.topAnchor, constant: 41.5),
            maxSun.trailingAnchor.constraint(
                equalTo: content.trailingAnchor, constant: -Self.contentInset),
            maxSun.centerYAnchor.constraint(equalTo: content.topAnchor, constant: 41.5),

            trackView.leadingAnchor.constraint(equalTo: minSun.trailingAnchor, constant: 8),
            trackView.trailingAnchor.constraint(equalTo: maxSun.leadingAnchor, constant: -8),
            trackView.topAnchor.constraint(equalTo: content.topAnchor, constant: 39.5),
            trackView.heightAnchor.constraint(equalToConstant: TrackView.height),
        ])

        let glass = NSGlassEffectView(frame: NSRect(origin: .zero, size: Self.pillSize))
        glass.style = .clear
        glass.cornerRadius = Self.cornerRadius
        glass.contentView = content
        glassView = glass

        let container = NSView(frame: NSRect(origin: .zero, size: Self.pillSize))
        container.wantsLayer = true
        container.addSubview(glass)
        /* A sibling ABOVE the glass view: the glass draws its own edge
           treatment over its contentView, so a line inside the content
           could never sit on the boundary. */
        container.addSubview(RimView(frame: container.bounds))
        panel.contentView = container
        return panel
    }

    /* Tunes the glass material — anchored on the real HUD's transfer
       (captured over pure white and pure black backdrops, ≈219 and ≈51 vs
       .clear's 244/71), then deliberately pushed clearer and more liquid
       than native. The material is a private "glassBackground" filter on a
       backdrop layer inside NSGlassEffectView; its face color matrix maps
       backdrop luminance as out = black + (white − black) · in, and .clear
       ships white 0.95 / black 0.2 plus a 10% white fill (the native HUD
       corresponds to white 0.86, fill dropped). The stock blur radius is
       6.25. Values must be set through the layer's filter key path —
       mutating the filter object directly never reaches the render server.

       The backdrop layer only exists a runloop turn or two after the panel
       first comes on screen, so retry briefly before falling back. If the
       private structure ever changes, the fallback is a black tint that
       approximates the same transfer (≈220/64). */
    private func tuneGlassMaterial(attempt: Int = 0) {
        guard let glassView else { return }
        func findBackdropLayer(_ layer: CALayer) -> CALayer? {
            if String(describing: type(of: layer)) == "CABackdropLayer" { return layer }
            for sublayer in layer.sublayers ?? [] {
                if let found = findBackdropLayer(sublayer) { return found }
            }
            return nil
        }
        guard
            let layer = glassView.layer,
            let backdrop = findBackdropLayer(layer),
            (backdrop.filters?.first as? NSObject)?.value(forKey: "name") as? String
                == "glassBackground"
        else {
            if attempt < 5 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                    self?.tuneGlassMaterial(attempt: attempt + 1)
                }
            } else {
                glassView.tintColor = .black.withAlphaComponent(0.05)
            }
            return
        }
        glassView.tintColor = nil
        /* An imperceptible epsilon toggled per application: Core Animation
           only commits a filter value when the model actually changes, and
           the view's stock re-commit resets the render server WITHOUT
           touching the model — re-setting an identical value would be
           silently dropped and the stock material would stay visible. */
        tuneEpsilonFlip.toggle()
        let epsilon = tuneEpsilonFlip ? 1e-6 : 0.0
        /* Clearer than the native HUD's material: the face transfer
           out = black + (white − black) · in is pushed toward identity
           (native tuning was white 0.86 / stock black 0.2), so the backdrop
           passes through nearly unchanged, and the blur is all but removed
           so the refracted backdrop stays crisp instead of frosted. */
        backdrop.setValue(
            0.90 + epsilon, forKeyPath: "filters.glassBackground.inputFaceColorMatrixWhite")
        backdrop.setValue(
            0.06 + epsilon, forKeyPath: "filters.glassBackground.inputFaceColorMatrixBlack")
        /* Legibility on light backdrops without smoking the whole face:
           cap the luminance the backdrop can reach through the glass
           (stock is 1 — uncapped). Only near-white content is pulled down
           to the cap; everything below it keeps the clear transfer above. */
        backdrop.setValue(
            0.86 + epsilon, forKeyPath: "filters.glassBackground.inputFaceColorMatrixMaxLuma")
        backdrop.setValue(
            0.86 + epsilon,
            forKeyPath: "filters.glassBackground.inputFaceColorMatrixMaxLumaSDR")
        backdrop.setValue(
            NSColor.white.withAlphaComponent(0).cgColor,
            forKeyPath: "filters.glassBackground.inputFaceColorMatrixFillColor")
        backdrop.setValue(
            0.25 + epsilon, forKeyPath: "filters.glassBackground.inputBlurRadius")
        /* Deliberately past the stock .clear material for a more liquid
           edge: the inner refraction (backdrop bending along the rim) ships
           at amount -39 over a 20pt band — deepen and widen it — and the
           material's own specular sheen ("key fill highlight") ships at
           0.4. */
        backdrop.setValue(
            -60.0 + epsilon,
            forKeyPath: "filters.glassBackground.inputInnerRefractionAmount")
        backdrop.setValue(
            26.0 + epsilon,
            forKeyPath: "filters.glassBackground.inputInnerRefractionHeight")
        backdrop.setValue(
            0.65 + epsilon,
            forKeyPath: "filters.glassBackground.inputKeyFillHighlightAmount")
    }

    private var tuneEpsilonFlip = false

    /* No shadows anywhere: zoomed captures of the real indicator show its
       white content plain on the glass, even over light backdrops. */
    private func sunImageView(_ symbolName: String, pointSize: CGFloat) -> NSImageView {
        let view = NSImageView()
        view.image = NSImage(
            systemSymbolName: symbolName, accessibilityDescription: "Brightness"
        )?.withSymbolConfiguration(.init(pointSize: pointSize, weight: .regular))
        view.contentTintColor = .white
        return view
    }

    /* The specular rim on the pill's border, sampled from edge scans of
       the real indicator: a thin bright line along the top and bottom
       (the light "comes from above", so the bottom is weaker) that blends
       around the corner arcs into the faint dark line running down the
       sides. The bright line is drawn additively ("plusL"), which is what
       makes it track the backdrop the way the native one does — brilliant
       over light content (255 vs native 246+) and subdued over dark
       (≈125) — where any fixed-alpha white could only match one of the
       two. Both lines are strokes masked by vertical gradients whose fades
       overlap through the corner arcs, cross-blending the two instead of
       meeting them at a seam; at mid-height the border consists of nothing
       but the straight sides, so the dark line needs no horizontal
       constraint at all. */
    private final class RimView: NSView {
        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true

            /* Strokes centered on the bounds path; the outer halves are
               clipped off by the layer mask so nothing spills onto the
               desktop around the pill. */
            let path = CGPath(
                roundedRect: bounds,
                cornerWidth: BrightnessHUD.cornerRadius,
                cornerHeight: BrightnessHUD.cornerRadius,
                transform: nil
            )
            let clip = CAShapeLayer()
            clip.frame = bounds
            clip.path = path
            clip.fillColor = NSColor.white.cgColor
            layer?.mask = clip

            func line(
                width: CGFloat, colors: [NSColor], locations: [NSNumber], compositing: String?
            ) -> CAGradientLayer {
                let strokeMask = CAShapeLayer()
                strokeMask.frame = bounds
                strokeMask.path = path
                strokeMask.fillColor = nil
                strokeMask.strokeColor = NSColor.white.cgColor
                strokeMask.lineWidth = width

                let gradient = CAGradientLayer()
                gradient.frame = bounds
                /* Unflipped layer space: start (0.5, 1) is the top edge. */
                gradient.startPoint = CGPoint(x: 0.5, y: 1)
                gradient.endPoint = CGPoint(x: 0.5, y: 0)
                gradient.colors = colors.map(\.cgColor)
                gradient.locations = locations
                gradient.mask = strokeMask
                gradient.compositingFilter = compositing
                return gradient
            }

            let clear = NSColor.white.withAlphaComponent(0)
            let dark = line(
                width: 2.0,
                colors: [
                    clear, .black.withAlphaComponent(0.12),
                    .black.withAlphaComponent(0.12), clear,
                ],
                locations: [0.18, 0.42, 0.58, 0.82],
                compositing: nil)
            /* The glassiness of the rim comes from a faint glow bleeding
               ~6pt inward from the crisp line (edge scans show a soft decay
               below it, not a hard stop). Three nested strokes of decreasing
               alpha approximate that decay — additive, so they sum near the
               edge and thin out inward. Deliberately pushed past the native
               levels: the glow never fully dies mid-height, so a faint sheen
               carries through the sides and the corners read as one
               continuous reflection instead of two separate highlights. */
            let glows = zip([5.0, 8.0, 12.0], [0.08, 0.06, 0.04]).map { width, alpha in
                line(
                    width: width,
                    colors: [
                        .white.withAlphaComponent(alpha),
                        .white.withAlphaComponent(alpha * 0.25),
                        .white.withAlphaComponent(alpha * 0.25),
                        .white.withAlphaComponent(alpha * 0.7),
                    ],
                    locations: [0, 0.38, 0.62, 1],
                    compositing: "plusL")
            }
            let bright = line(
                width: 2.0,
                colors: [
                    .white.withAlphaComponent(0.60),
                    .white.withAlphaComponent(0.10),
                    .white.withAlphaComponent(0.10),
                    .white.withAlphaComponent(0.42),
                ],
                locations: [0, 0.38, 0.62, 1],
                compositing: "plusL")
            layer?.addSublayer(dark)
            for glow in glows { layer?.addSublayer(glow) }
            layer?.addSublayer(bright)
        }

        required init?(coder: NSCoder) { fatalError("unused") }
    }

    /* The native slider: a 4pt rounded bar — pure-white fill, faint
       remainder — with 17 tick dots (16 steps' boundaries) floating 2pt
       below it. Colors are fixed, not semantic: the native HUD keeps white
       content on any backdrop, and the exact levels are sampled from
       window captures of the real indicator. */
    private final class TrackView: NSView {
        static let barHeight: CGFloat = 4
        static let tickDiameter: CGFloat = 2
        static let tickGap: CGFloat = 2
        static let height = barHeight + tickGap + tickDiameter
        static let tickCount = 17

        var value: Float = 0 {
            didSet { needsDisplay = true }
        }

        override func draw(_ dirtyRect: NSRect) {
            /* Unflipped coordinates: the bar hugs the view's top edge. */
            let bar = NSRect(
                x: 0, y: bounds.height - Self.barHeight,
                width: bounds.width, height: Self.barHeight)
            let radius = Self.barHeight / 2

            NSColor.white.withAlphaComponent(0.10).setFill()
            NSBezierPath(roundedRect: bar, xRadius: radius, yRadius: radius).fill()

            /* Never shrink below a dot: brightness 0 should still read as
               "the far-left end", not an empty track. */
            var fill = bar
            fill.size.width = max(Self.barHeight, bar.width * CGFloat(value))
            NSColor.white.setFill()
            NSBezierPath(roundedRect: fill, xRadius: radius, yRadius: radius).fill()

            NSColor.white.withAlphaComponent(0.13).setFill()
            let tickY = bar.minY - Self.tickGap - Self.tickDiameter
            let usable = bounds.width - 2 * radius - Self.tickDiameter
            for tick in 0..<Self.tickCount {
                let centerX =
                    radius + Self.tickDiameter / 2
                    + usable * CGFloat(tick) / CGFloat(Self.tickCount - 1)
                NSBezierPath(
                    ovalIn: NSRect(
                        x: centerX - Self.tickDiameter / 2, y: tickY,
                        width: Self.tickDiameter, height: Self.tickDiameter)
                ).fill()
            }
        }
    }
}
