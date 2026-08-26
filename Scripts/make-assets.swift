#!/usr/bin/env swift
// Generates the app icon (Assets/AppIcon.iconset/*.png + icon-1024.png) and
// the README banner (Assets/banner.png) programmatically, so the artwork is
// reproducible from source. Run: swift Scripts/make-assets.swift
// Then:  iconutil -c icns Assets/AppIcon.iconset -o Assets/AppIcon.icns
//
// Styled after macOS Tahoe's Liquid Glass icon language, sibling to Oriel's
// icon: the same continuous-curvature squircle, frosted-glass panels (real
// gaussian-blurred backdrop via CoreImage), specular rim highlights, and soft
// layered shadows — but on a warm sunlight gradient, with a sun glyph on the
// front display pane (brightness, on the display under your cursor).

import AppKit
import CoreImage
import SwiftUI

// MARK: - Helpers

let ciContext = CIContext()

func makeBitmap(_ w: Int, _ h: Int) -> NSBitmapImageRep {
    NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
}

func withContext(_ rep: NSBitmapImageRep, _ draw: (CGContext) -> Void) {
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ctx
    draw(ctx.cgContext)
    NSGraphicsContext.current = nil
}

func savePNG(_ rep: NSBitmapImageRep, _ path: String) {
    let data = rep.representation(using: .png, properties: [:])!
    try! data.write(to: URL(fileURLWithPath: path))
    print("wrote \(path)")
}

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        red: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

let rgb = CGColorSpaceCreateDeviceRGB()

func linearGradient(_ cg: CGContext, in path: CGPath, colors: [CGColor], from: CGPoint, to: CGPoint) {
    cg.saveGState()
    cg.addPath(path)
    cg.clip()
    let grad = CGGradient(colorsSpace: rgb, colors: colors as CFArray, locations: nil)!
    cg.drawLinearGradient(grad, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    cg.restoreGState()
}

/// The macOS app-icon silhouette: a continuous-corner rounded rect (straight
/// edges, Apple's smooth corner curve) — not a superellipse, whose sides
/// bulge. Radius fitted against the system's live icon mask (measured from
/// Calculator/Notes/Finder at 1024px: 214.5px on the 824px shape, ~0.16px RMS).
func squircle(in rect: CGRect) -> CGPath {
    Path(roundedRect: rect, cornerRadius: rect.width * (214.5 / 824), style: .continuous).cgPath
}

/// Sun silhouette: core disc + 8 rounded rays, as one fillable path.
func sunPath(center: CGPoint, core: CGFloat, rayInner: CGFloat, rayOuter: CGFloat, rayWidth: CGFloat) -> CGPath {
    let path = CGMutablePath()
    path.addEllipse(in: CGRect(
        x: center.x - core, y: center.y - core, width: core * 2, height: core * 2))
    let rays = CGMutablePath()
    for i in 0..<8 {
        let a = CGFloat(i) / 8 * 2 * .pi
        rays.move(to: CGPoint(x: center.x + cos(a) * rayInner, y: center.y + sin(a) * rayInner))
        rays.addLine(to: CGPoint(x: center.x + cos(a) * rayOuter, y: center.y + sin(a) * rayOuter))
    }
    path.addPath(rays.copy(strokingWithWidth: rayWidth, lineCap: .round, lineJoin: .round, miterLimit: 10))
    return path
}

func gaussianBlur(_ image: CGImage, radius: CGFloat) -> CGImage {
    let ci = CIImage(cgImage: image)
    let blurred = ci.clampedToExtent()
        .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
        .cropped(to: ci.extent)
    return ciContext.createCGImage(blurred, from: ci.extent)!
}

// MARK: - Icon (designed in a 1024x1024 space, bottom-left origin)

let designRect = CGRect(x: 0, y: 0, width: 1024, height: 1024)
let bgRect = CGRect(x: 100, y: 100, width: 824, height: 824) // standard macOS icon grid

/// Background layer: squircle, warm sunlight gradient, top sheen, outer shadow.
func drawIconBackground(_ cg: CGContext) {
    let shape = squircle(in: bgRect)

    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -12), blur: 36, color: color(0x000000, 0.28))
    cg.addPath(shape)
    cg.setFillColor(color(0xE8720F))
    cg.fillPath()
    cg.restoreGState()

    // A single restrained golden-hour gradient, in the language of macOS
    // system icons: the background recedes, the glyph is the hero.
    linearGradient(
        cg, in: shape,
        colors: [color(0xFFC94F), color(0xF07014)],
        from: CGPoint(x: 512, y: bgRect.maxY), to: CGPoint(x: 512, y: bgRect.minY)
    )
    // Barely-there top light for depth
    linearGradient(
        cg, in: shape,
        colors: [color(0xFFFFFF, 0.12), color(0xFFFFFF, 0)],
        from: CGPoint(x: 512, y: bgRect.maxY), to: CGPoint(x: 512, y: bgRect.maxY - 320)
    )
}

