import Foundation

/* Pure brightness-stepping math, kept UI-free so it's unit-testable.

   Brightness is a Float in 0...1. Stepping first snaps the current value to
   the nearest tick of the step grid, then moves one tick — so repeated
   presses walk a stable grid (0, 1/16, 2/16, …) instead of accumulating
   float drift, and a value set elsewhere (Control Center, another app)
   joins the grid on the first key press. */
enum BrightnessMath {
    /* Standard macOS granularity: 16 ticks, or 64 with ⌥⇧ held
       (quarter-steps, matching the native fine-adjust gesture). */
    static let coarseSteps = 16
    static let fineSteps = 64

    static func stepped(from current: Float, delta: Int, steps: Int) -> Float {
        precondition(steps > 0)
        let tick = (current * Float(steps)).rounded()
        let next = (tick + Float(delta)) / Float(steps)
        return min(max(next, 0), 1)
    }
}
