import CoreGraphics
import Testing

@testable import Transom

/* A laptop-ish primary and a 4K-ish external to its right, in Cocoa's
   global space (shared origin at the primary's bottom-left). */
private let laptop = CGRect(x: 0, y: 0, width: 1512, height: 982)
private let external = CGRect(x: 1512, y: 0, width: 3840, height: 2160)
private let frames = [laptop, external]

@Test func pointInsideAScreenHitsThatScreen() {
    #expect(CursorDisplay.index(of: CGPoint(x: 100, y: 100), in: frames) == 0)
    #expect(CursorDisplay.index(of: CGPoint(x: 2000, y: 1500), in: frames) == 1)
}

@Test func sharedEdgeBelongsToExactlyOneScreen() {
    /* x == 1512 is laptop.maxX and external.minX; the half-open test must
       resolve it to the external, never both or neither. */
    #expect(CursorDisplay.index(of: CGPoint(x: 1512, y: 100), in: frames) == 1)
    #expect(CursorDisplay.index(of: CGPoint(x: 1511.9, y: 100), in: frames) == 0)
}

@Test func pointOnNoScreenFallsBackToNearestCenter() {
    /* Above the laptop, in the dead zone next to the taller external. */
    let deadZone = CGPoint(x: 100, y: 1500)
    #expect(CursorDisplay.index(of: deadZone, in: frames) == 0)

    /* Far off to the external's right. */
    #expect(CursorDisplay.index(of: CGPoint(x: 9999, y: 100), in: frames) == 1)
}

@Test func emptyScreenListYieldsNil() {
    #expect(CursorDisplay.index(of: .zero, in: []) == nil)
}

// MARK: - Brightness stepping

@Test func stepsWalkTheGrid() {
    #expect(BrightnessMath.stepped(from: 0.5, delta: 1, steps: 16) == 0.5625)
    #expect(BrightnessMath.stepped(from: 0.5, delta: -1, steps: 16) == 0.4375)
}

@Test func offGridValueSnapsToGridOnFirstStep() {
    /* 0.51 rounds to tick 8 (0.5); one step up lands exactly on 9/16. */
    #expect(BrightnessMath.stepped(from: 0.51, delta: 1, steps: 16) == 0.5625)
}

@Test func clampsAtBothEnds() {
    #expect(BrightnessMath.stepped(from: 0.01, delta: -1, steps: 16) == 0)
    #expect(BrightnessMath.stepped(from: 0, delta: -1, steps: 16) == 0)
    #expect(BrightnessMath.stepped(from: 0.99, delta: 1, steps: 16) == 1)
    #expect(BrightnessMath.stepped(from: 1, delta: 1, steps: 16) == 1)
}

@Test func repeatedStepsDoNotDrift() {
    var value: Float = 0
    for _ in 0..<16 { value = BrightnessMath.stepped(from: value, delta: 1, steps: 16) }
    #expect(value == 1)
    for _ in 0..<16 { value = BrightnessMath.stepped(from: value, delta: -1, steps: 16) }
    #expect(value == 0)
}

@Test func fineStepsAreQuarterSize() {
    #expect(BrightnessMath.stepped(from: 0.5, delta: 1, steps: 64) == 0.515625)
}
