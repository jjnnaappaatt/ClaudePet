import Testing
import Foundation
@testable import ClaudePetCore

/// `String.asciiContains` replaces `lowercased().contains(_:)` on the two hottest string paths in the
/// app — model-family classification (once per parsed line) and price-override matching (once per
/// entry, from three full-history loops per recompute).
///
/// It is a **narrower** predicate than the thing it replaces: case folding is `| 0x20`, which is only
/// equivalent to Unicode lowercasing for ASCII. Both inputs are machine-generated identifiers, so
/// that holds — but "holds for the inputs it is given" is a claim that needs pinning, because a
/// mismatch would silently misprice a model or misfile it into `.other`.
@Suite struct StringScanningTests {

    /// The property that matters: for every id/needle pair this code actually sees, the fast test and
    /// the old one agree. The pairs are the real model ids crossed with the real override needles.
    @Test func agreesWithLowercasedContainsOnRealModelIdsAndNeedles() {
        let ids = [
            "claude-opus-4-8", "claude-opus-4-7", "claude-opus-4-1", "claude-opus-5",
            "claude-sonnet-4-6", "claude-sonnet-5", "claude-haiku-4-5-20251001",
            "claude-fable-5", "claude-mythos-1", "CLAUDE-OPUS-4-8", "Claude-Sonnet-5",
            "gpt-5-codex", "weird-thing", "", "opus", "-", "claude",
        ]
        let needles = PricingTable.default.overrides.map(\.idContains)
            + ["fable", "mythos", "opus", "sonnet", "haiku", "claude", "5", "-4-", "OPUS"]
        #expect(!needles.isEmpty)
        for id in ids {
            for needle in needles {
                #expect(id.asciiContains(needle) == id.lowercased().contains(needle.lowercased()),
                        "disagreement: \"\(id)\".asciiContains(\"\(needle)\")")
            }
        }
    }

    /// `| 0x20` folds letters, but it also maps `@`→`` ` `` and `[`→`{`. Those pairs must not match,
    /// or the folding trick is unsound for anything but pure letters — this is the subtle failure
    /// mode, and it is why the needles are documented as letters-only.
    @Test func punctuationThatDiffersByBitFiveDoesNotFalselyMatch() {
        #expect(!"A@B".asciiContains("a`b"))
        #expect(!"x[y".asciiContains("x{y"))
        #expect(!"1-2".asciiContains("1\r2"))
        // …while genuine letter case folding still works in both directions.
        #expect("A@B".asciiContains("a@b"))
        #expect("OPUS".asciiContains("opus"))
        #expect("opus".asciiContains("OPUS"))
    }

    @Test func edgesBehaveLikeContains() {
        #expect("claude-opus-4-8".asciiContains("claude"))       // at the start
        #expect("claude-opus-4-8".asciiContains("4-8"))          // at the end
        #expect("claude-opus-4-8".asciiContains("claude-opus-4-8"))  // whole string
        #expect(!"opus".asciiContains("claude-opus"))            // needle longer than haystack
        #expect(!"".asciiContains("opus"))
        // An empty needle declines here, and `contains("")` declines too — they agree.
        #expect("opus".asciiContains("") == "opus".lowercased().contains(""))
        #expect(PricingTable.default.overrides.allSatisfy { !$0.idContains.isEmpty })
    }

    /// The classification this all feeds. Mythos is priced as Fable deliberately.
    @Test func modelFamilyStillClassifiesEveryRealId() {
        #expect(ModelFamily(modelID: "claude-opus-4-8") == .opus)
        #expect(ModelFamily(modelID: "CLAUDE-OPUS-4-8") == .opus)
        #expect(ModelFamily(modelID: "claude-sonnet-5") == .sonnet)
        #expect(ModelFamily(modelID: "claude-haiku-4-5-20251001") == .haiku)
        #expect(ModelFamily(modelID: "claude-fable-5") == .fable)
        #expect(ModelFamily(modelID: "claude-mythos-1") == .fable)
        #expect(ModelFamily(modelID: "gpt-5") == .other)
        #expect(ModelFamily(modelID: "") == .other)
    }
}
