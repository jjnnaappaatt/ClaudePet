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
    case sit, blink, walk, hop, glance
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
        case .sit:    return [f()]
        case .blink:  return [f(.closed), f()]
        case .walk:   return [f(leg: 1), f(), f(leg: 2), f()]
        case .hop:    return [f(), f(y: 2), f(y: 2), f()]
        case .glance: return [f(.lookLeft), f(), f(.lookRight), f()]   // the CLI's look-left/right poses
        }
    }

    public func frameDuration(for state: MascotState) -> Double {
        switch state {
        case .sit:    return 1.1
        case .blink:  return 0.11
        case .walk:   return 0.18
        case .hop:    return 0.14
        case .glance: return 0.55                             // unhurried look around
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
            case ..<0.30: return .sit
            case ..<0.60: return .blink
            case ..<0.75: return .glance
            case ..<0.88: return .walk
            default:      return .hop
            }
        case .neutral:
            switch roll {                                 // idle mix with the odd look-around
            case ..<0.36: return .sit
            case ..<0.68: return .blink
            case ..<0.83: return .glance
            case ..<0.94: return .walk
            default:      return .hop
            }
        }
    }
}
