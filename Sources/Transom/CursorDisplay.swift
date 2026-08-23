import AppKit

/* Resolves which display the mouse cursor is on. NSScreen frames and
   NSEvent.mouseLocation share Cocoa's global space (bottom-left origin of
   the primary screen), so no coordinate flipping is needed here — the only
   subtlety is the containment test itself, kept pure for unit tests. */
enum CursorDisplay {
    /* Index of the frame containing the point. Screen frames tile the
       desktop without overlap, but a point exactly on a shared edge would
       satisfy a naive `contains` for both — the half-open test (min-edge
       inclusive, max-edge exclusive) picks exactly one. A point on no
       screen (possible mid-reconfiguration) falls back to the nearest
       frame center. */
    static func index(of point: CGPoint, in frames: [CGRect]) -> Int? {
        guard !frames.isEmpty else { return nil }
        if let hit = frames.firstIndex(where: { frame in
            point.x >= frame.minX && point.x < frame.maxX
                && point.y >= frame.minY && point.y < frame.maxY
        }) {
            return hit
        }
        return frames.enumerated().min { a, b in
            hypot(a.element.midX - point.x, a.element.midY - point.y)
                < hypot(b.element.midX - point.x, b.element.midY - point.y)
        }?.offset
    }

    /* CGDirectDisplayID of the display under the cursor right now. */
    static func displayIDUnderCursor() -> CGDirectDisplayID? {
        let screens = NSScreen.screens
        guard
            let index = index(of: NSEvent.mouseLocation, in: screens.map(\.frame)),
            let number = screens[index].deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        else { return nil }
        return CGDirectDisplayID(number.uint32Value)
    }
}
