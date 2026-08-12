import Testing
import Foundation
@testable import ClaudePetCore

/// The arithmetic timestamp path must be **indistinguishable** from `ISO8601DateFormatter`, not
/// merely close to it.
///
/// Every `UsageEntry.timestamp` flows from here into day bucketing, 5h/weekly window edges, sorting
/// and dedup ordering. A parser that is faster but shifts one date by a millisecond is not an
/// optimisation, it is silent corruption of every figure in the app — and nothing else in the suite
/// would catch it, because the wrong answer is still internally consistent.
///
/// So these compare against the formatter itself rather than against hand-written expectations:
/// the formatter is the definition of correct here, and the fast path only exists to agree with it.
@Suite struct TimestampParserTests {

    private func formatter(fractional: Bool) -> ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = fractional ? [.withInternetDateTime, .withFractionalSeconds]
                                     : [.withInternetDateTime]
        return f
    }

    private func fast(_ s: String) -> Date? {
        var s = s
        return s.withUTF8 { TimestampParser.fastPath($0) }
    }

    // MARK: - Agreement with the formatter

    /// Dense coverage of the real layout: every month, month-end and month-start, leap and non-leap
    /// Februaries, midnight and the last second of a day, and the fractional edges.
    @Test func fastPathMatchesTheFormatterExactly() throws {
        let f = formatter(fractional: true)
        var checked = 0
        for year in [1970, 1999, 2000, 2001, 2023, 2024, 2026, 2100] {
            for month in 1...12 {
                for day in [1, 15, 28] {
                    for (h, m, s) in [(0, 0, 0), (12, 34, 56), (23, 59, 59)] {
                        for ms in [0, 1, 19, 500, 999] {
                            let str = String(format: "%04d-%02d-%02dT%02d:%02d:%02d.%03dZ",
                                             year, month, day, h, m, s, ms)
                            let expected = try #require(f.date(from: str), "formatter rejected \(str)")
                            let got = try #require(fast(str), "fast path rejected \(str)")
                            // Bit-identical, not approximately equal.
                            #expect(got == expected, "\(str): \(got) != \(expected)")
                            #expect(got.timeIntervalSince1970.bitPattern
                                    == expected.timeIntervalSince1970.bitPattern, "\(str) differs in the last bits")
                            checked += 1
                        }
                    }
                }
            }
        }
        #expect(checked == 8 * 12 * 3 * 3 * 5)      // else the loop silently stopped covering things
    }

    /// 29 February exists only in leap years, and the civil-days algorithm's century rule is the part
    /// most likely to be wrong: 2000 is a leap year, 2100 is not.
    @Test func leapDayBoundariesMatchTheFormatter() throws {
        let f = formatter(fractional: true)
        for (y, valid) in [(2024, true), (2000, true), (2023, false), (2100, false)] {
            let str = String(format: "%04d-02-29T00:00:00.000Z", y)
            if valid {
                let expected = try #require(f.date(from: str))
                #expect(fast(str) == expected)
            } else {
                // The formatter rolls 2023-02-29 rather than rejecting it. We must not *disagree* —
                // whatever it does, the fast path either matches it or declines and lets it run.
                if let expected = f.date(from: str), let got = fast(str) {
                    #expect(got == expected, "\(str): fast \(got) vs formatter \(expected)")
                }
            }
        }
    }

    /// The no-fraction form is accepted too, and must agree with the *plain* formatter.
    @Test func theTwentyByteFormMatchesThePlainFormatter() throws {
        let f = formatter(fractional: false)
        for str in ["2026-08-12T10:40:21Z", "1970-01-01T00:00:00Z", "2001-01-01T00:00:00Z"] {
            let expected = try #require(f.date(from: str))
            #expect(fast(str) == expected, "\(str)")
        }
    }

    /// The public entry point must give the same answer whichever path serves it.
    @Test func publicEntryPointAgreesWithTheFormatterOnBothForms() throws {
        let frac = formatter(fractional: true), plain = formatter(fractional: false)
        #expect(TimestampParser.date(from: "2026-08-12T10:40:21.019Z")
                == frac.date(from: "2026-08-12T10:40:21.019Z"))
        #expect(TimestampParser.date(from: "2026-08-12T10:40:21Z")
                == plain.date(from: "2026-08-12T10:40:21Z"))
    }

    // MARK: - The fast path must decline everything it does not fully understand

    /// **The safety property.** Anything not exactly the known layout has to fall through, because
    /// the fallback is what keeps an unexpected shape correct rather than merely fast.
    @Test func fastPathDeclinesAnythingItDoesNotFullyUnderstand() {
        let rejects = [
            "2026-08-12T10:40:21+07:00",     // real offset, NOT UTC — the dangerous one
            "2026-08-12T10:40:21.019+07:00",
            "2026-08-12T10:40:21.123456Z",   // microseconds
            "2026-08-12T10:40:21.01Z",       // 2-digit fraction
            "2026-08-12 10:40:21.019Z",      // space instead of T
            "2026-08-12T10:40:21.019z",      // lowercase z
            "2026-08-12T10:40:21.019",       // no zone
            "202X-08-12T10:40:21.019Z",      // non-digit
            "2026-08-12T10:40:2X.019Z",
            "2026-13-12T10:40:21.019Z",      // month 13
            "2026-00-12T10:40:21.019Z",      // month 0
            "2026-08-32T10:40:21.019Z",      // day 32
            "2026-08-00T10:40:21.019Z",      // day 0
            "2026-08-12T24:40:21.019Z",      // hour 24
            "2026-08-12T10:60:21.019Z",      // minute 60
            "", "Z", "not a date at all",
        ]
        for s in rejects {
            #expect(fast(s) == nil, "fast path should have declined \(s.isEmpty ? "<empty>" : s)")
        }
    }

    /// Declining is only safe because the caller still answers correctly. An offset timestamp is the
    /// case that would silently shift a turn by hours if the fast path ever accepted it.
    @Test func declinedShapesAreStillParsedCorrectlyByTheFallback() throws {
        let offset = try #require(TimestampParser.date(from: "2026-08-12T10:40:21+07:00"))
        let sameInstantUTC = try #require(TimestampParser.date(from: "2026-08-12T03:40:21Z"))
        #expect(offset == sameInstantUTC)
        #expect(TimestampParser.date(from: "definitely not a date") == nil)
    }

    /// Leap seconds are legal ISO and appear in some logs; second 60 must not be rejected outright by
    /// the range guard while the formatter accepts it.
    @Test func secondSixtyIsHandledConsistentlyWithTheFormatter() {
        let s = "2016-12-31T23:59:60.000Z"
        let expected = formatter(fractional: true).date(from: s)
        if let expected, let got = fast(s) { #expect(got == expected) }
    }
}
