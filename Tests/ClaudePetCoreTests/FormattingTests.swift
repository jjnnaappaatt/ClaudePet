import Testing
import Foundation
@testable import ClaudePetCore

@Suite struct FormattingTests {

    /// Abbreviation must not start until the digits it hides stop mattering. `$1,001` used to render
    /// as "$1k", so the headline cost read the same for days while the real figure climbed past $1,900.
    @Test func currencyKeepsFullDigitsBelowTenThousand() {
        #expect(Format.currency(1001).hasPrefix("$1"))
        #expect(!Format.currency(1001).hasSuffix("k"))
        #expect(!Format.currency(9_999).hasSuffix("k"))
        #expect(Format.currency(1001).filter(\.isNumber) == "1001")   // separator-agnostic
        #expect(Format.currency(9_999).filter(\.isNumber) == "9999")
    }

    @Test func currencyAbbreviatesFromTenThousand() {
        #expect(Format.currency(10_000) == "$10k")
        #expect(Format.currency(12_500) == "$12.5k")
    }

    @Test func currencySmallValuesAreUnchanged() {
        #expect(Format.currency(0.06) == "$0.06")
        #expect(Format.currency(4.21) == "$4.21")
        #expect(Format.currency(402) == "$402")
        #expect(Format.currency(99.5) == "$99.50")
    }

    @Test func tokensAbbreviationIsUnchanged() {
        #expect(Format.tokens(932) == "932")
        #expect(Format.tokens(12_400) == "12.4k")
        #expect(Format.tokens(41_200_000) == "41.2M")
        #expect(Format.tokens(3_100_000_000) == "3.1B")
    }
}
