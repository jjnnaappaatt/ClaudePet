import Foundation

/// Deterministic RNG so mascot behavior is testable.
struct SeededRNG: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed == 0 ? 0x9E3779B97F4A7C15 : seed }
    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}

public enum MascotState: CaseIterable {
    case sit, blink, walk, hop
}

/// Weighted-random idle state machine. Each state owns a frame sequence and a
/// per-frame duration; when a sequence finishes, the next state is chosen by weight.
public struct MascotMachine {
    private var rng: SeededRNG

    public init(seed: UInt64 = 0xC1A0_DE) { rng = SeededRNG(seed: seed) }

    public func frames(for state: MascotState, emotion: MascotEmotion = .neutral) -> [[[UInt8]]] {
        func f(_ eye: MascotArt.Eyes? = nil, leg: Int = 0, y: Int = 0) -> [[UInt8]] {
            MascotArt.face(emotion, eyeOverride: eye, legPhase: leg, yOffset: y)
        }
        switch state {
        case .sit:   return [f()]
        case .blink: return [f(.closed), f()]
        case .walk:  return [f(leg: 1), f(), f(leg: 2), f()]
        case .hop:   return [f(), f(y: 2), f(y: 2), f()]
        }
    }

    public func frameDuration(for state: MascotState) -> Double {
        switch state {
        case .sit:   return 1.1
        case .blink: return 0.11
        case .walk:  return 0.18
        case .hop:   return 0.14
        }
    }

    /// Pick the next idle action, biased by mood: calm moods wander/hop, stressed moods stay
    /// put and just blink, sleeping holds still.
    public mutating func nextState(for emotion: MascotEmotion = .neutral) -> MascotState {
        let roll = Double(rng.next() % 1000) / 1000.0
        switch emotion {
        case .sleeping:
            return .sit                                   // hold the sleeping pose
        case .worried, .alarmed:
            return roll < 0.7 ? .sit : .blink             // anxious — no wandering
        case .happy, .celebrating:
            switch roll {                                 // livelier
            case ..<0.40: return .sit
            case ..<0.70: return .blink
            case ..<0.85: return .walk
            default:      return .hop
            }
        case .neutral:
            switch roll {                                 // original idle mix
            case ..<0.46: return .sit
            case ..<0.80: return .blink
            case ..<0.93: return .walk
            default:      return .hop
            }
        }
    }
}
