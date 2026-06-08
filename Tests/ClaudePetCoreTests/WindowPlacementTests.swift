import Testing
import Foundation
import CoreGraphics
@testable import ClaudePetCore

@Suite struct WindowPlacementTests {
    // A laptop screen and an external monitor to its right (AppKit bottom-left coords).
    let laptop = CGRect(x: 0, y: 0, width: 1440, height: 900)
    let external = CGRect(x: 1440, y: 0, width: 2560, height: 1440)

    @Test func signatureIsOrderIndependent() {
        let a = WindowPlacement.signature(for: ["B", "A"])
        let b = WindowPlacement.signature(for: ["A", "B"])
        #expect(a == b)                         // same arrangement → same key regardless of enumeration order
        #expect(a != WindowPlacement.signature(for: ["A"]))   // unplugging a monitor → different key
    }

    @Test func fullyVisibleFrameIsLeftAlone() {
        let win = CGRect(x: 100, y: 100, width: 268, height: 240)
        let out = WindowPlacement.clamped(win, into: [laptop, external])
        #expect(out == win)                     // don't fight an intentional, visible position
    }

    @Test func frameOnDisconnectedMonitorIsPulledBackOnScreen() {
        // Window lived on the external monitor; now only the laptop remains.
        let win = CGRect(x: 2000, y: 700, width: 268, height: 240)
        let out = WindowPlacement.clamped(win, into: [laptop])
        // Must end up fully inside the laptop's bounds.
        #expect(out.minX >= laptop.minX)
        #expect(out.maxX <= laptop.maxX)
        #expect(out.minY >= laptop.minY)
        #expect(out.maxY <= laptop.maxY)
    }

    @Test func partlyVisibleAtEdgeIsKept() {
        // ~68pt still showing on the laptop — enough to grab, so leave it.
        let win = CGRect(x: 1440 - 68, y: 100, width: 268, height: 240)
        let out = WindowPlacement.clamped(win, into: [laptop])
        #expect(out == win)
    }

    @Test func sliverOffScreenIsRescued() {
        // Only 10pt visible — too little to grab → clamp back in.
        let win = CGRect(x: 1440 - 10, y: 100, width: 268, height: 240)
        let out = WindowPlacement.clamped(win, into: [laptop])
        #expect(out != win)
        #expect(out.maxX <= laptop.maxX)
    }

    @Test func emptyScreenListReturnsFrameUnchanged() {
        let win = CGRect(x: 100, y: 100, width: 268, height: 240)
        #expect(WindowPlacement.clamped(win, into: []) == win)
    }
}
