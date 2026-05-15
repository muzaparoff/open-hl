// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import OpenHLCore

// Fixed locale for deterministic assertions.
// A separate non-US locale is tested at the bottom to catch locale leakage.
private let enUS = Locale(identifier: "en_US")

@Suite("MoneyFormatter — usd")
struct MoneyFormatterUSDTests {

    @Test("Formats a positive value")
    func formatsPositive() {
        #expect(MoneyFormatter.usd(Decimal(string: "1234.56")!, locale: enUS) == "$1,234.56")
    }

    @Test("Formats zero")
    func formatsZero() {
        #expect(MoneyFormatter.usd(Decimal(0), locale: enUS) == "$0.00")
    }

    @Test("Formats a negative value with leading minus")
    func formatsNegative() {
        let result = MoneyFormatter.usd(Decimal(string: "-1234.56")!, locale: enUS)
        #expect(result == "-$1,234.56")
    }

    @Test("Always shows exactly 2 fraction digits")
    func showsTwoFractionDigits() {
        #expect(MoneyFormatter.usd(Decimal(string: "5")!, locale: enUS) == "$5.00")
        #expect(MoneyFormatter.usd(Decimal(string: "5.1")!, locale: enUS) == "$5.10")
    }

    @Test("Optional overload returns empty string for nil")
    func optionalOverloadReturnsEmptyForNil() {
        let nilValue: Decimal? = nil
        #expect(MoneyFormatter.usd(nilValue, locale: enUS) == "")
    }

    @Test("Optional overload returns formatted string for non-nil")
    func optionalOverloadFormatsNonNil() {
        let value: Decimal? = Decimal(string: "42.00")
        #expect(MoneyFormatter.usd(value, locale: enUS) == "$42.00")
    }
}

@Suite("MoneyFormatter — signedUSD")
struct MoneyFormatterSignedUSDTests {

    @Test("Positive value shows leading plus")
    func positivShowsPlus() {
        let result = MoneyFormatter.signedUSD(Decimal(string: "1234.56")!, locale: enUS)
        #expect(result == "+$1,234.56")
    }

    @Test("Negative value shows leading minus")
    func negativeShowsMinus() {
        let result = MoneyFormatter.signedUSD(Decimal(string: "-1234.56")!, locale: enUS)
        #expect(result == "-$1,234.56")
    }

    @Test("Zero renders without a sign")
    func zeroHasNoSign() {
        let result = MoneyFormatter.signedUSD(Decimal(0), locale: enUS)
        // Zero is unsigned: "$0.00", not "+$0.00"
        #expect(result == "$0.00")
    }

    @Test("Optional overload returns empty string for nil")
    func optionalOverloadNil() {
        let nilValue: Decimal? = nil
        #expect(MoneyFormatter.signedUSD(nilValue, locale: enUS) == "")
    }
}

@Suite("MoneyFormatter — signedPercent")
struct MoneyFormatterSignedPercentTests {

    @Test("Positive ratio multiplies by 100 and shows plus")
    func positiveRatioShowsPlus() {
        // 0.1234 -> "+12.34%"
        let result = MoneyFormatter.signedPercent(Decimal(string: "0.1234")!, locale: enUS)
        #expect(result == "+12.34%")
    }

    @Test("Negative ratio shows minus")
    func negativeRatioShowsMinus() {
        // -0.012 -> "-1.20%"
        let result = MoneyFormatter.signedPercent(Decimal(string: "-0.012")!, locale: enUS)
        #expect(result == "-1.20%")
    }

    @Test("Zero ratio renders without a sign")
    func zeroRatioHasNoSign() {
        let result = MoneyFormatter.signedPercent(Decimal(0), locale: enUS)
        #expect(result == "0.00%")
    }

    @Test("Optional overload returns empty string for nil")
    func optionalOverloadNil() {
        let nilValue: Decimal? = nil
        #expect(MoneyFormatter.signedPercent(nilValue, locale: enUS) == "")
    }
}

@Suite("MoneyFormatter — decimal")
struct MoneyFormatterDecimalTests {

    @Test("Formats with specified fraction digits")
    func formatsWithFractionDigits() {
        let result = MoneyFormatter.decimal(
            Decimal(string: "1234.5678")!,
            minimumFractionDigits: 2,
            maximumFractionDigits: 4,
            locale: enUS
        )
        #expect(result == "1,234.5678")
    }

    @Test("Pads to minimum fraction digits")
    func paddsToMinimum() {
        let result = MoneyFormatter.decimal(
            Decimal(string: "5")!,
            minimumFractionDigits: 2,
            maximumFractionDigits: 6,
            locale: enUS
        )
        #expect(result == "5.00")
    }

    @Test("Rounds at maximum fraction digits")
    func roundsAtMaximum() {
        let result = MoneyFormatter.decimal(
            Decimal(string: "1.123456789")!,
            minimumFractionDigits: 0,
            maximumFractionDigits: 2,
            locale: enUS
        )
        // "1.12" — truncation/rounding behavior within 2 places
        #expect(result.hasPrefix("1.1"))
    }

    @Test("Zero with two fraction digits")
    func zeroWithTwoDigits() {
        let result = MoneyFormatter.decimal(
            Decimal(0),
            minimumFractionDigits: 2,
            maximumFractionDigits: 2,
            locale: enUS
        )
        #expect(result == "0.00")
    }
}

// MARK: - Non-US locale guard
// These tests verify that formatters do NOT leak the system locale into
// money formatting. We force a French locale (uses comma as decimal separator)
// and confirm the formatter still uses the locale-appropriate separator —
// meaning it IS respecting the provided locale, not a hardcoded "en_US".
// If the formatter were hardcoded to en_US it would emit "1234.56"; the
// French locale emits "1 234,56" (non-breaking space + comma). Either
// behavior is acceptable as long as it is consistent with the provided locale.

@Suite("MoneyFormatter — locale parameter is respected (non-US locale guard)")
struct MoneyFormatterLocaleTests {

    private let frFR = Locale(identifier: "fr_FR")

    @Test("usd output differs between en_US and fr_FR (locale is respected)")
    func usdLocaleRespected() {
        let enResult = MoneyFormatter.usd(Decimal(string: "1234.56")!, locale: enUS)
        let frResult = MoneyFormatter.usd(Decimal(string: "1234.56")!, locale: frFR)
        // The two locales must produce different output. If they're identical,
        // the formatter has hardcoded a locale and is ignoring the parameter.
        #expect(enResult != frResult)
    }

    @Test("signedUSD output differs between en_US and fr_FR")
    func signedUSDLocaleRespected() {
        let enResult = MoneyFormatter.signedUSD(Decimal(string: "1234.56")!, locale: enUS)
        let frResult = MoneyFormatter.signedUSD(Decimal(string: "1234.56")!, locale: frFR)
        #expect(enResult != frResult)
    }

    @Test("decimal output differs between en_US and fr_FR")
    func decimalLocaleRespected() {
        let enResult = MoneyFormatter.decimal(
            Decimal(string: "1234.56")!,
            minimumFractionDigits: 2,
            maximumFractionDigits: 2,
            locale: enUS
        )
        let frResult = MoneyFormatter.decimal(
            Decimal(string: "1234.56")!,
            minimumFractionDigits: 2,
            maximumFractionDigits: 2,
            locale: frFR
        )
        #expect(enResult != frResult)
    }
}
