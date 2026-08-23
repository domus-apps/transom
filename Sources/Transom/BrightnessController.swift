import AppKit

/* Sets per-display brightness. Two backends, tried in order:

   1. The private DisplayServices framework — the same backend System
      Settings and Control Center use. Covers the built-in panel and
      Apple/brightness-capable external displays (Studio Display, Pro
      Display XDR, many recent LG UltraFines).
   2. DDC/CI over IOAVService (DDCBrightness) — everything else: ordinary
      external monitors that DisplayServices reports as uncontrollable.

   Everything is resolved with dlopen/dlsym at runtime: there is no public
   header, and a missing symbol must degrade to "can't control" rather than
   fail to link. */
final class BrightnessController {
    private typealias CanChangeFn = @convention(c) (CGDirectDisplayID) -> Bool
    private typealias GetFn = @convention(c) (
        CGDirectDisplayID, UnsafeMutablePointer<Float>
    ) -> Int32
    private typealias SetFn = @convention(c) (CGDirectDisplayID, Float) -> Int32
    private typealias ChangedFn = @convention(c) (CGDirectDisplayID, Double) -> Void

    private let canChangeBrightness: CanChangeFn?
    private let getBrightness: GetFn?
    private let setBrightness: SetFn?
    /* Broadcasts the new value so the Control Center / System Settings
       sliders move in sync. Best-effort. */
    private let brightnessChanged: ChangedFn?

    init() {
        let handle = dlopen(
            "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices",
            RTLD_NOW
        )
        func symbol<T>(_ name: String, as type: T.Type) -> T? {
            guard let handle, let address = dlsym(handle, name) else { return nil }
            return unsafeBitCast(address, to: T.self)
        }
        canChangeBrightness = symbol("DisplayServicesCanChangeBrightness", as: CanChangeFn.self)
        getBrightness = symbol("DisplayServicesGetBrightness", as: GetFn.self)
        setBrightness = symbol("DisplayServicesSetBrightness", as: SetFn.self)
        brightnessChanged = symbol("DisplayServicesBrightnessChanged", as: ChangedFn.self)
        if handle == nil {
            NSLog("Transom: DisplayServices unavailable — brightness keys will pass through")
        }
    }

    private let ddc = DDCBrightness()

    func canControl(_ display: CGDirectDisplayID) -> Bool {
        canControlViaDisplayServices(display) || ddc.canControl(display)
    }

    /* One tick up or down on the given display. Returns the new value, or
       nil if the display couldn't be read/written. */
    @discardableResult
    func step(_ display: CGDirectDisplayID, delta: Int, fine: Bool) -> Float? {
        if let next = stepViaDisplayServices(display, delta: delta, fine: fine) {
            return next
        }
        return ddc.step(display, delta: delta, fine: fine)
    }

    private func canControlViaDisplayServices(_ display: CGDirectDisplayID) -> Bool {
        guard let canChangeBrightness, let getBrightness, setBrightness != nil else {
            return false
        }
        guard canChangeBrightness(display) else { return false }
        var value: Float = 0
        return getBrightness(display, &value) == 0
    }

    private func stepViaDisplayServices(
        _ display: CGDirectDisplayID, delta: Int, fine: Bool
    ) -> Float? {
        guard let getBrightness, let setBrightness else { return nil }
        var current: Float = 0
        guard getBrightness(display, &current) == 0 else { return nil }

        let steps = fine ? BrightnessMath.fineSteps : BrightnessMath.coarseSteps
        let next = BrightnessMath.stepped(from: current, delta: delta, steps: steps)
        guard setBrightness(display, next) == 0 else { return nil }
        brightnessChanged?(display, Double(next))
        return next
    }
}
