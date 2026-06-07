import Testing
import Foundation
@testable import ClaudePetCore

@Suite struct FiveHourBlockTests {
    let pricing = PricingTable.default
    let hour: TimeInterval = 3600

    /// A fixed hour-aligned base (1_779_998_400 = 494444 * 3600) so flooring math is exact.
    private var base: Date { Date(timeIntervalSince1970: 1_779_998_400) }

    private func entries(_ offsetsHours: [Double]) -> [UsageEntry] {
        offsetsHours.map { TestSupport.entry(at: base.addingTimeInterval($0 * hour), input: 100, output: 10) }
    }

    @Test func withinFiveHoursIsOneBlock() {
        let blocks = FiveHourBlockEngine.blocks(from: entries([0, 1, 4.9]), pricing: pricing)
        #expect(blocks.count == 1)
        #expect(blocks[0].workTokens == 330)
    }

    @Test func exactlyFiveHoursOpensNewBlock() {
        let blocks = FiveHourBlockEngine.blocks(from: entries([0, 5]), pricing: pricing)
        #expect(blocks.count == 2)
    }

    @Test func gapOverFiveHoursClosesBlock() {
        let blocks = FiveHourBlockEngine.blocks(from: entries([0, 0.5, 6]), pricing: pricing)
        #expect(blocks.count == 2)
        #expect(blocks[0].workTokens == 220)   // first two
        #expect(blocks[1].workTokens == 110)   // the +6h one
    }

    @Test func blockStartIsHourFloored() {
        // 30 minutes past the hour -> start floors back to the hour boundary.
        let e = TestSupport.entry(at: base.addingTimeInterval(30 * 60), input: 1, output: 1)
        let blocks = FiveHourBlockEngine.blocks(from: [e], pricing: pricing)
        #expect(blocks.count == 1)
        #expect(blocks[0].start == base)                       // floored to the hour
        #expect(blocks[0].actualStart == base.addingTimeInterval(30 * 60))
        #expect(blocks[0].endsAt == base.addingTimeInterval(5 * hour))
    }

    @Test func concurrentSessionsShareOneBlock() {
        // Two near-simultaneous entries from different sessions land in one block.
        let a = TestSupport.entry(id: "a", at: base.addingTimeInterval(60), input: 10, output: 0, sidechain: false)
        let b = TestSupport.entry(id: "b", at: base.addingTimeInterval(120), input: 20, output: 0, sidechain: true)
        let blocks = FiveHourBlockEngine.blocks(from: [a, b], pricing: pricing)
        #expect(blocks.count == 1)
        #expect(blocks[0].workTokens == 30)
    }

    @Test func activeBlockDetection() {
        let blocks = FiveHourBlockEngine.blocks(from: entries([0]), pricing: pricing)
        // now 2h into the window -> active
        #expect(FiveHourBlockEngine.activeBlock(in: blocks, now: base.addingTimeInterval(2 * hour)) != nil)
        // now 6h later -> outside the 5h window -> nil
        #expect(FiveHourBlockEngine.activeBlock(in: blocks, now: base.addingTimeInterval(6 * hour)) == nil)
    }
}
