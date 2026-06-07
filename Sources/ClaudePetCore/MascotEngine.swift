import Foundation

/// Advances the mascot animation by elapsed wall-clock time. Plain reference type
/// (not observed) so mutating it inside a TimelineView's draw closure doesn't trigger
/// re-render loops — TimelineView itself drives the cadence.
@MainActor
public final class MascotEngine {
    private var machine: MascotMachine
    private var sequence: [[[UInt8]]]
    private var frameDuration: Double
    private var index = 0
    private var accumulator = 0.0
    private var lastTick: Date?

    public private(set) var currentState: MascotState = .sit

    public init(seed: UInt64 = 0xC1A0_DE) {
        machine = MascotMachine(seed: seed)
        sequence = machine.frames(for: .sit)
        frameDuration = machine.frameDuration(for: .sit)
    }

    public var currentFrame: [[UInt8]] { sequence[min(index, sequence.count - 1)] }

    /// Advance to `date`. dt is clamped so waking from sleep/occlusion doesn't fast-forward.
    public func advance(to date: Date) {
        guard let last = lastTick else { lastTick = date; return }
        lastTick = date
        accumulator += min(date.timeIntervalSince(last), 0.5)

        while accumulator >= frameDuration {
            accumulator -= frameDuration
            index += 1
            if index >= sequence.count {
                let next = machine.nextState()
                currentState = next
                sequence = machine.frames(for: next)
                frameDuration = machine.frameDuration(for: next)
                index = 0
            }
        }
    }

    /// Called when resuming from a pause: drop accumulated time and reset the clock,
    /// so the mascot picks up smoothly from a resting frame.
    public func resetClock() {
        lastTick = nil
        accumulator = 0
    }
}
