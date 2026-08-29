import AppKit

/* Intercepts the keyboard brightness keys before the system acts on them.

   Brightness keys don't arrive as regular key events — they are
   NX_SYSDEFINED (type 14) system events with subtype 8, the special-key
   channel shared by volume/play/brightness. A CGEventTap in default
   (filtering) mode can consume them, which is what lets Transom redirect
   the adjustment to the display under the cursor instead of the one macOS
   would pick. An active tap requires the Accessibility permission. */
final class BrightnessKeyTap {
    enum Direction: Int {
        case down = -1
        case up = 1
    }

    /* Called for every brightness key press (down + autorepeat). Return
       true to consume the event, false to let the system handle it. The
       matching key-up is consumed the same way so the system never sees
       half of a press. */
    var onKey: ((Direction, _ fine: Bool, _ isDown: Bool) -> Bool)?

    /* Called for presses that arrive ONLY as brightness keycodes (144/145)
       with no NX twin. macOS 26 delivers Bluetooth Magic Keyboard
       brightness keys this way — and itself ignores the keycodes entirely
       (no OSD, no adjustment, not even for the built-in panel), so unlike
       onKey there is no native behavior to defer to: the handler must act
       on whatever display is under the cursor. */
    var onFallbackKey: ((Direction, _ fine: Bool, _ isDown: Bool) -> Void)?

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    private static let nxSysdefined = CGEventType(rawValue: 14)!
    private static let nxSubtypeAuxControl: Int16 = 8
    private static let nxKeyBrightnessUp = 2
    private static let nxKeyBrightnessDown = 3

    /* The plain-key-event leg of a brightness press. */
    private static let keycodeBrightnessUp: Int64 = 144
    private static let keycodeBrightnessDown: Int64 = 145
    /* Hardware that emits both legs (the built-in keyboard) sends them
       within one press-repeat cycle; an NX event older than this belongs
       to some earlier press. */
    private static let auxTwinWindow: TimeInterval = 0.5
    /* How long a keycode-leg press waits for its NX twin before concluding
       it has none and handling the press itself. */
    private static let fallbackDelay: TimeInterval = 0.06
    private var lastAuxTimestamp: TimeInterval = 0

    var isRunning: Bool { tap != nil }

    /* Returns false when the tap can't be created — in practice, when the
       Accessibility permission hasn't been granted yet. */
    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }

        let callback: CGEventTapCallBack = { _, type, cgEvent, userInfo in
            let tap = Unmanaged<BrightnessKeyTap>.fromOpaque(userInfo!).takeUnretainedValue()
            return tap.handle(type: type, cgEvent: cgEvent)
        }
        guard
            let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: CGEventMask(1 << Self.nxSysdefined.rawValue)
                    | CGEventMask(1 << CGEventType.keyDown.rawValue)
                    | CGEventMask(1 << CGEventType.keyUp.rawValue),
                callback: callback,
                userInfo: Unmanaged.passUnretained(self).toOpaque()
            )
        else { return false }

        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        return true
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        tap = nil
        runLoopSource = nil
    }

    private func handle(type: CGEventType, cgEvent: CGEvent) -> Unmanaged<CGEvent>? {
        /* The system disables a tap that stalls (or on secure input);
           re-enable and pass the event along. */
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(cgEvent)
        }

        if type == .keyDown || type == .keyUp {
            return handleBrightnessKeycode(type: type, cgEvent: cgEvent)
        }

        guard
            type == Self.nxSysdefined,
            let event = NSEvent(cgEvent: cgEvent),
            event.subtype.rawValue == Self.nxSubtypeAuxControl
        else { return Unmanaged.passUnretained(cgEvent) }

        /* data1 layout for special keys:
           bits 16–31 key code, bits 8–15 key state (0x0A down / 0x0B up),
           bit 0 autorepeat. */
        let data1 = event.data1
        let keyCode = (data1 & 0xFFFF_0000) >> 16
        let keyState = (data1 & 0x0000_FF00) >> 8

        let direction: Direction
        switch keyCode {
        case Self.nxKeyBrightnessUp: direction = .up
        case Self.nxKeyBrightnessDown: direction = .down
        default: return Unmanaged.passUnretained(cgEvent)
        }

        /* Tells the keycode leg of this press (if the hardware sends one)
           that the NX path owns it. */
        lastAuxTimestamp = ProcessInfo.processInfo.systemUptime

        let fine = event.modifierFlags.contains([.option, .shift])
        let isDown = keyState == 0x0A
        let consumed = onKey?(direction, fine, isDown) ?? false
        return consumed ? nil : Unmanaged.passUnretained(cgEvent)
    }

    /* The keycode leg: brightness keycodes are consumed and handled after a
       short wait for their NX twin — if the twin shows up (built-in
       keyboard), the NX path above owns the press and the deferred handler
       stands down. Consuming unconditionally is safe because macOS ignores
       these keycodes outright. Every other key passes straight through. */
    private func handleBrightnessKeycode(
        type: CGEventType, cgEvent: CGEvent
    ) -> Unmanaged<CGEvent>? {
        let direction: Direction
        switch cgEvent.getIntegerValueField(.keyboardEventKeycode) {
        case Self.keycodeBrightnessUp: direction = .up
        case Self.keycodeBrightnessDown: direction = .down
        default: return Unmanaged.passUnretained(cgEvent)
        }

        let now = ProcessInfo.processInfo.systemUptime
        /* Mid-hold on both-legs hardware: the NX repeats keep the timestamp
           fresh, so the keycode repeats just pass through. */
        guard now - lastAuxTimestamp > Self.auxTwinWindow else {
            return Unmanaged.passUnretained(cgEvent)
        }

        let flags = cgEvent.flags
        let fine = flags.contains(.maskAlternate) && flags.contains(.maskShift)
        let isDown = type == .keyDown
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.fallbackDelay) { [weak self] in
            guard let self, self.lastAuxTimestamp < now else { return }
            self.onFallbackKey?(direction, fine, isDown)
        }
        return nil
    }
}
