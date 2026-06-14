import Testing
import Foundation
@testable import ClaudePetCore

@Suite struct MascotTests {

    @Test func framesAreCorrectSize() {
        for frame in [MascotArt.sit, MascotArt.blink, MascotArt.walkA, MascotArt.walkB, MascotArt.hop] {
            #expect(frame.count == 16)
            #expect(frame.allSatisfy { $0.count == 16 })
        }
    }

    @Test func framesDifferBetweenStates() {
        #expect(MascotArt.sit != MascotArt.blink)      // eyes change
        #expect(MascotArt.walkA != MascotArt.walkB)    // feet alternate
        #expect(MascotArt.sit != MascotArt.hop)        // body shifts
    }

    @Test func emotionFacesAreSizedAndDistinct() {
        let faces = [MascotArt.happy, MascotArt.worried, MascotArt.alarmed,
                     MascotArt.sleeping, MascotArt.celebrating]
        for f in faces {
            #expect(f.count == 16)
            #expect(f.allSatisfy { $0.count == 16 })
        }
        #expect(MascotArt.happy != MascotArt.worried)
        #expect(MascotArt.worried != MascotArt.alarmed)
        #expect(MascotArt.sleeping != MascotArt.sit)
        #expect(MascotArt.face(.neutral) == MascotArt.sit)   // neutral == the original idle face
    }

    @Test func neutralFaceHasGlintAndSmile() {
        let flat = MascotArt.face(.neutral).flatMap { $0 }
        #expect(flat.contains(4))   // refined eyes carry a white glint
        #expect(flat.contains(3))   // and a small smile
    }

    @Test func machineIsDeterministicForSeed() {
        var a = MascotMachine(seed: 42)
        var b = MascotMachine(seed: 42)
        let seqA = (0..<20).map { _ in a.nextState() }
        let seqB = (0..<20).map { _ in b.nextState() }
        #expect(seqA == seqB)
        // All four states should appear over enough rolls.
        #expect(Set(seqA).isSuperset(of: [.sit, .blink]))
    }

    @MainActor
    @Test func engineAdvancesFramesOverTime() {
        let engine = MascotEngine(seed: 7)
        var t = Date(timeIntervalSinceReferenceDate: 0)
        engine.advance(to: t)                       // primes lastTick
        let first = engine.currentFrame

        var changed = false
        var states: Set<MascotState> = [engine.currentState]
        for _ in 0..<400 {                          // ~ many seconds at 1/6s steps
            t = t.addingTimeInterval(1.0 / 6.0)
            engine.advance(to: t)
            states.insert(engine.currentState)
            if engine.currentFrame != first { changed = true }
        }
        #expect(changed)                            // animation actually progresses
        #expect(states.count >= 2)                  // cycles through multiple states
    }

    @MainActor
    @Test func clampsLargeTimeJumps() {
        let engine = MascotEngine(seed: 1)
        let t = Date(timeIntervalSinceReferenceDate: 0)
        engine.advance(to: t)
        // A huge jump (e.g. wake from sleep) must not crash or fast-forward unbounded.
        engine.advance(to: t.addingTimeInterval(100_000))
        #expect(engine.currentFrame.count == 16)
    }
}