/// Specular rim: a stroke around `path` that is bright on top, fading below.
func glassRim(_ cg: CGContext, around path: CGPath, width: CGFloat, bounds: CGRect, top: CGFloat, bottom: CGFloat) {
    let stroked = path.copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 10)
    linearGradient(
        cg, in: stroked,
        colors: [color(0xFFFFFF, top), color(0xFFFFFF, bottom)],
        from: CGPoint(x: bounds.midX, y: bounds.maxY), to: CGPoint(x: bounds.midX, y: bounds.minY)
    )
}

/// One frosted-glass display pane: blurred backdrop, milky tint, specular rim.
func drawGlassPane(
    _ cg: CGContext, rect: CGRect, backdrop: CGImage,
    tintTop: CGFloat, tintBottom: CGFloat,
    rimWidth: CGFloat, rimTop: CGFloat, rimBottom: CGFloat,
    shadowBlur: CGFloat, shadowAlpha: CGFloat
) {
    let path = CGPath(roundedRect: rect, cornerWidth: 56, cornerHeight: 56, transform: nil)

    // Drop shadow (opaque fill, replaced by the glass interior right after)
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -shadowBlur * 0.4), blur: shadowBlur, color: color(0x54240A, shadowAlpha))
    cg.addPath(path)
    cg.setFillColor(color(0xF3B26B))
    cg.fillPath()
    cg.restoreGState()

    // Blurred backdrop + milky tint
    cg.saveGState()
    cg.addPath(path)
    cg.clip()
    cg.draw(backdrop, in: designRect)
    linearGradient(
        cg, in: path,
        colors: [color(0xFFFFFF, tintTop), color(0xFFFFFF, tintBottom)],
        from: CGPoint(x: rect.midX, y: rect.maxY), to: CGPoint(x: rect.midX, y: rect.minY)
    )
    cg.restoreGState()

    glassRim(cg, around: path, width: rimWidth, bounds: rect, top: rimTop, bottom: rimBottom)
}

// The glyph: two displays — a dim ghost pane behind, the display under the
// cursor arrived bright in front, carrying the sun. Same composition as
// Oriel's two window panes, so the apps read as siblings side by side.
let backPane = CGRect(x: 220, y: 430, width: 420, height: 330)
let frontPane = CGRect(x: 350, y: 260, width: 440, height: 340)

func drawBackPane(_ cg: CGContext, backdrop: CGImage, boost: Bool) {
    drawGlassPane(
        cg, rect: backPane, backdrop: backdrop,
        tintTop: boost ? 0.52 : 0.4, tintBottom: boost ? 0.4 : 0.26,
        rimWidth: 4, rimTop: 0.7, rimBottom: 0.12,
        shadowBlur: 30, shadowAlpha: 0.22
    )
}

