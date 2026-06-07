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

    public func frames(for state: MascotState) -> [[[UInt8]]] {
        switch state {
        case .sit:   return [MascotArt.sit]
        case .blink: return [MascotArt.blink, MascotArt.sit]
        case .walk:  return [MascotArt.walkA, MascotArt.sit, MascotArt.walkB, MascotArt.sit]
        case .hop:   return [MascotArt.sit, MascotArt.hop, MascotArt.hop, MascotArt.sit]
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

    /// Pick the next state: mostly sit, frequent blinks, occasional walk, rare hop.
    public mutating func nextState() -> MascotState {
        let roll = Double(rng.next() % 1000) / 1000.0
        switch roll {
        case ..<0.46: return .sit
        case ..<0.80: return .blink
        case ..<0.93: return .walk
        default:      return .hop
        }
    }
}