func drawFrontPane(_ cg: CGContext, backdrop: CGImage, boost: Bool) {
    drawGlassPane(
        cg, rect: frontPane, backdrop: backdrop,
        tintTop: boost ? 0.98 : 0.94, tintBottom: boost ? 0.94 : 0.85,
        rimWidth: 5, rimTop: 1.0, rimBottom: 0.3,
        shadowBlur: 46, shadowAlpha: 0.32
    )

    drawScreenSun(cg)
}

/// The sun on the front pane. Shared between the rendered icon and the flat
/// Icon Composer layers. Flat two-stop gradient, no gloss — like the traffic
/// lights on Oriel's front pane, it should feel native, not skeuomorphic.
func drawScreenSun(_ cg: CGContext) {
    let center = CGPoint(x: frontPane.midX, y: frontPane.midY)
    let sun = sunPath(center: center, core: 54, rayInner: 86, rayOuter: 118, rayWidth: 27)
    linearGradient(
        cg, in: sun,
        colors: [color(0xFFB545), color(0xF2680E)],
        from: CGPoint(x: center.x, y: center.y + 132),
        to: CGPoint(x: center.x, y: center.y - 132)
    )
}

/// Renders the complete icon at `px` and returns the bitmap.
func makeIcon(px: Int) -> NSBitmapImageRep {
    let scale = CGFloat(px) / 1024
    let blurRadius = max(36 * scale, 1)
    // Small sizes: more opaque panes keep the glyph legible in the menu bar /
    // Dock, where the frosted subtlety would just vanish.
    let boost = px <= 64

    let bgRep = makeBitmap(px, px)
    withContext(bgRep) { cg in
        cg.scaleBy(x: scale, y: scale)
        drawIconBackground(cg)
    }
    let backdrop = gaussianBlur(bgRep.cgImage!, radius: blurRadius)

    // Intermediate scene (background + back pane), so the front pane's
    // backdrop blur includes the ghost pane behind it — glass over glass.
    let shape = squircle(in: bgRect)

    /* Clip the panes to the squircle, and at small sizes optically enlarge
       the glyph (like Apple's small-size icon variants) so it stays
       prominent in the menu bar / Dock. */
    func drawPanes(_ cg: CGContext, _ body: (CGContext) -> Void) {
        cg.saveGState()
        cg.addPath(shape)
        cg.clip()
        if boost {
            cg.translateBy(x: 512, y: 512)
            cg.scaleBy(x: 1.14, y: 1.14)
            cg.translateBy(x: -512, y: -512)
        }
        body(cg)
        cg.restoreGState()
    }

    let midRep = makeBitmap(px, px)
    withContext(midRep) { cg in
        cg.scaleBy(x: scale, y: scale)
        cg.draw(bgRep.cgImage!, in: designRect)
        drawPanes(cg) { drawBackPane($0, backdrop: backdrop, boost: boost) }
    }
    let midBackdrop = gaussianBlur(midRep.cgImage!, radius: blurRadius)

    let rep = makeBitmap(px, px)
    withContext(rep) { cg in
        cg.scaleBy(x: scale, y: scale)
        cg.draw(midRep.cgImage!, in: designRect)
        drawPanes(cg) { drawFrontPane($0, backdrop: midBackdrop, boost: boost) }
    }
    return rep
}

// MARK: - Icon Composer layers (macOS 26+ .icon document)

/* The .icon format gets dark/clear/tinted appearances for free: we ship flat
   transparent layers plus a background fill, and the system renders the
   Liquid Glass treatment (and the dark background) at runtime. In a .icon
   document the 1024pt canvas IS the icon shape — the system adds its own
   margins — whereas our design space puts the squircle at 100..924, so the
   panes are remapped to land at the same visual position. */
func makeIconLayer(_ draw: (CGContext) -> Void) -> NSBitmapImageRep {
    let rep = makeBitmap(1024, 1024)
    withContext(rep) { cg in
        cg.scaleBy(x: 1024 / 824, y: 1024 / 824)
        cg.translateBy(x: -100, y: -100)
        draw(cg)
    }
    return rep
}

func drawFlatBackPane(_ cg: CGContext) {
    cg.addPath(CGPath(roundedRect: backPane, cornerWidth: 56, cornerHeight: 56, transform: nil))
    cg.setFillColor(color(0xFFFFFF, 0.4))
    cg.fillPath()
}

func drawFlatFrontPane(_ cg: CGContext) {
    cg.addPath(CGPath(roundedRect: frontPane, cornerWidth: 56, cornerHeight: 56, transform: nil))
    cg.setFillColor(color(0xFFFFFF))
    cg.fillPath()
    drawScreenSun(cg)
}

// MARK: - Shared banner elements

/// A faint decorative sun outline: ring + detached ray ticks.
func decorativeSun(_ cg: CGContext, center: CGPoint, radius: CGFloat, alpha: CGFloat, lineWidth: CGFloat) {
    cg.setStrokeColor(color(0xFFFFFF, alpha))
    cg.setLineWidth(lineWidth)
    cg.setLineCap(.round)
    cg.strokeEllipse(in: CGRect(
        x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
    for i in 0..<8 {
        let a = CGFloat(i) / 8 * 2 * .pi + .pi / 8
        cg.move(to: CGPoint(
            x: center.x + cos(a) * radius * 1.35, y: center.y + sin(a) * radius * 1.35))
        cg.addLine(to: CGPoint(
            x: center.x + cos(a) * radius * 1.6, y: center.y + sin(a) * radius * 1.6))
        cg.strokePath()
    }
}

/// A small solid sun glyph for the keycap pills (F1 dim / F2 bright).
func pillSun(_ cg: CGContext, center: CGPoint, core: CGFloat, rayInner: CGFloat, rayOuter: CGFloat, rayWidth: CGFloat, color c: CGColor) {
    cg.setFillColor(c)
    cg.addPath(sunPath(center: center, core: core, rayInner: rayInner, rayOuter: rayOuter, rayWidth: rayWidth))
    cg.fillPath()
}

let pillLabelColor = NSColor(srgbRed: 0.97, green: 0.87, blue: 0.70, alpha: 1)
let taglineColor = NSColor(srgbRed: 0.91, green: 0.81, blue: 0.65, alpha: 1)
let tagline = "Cursor-aware brightness controller for macOS"

enum PillSunStyle {
    case dim
    case bright
}

private func pillText(_ label: String, fontSize: CGFloat) -> NSAttributedString {
    NSAttributedString(string: label, attributes: [
        .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
        .foregroundColor: pillLabelColor,
    ])
}

/// Width of a keycap pill, computed (not measured by drawing — a nested
/// bitmap context would clear NSGraphicsContext.current mid-render and
/// silently drop every text draw after it).
func sunPillWidth(label: String, fontSize: CGFloat, sunScale: CGFloat, sun: PillSunStyle?) -> CGFloat {
    let pad = 22 * sunScale
    let gap = 14 * sunScale
    let sunSlot: CGFloat =
        switch sun {
        case .bright: 15 * sunScale * 2 + gap
        case .dim: 11 * sunScale * 2 + gap
        case nil: 0
        }
    return pad + sunSlot + pillText(label, fontSize: fontSize).size().width + pad
}

/// One keycap pill with an optional sun glyph and a key label; returns maxX.
@discardableResult
func drawSunPill(
    _ cg: CGContext, x: CGFloat, y: CGFloat, height: CGFloat, label: String,
    fontSize: CGFloat, sunScale: CGFloat, sun: PillSunStyle?
) -> CGFloat {
    let text = pillText(label, fontSize: fontSize)
    let pad = 22 * sunScale
    let gap = 14 * sunScale
    let width = sunPillWidth(label: label, fontSize: fontSize, sunScale: sunScale, sun: sun)
    let pill = CGRect(x: x, y: y, width: width, height: height)

    cg.addPath(CGPath(roundedRect: pill, cornerWidth: height / 4, cornerHeight: height / 4, transform: nil))
    cg.setFillColor(color(0xFFFFFF, 0.07))
    cg.fillPath()
    cg.addPath(CGPath(roundedRect: pill.insetBy(dx: 1.5, dy: 1.5), cornerWidth: height / 4 - 1, cornerHeight: height / 4 - 1, transform: nil))
    cg.setStrokeColor(color(0xFFFFFF, 0.14))
    cg.setLineWidth(2.5)
    cg.strokePath()

    var textX = pill.minX + pad
    if let sun {
        let sunRadius = (sun == .bright ? 15.0 : 11.0) * sunScale
        let sunCenter = CGPoint(x: pill.minX + pad + sunRadius, y: pill.midY)
        switch sun {
        case .bright:
            pillSun(
                cg, center: sunCenter, core: 6.5 * sunScale, rayInner: 10 * sunScale,
                rayOuter: 15 * sunScale, rayWidth: 3.2 * sunScale, color: pillLabelColor.cgColor)
        case .dim:
            pillSun(
                cg, center: sunCenter, core: 5 * sunScale, rayInner: 7.5 * sunScale,
                rayOuter: 11 * sunScale, rayWidth: 2.6 * sunScale, color: pillLabelColor.cgColor)
        }
        textX = sunCenter.x + sunRadius + gap
    }
    text.draw(at: NSPoint(x: textX, y: pill.minY + (pill.height - text.size().height) / 2))
    return pill.maxX
}

// MARK: - Banner (1800 x 600)

func drawBanner(_ cg: CGContext, icon: CGImage) {
    let canvas = CGRect(x: 0, y: 0, width: 1800, height: 600)
    let frame = CGPath(roundedRect: canvas, cornerWidth: 40, cornerHeight: 40, transform: nil)
    // Same dark navy as Oriel's banner: the apps are siblings, and the warm
    // icon is the complementary accent against it.
    linearGradient(
        cg, in: frame,
        colors: [color(0x33250E), color(0x191106)],
        from: CGPoint(x: canvas.midX, y: canvas.maxY), to: CGPoint(x: canvas.midX, y: canvas.minY)
    )

    // Faint decorative suns drifting off the right edge
    cg.saveGState()
    cg.addPath(frame)
    cg.clip()
    decorativeSun(cg, center: CGPoint(x: 1560, y: 400), radius: 120, alpha: 0.07, lineWidth: 3)
    decorativeSun(cg, center: CGPoint(x: 1350, y: 90), radius: 70, alpha: 0.06, lineWidth: 2.5)
    decorativeSun(cg, center: CGPoint(x: 1760, y: 110), radius: 90, alpha: 0.05, lineWidth: 3)
    cg.restoreGState()

    // App icon on the left
    cg.draw(icon, in: CGRect(x: 100, y: 118, width: 364, height: 364))

    // Wordmark + tagline
    let title = NSAttributedString(string: "Transom", attributes: [
        .font: NSFont.systemFont(ofSize: 130, weight: .bold),
        .foregroundColor: NSColor.white,
    ])
    title.draw(at: NSPoint(x: 520, y: 300))

    let taglineText = NSAttributedString(string: tagline, attributes: [
        .font: NSFont.systemFont(ofSize: 46, weight: .medium),
        .foregroundColor: taglineColor,
    ])
    taglineText.draw(at: NSPoint(x: 528, y: 218))

    // Brightness keycaps
    var x: CGFloat = 528
    x = drawSunPill(cg, x: x, y: 108, height: 72, label: "F1", fontSize: 36, sunScale: 1.3, sun: .dim) + 22
    x = drawSunPill(cg, x: x, y: 108, height: 72, label: "F2", fontSize: 36, sunScale: 1.3, sun: .bright) + 22
    drawSunPill(cg, x: x, y: 108, height: 72, label: "⌥⇧  fine", fontSize: 36, sunScale: 1.3, sun: nil)
}

// MARK: - GitHub social preview (1280 x 640 design space, rendered @2x)

func drawSocialPreview(_ cg: CGContext, icon: CGImage) {
    let canvas = CGRect(x: 0, y: 0, width: 1280, height: 640)
    // Full bleed — GitHub renders the preview edge to edge and rounds the
    // corners itself, so transparent corners would show through as white.
    linearGradient(
        cg, in: CGPath(rect: canvas, transform: nil),
        colors: [color(0x3B2C12), color(0x191106)],
        from: CGPoint(x: canvas.midX, y: canvas.maxY), to: CGPoint(x: canvas.midX, y: canvas.minY)
    )

    // Faint decorative suns drifting off the corners
    decorativeSun(cg, center: CGPoint(x: 90, y: 560), radius: 90, alpha: 0.06, lineWidth: 2.5)
    decorativeSun(cg, center: CGPoint(x: 250, y: 660), radius: 60, alpha: 0.05, lineWidth: 2)
    decorativeSun(cg, center: CGPoint(x: 1190, y: 80), radius: 100, alpha: 0.06, lineWidth: 2.5)
    decorativeSun(cg, center: CGPoint(x: 1040, y: -40), radius: 65, alpha: 0.05, lineWidth: 2)

    func drawCentered(_ text: NSAttributedString, y: CGFloat) {
        text.draw(at: NSPoint(x: canvas.midX - text.size().width / 2, y: y))
    }

    // Centered stack: icon, wordmark, tagline, brightness keycaps — sized up
    // so the card stays legible at the small sizes link previews render at.
    cg.draw(icon, in: CGRect(x: canvas.midX - 125, y: 355, width: 250, height: 250))

    drawCentered(
        NSAttributedString(string: "Transom", attributes: [
            .font: NSFont.systemFont(ofSize: 100, weight: .bold),
            .foregroundColor: NSColor.white,
        ]), y: 238)

    drawCentered(
        NSAttributedString(string: tagline, attributes: [
            .font: NSFont.systemFont(ofSize: 38, weight: .medium),
            .foregroundColor: taglineColor,
        ]), y: 176)

    let pills: [(label: String, sun: PillSunStyle?)] = [
        ("F1", .dim), ("F2", .bright), ("⌥⇧  fine", nil),
    ]
    let gap: CGFloat = 16
    let widths = pills.map {
        sunPillWidth(label: $0.label, fontSize: 30, sunScale: 1.15, sun: $0.sun)
    }
    var x = canvas.midX - (widths.reduce(0, +) + gap * CGFloat(pills.count - 1)) / 2
    for (pill, width) in zip(pills, widths) {
        drawSunPill(
            cg, x: x, y: 82, height: 62, label: pill.label,
            fontSize: 30, sunScale: 1.15, sun: pill.sun)
        x += width + gap
    }
}

// MARK: - Main

let fm = FileManager.default
try? fm.createDirectory(atPath: "Assets/AppIcon.iconset", withIntermediateDirectories: true)

// Iconset: render each size directly from vectors (crisper than downscaling)
let iconSizes: [(name: String, px: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, px) in iconSizes {
    savePNG(makeIcon(px: px), "Assets/AppIcon.iconset/\(name).png")
}

let master = makeIcon(px: 1024)
savePNG(master, "Assets/icon-1024.png")

// Icon Composer layers for the macOS 26+ .icon document
try? fm.createDirectory(atPath: "Assets/AppIcon.icon/Assets", withIntermediateDirectories: true)
savePNG(makeIconLayer(drawFlatBackPane), "Assets/AppIcon.icon/Assets/back.png")
savePNG(makeIconLayer(drawFlatFrontPane), "Assets/AppIcon.icon/Assets/front.png")

let bannerIcon = makeIcon(px: 728).cgImage!
let banner = makeBitmap(1800, 600)
withContext(banner) { drawBanner($0, icon: bannerIcon) }
savePNG(banner, "Assets/banner.png")

// GitHub social preview: exactly 1280x640, GitHub's recommended size.
let og = makeBitmap(1280, 640)
withContext(og) { cg in
    drawSocialPreview(cg, icon: bannerIcon)
}
savePNG(og, "Assets/og-image.png")
