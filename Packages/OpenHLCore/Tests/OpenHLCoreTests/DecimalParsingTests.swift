// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import OpenHLCore

// MARK: - DecimalParsing.parse(_:)

@Suite("DecimalParsing.parse")
struct DecimalParsingTests {

    // -------------------------------------------------------------------------
    // Valid inputs
    // -------------------------------------------------------------------------

    @Test("Parses zero")
    func parsesZero() {
        #expect(DecimalParsing.parse("0") == Decimal(0))
    }

    @Test("Parses zero point zero")
    func parsesZeroPointZero() {
        #expect(DecimalParsing.parse("0.0") == Decimal(0))
    }

    @Test("Parses a positive decimal")
    func parsesPositiveDecimal() {
        #expect(DecimalParsing.parse("1234.5") == Decimal(string: "1234.5"))
    }

    @Test("Parses a negative decimal")
    func parsesNegativeDecimal() {
        #expect(DecimalParsing.parse("-1234.5") == Decimal(string: "-1234.5"))
    }

    @Test("Parses a large integer string")
    func parsesLargeInteger() {
        #expect(DecimalParsing.parse("9999999999") == Decimal(string: "9999999999"))
    }

    @Test("Parses a high-precision decimal matching Hyperliquid scale")
    func parsesHighPrecisionDecimal() {
        let result = DecimalParsing.parse("123456789.123456789")
        let expected = Decimal(string: "123456789.123456789")
        #expect(result == expected)
    }

    @Test("Parses negative zero (returns non-nil)")
    func parsesNegativeZero() {
        let result = DecimalParsing.parse("-0")
        #expect(result != nil)
    }

    @Test("Parses string with leading and trailing whitespace (trimmed)")
    func parsesWithWhitespace() {
        #expect(DecimalParsing.parse("  42.5  ") == Decimal(string: "42.5"))
    }

    @Test("Parses small fractional value")
    func parsesSmallFractional() {
        #expect(DecimalParsing.parse("0.000123") == Decimal(string: "0.000123"))
    }

    // -------------------------------------------------------------------------
    // Scientific notation — Hyperliquid does NOT use scientific notation.
    // We document and test that we REJECT it to prevent silent precision loss
    // if a future API response ever uses it.
    // -------------------------------------------------------------------------

    @Test("Rejects scientific notation — Hyperliquid never uses it and we want a loud failure")
    func rejectsScientificNotation() {
        #expect(DecimalParsing.parse("1e5") == nil)
    }

    @Test("Rejects scientific notation with uppercase E")
    func rejectsUppercaseScientificNotation() {
        #expect(DecimalParsing.parse("1E5") == nil)
    }

    // -------------------------------------------------------------------------
    // Invalid inputs
    // -------------------------------------------------------------------------

    @Test("Returns nil for empty string")
    func returnsNilForEmpty() {
        #expect(DecimalParsing.parse("") == nil)
    }

    @Test("Returns nil for alphabetic input")
    func returnsNilForAlphabetic() {
        #expect(DecimalParsing.parse("abc") == nil)
    }

    @Test("Returns nil for locale-style comma grouping separator")
    func returnsNilForCommaGroupingSeparator() {
        #expect(DecimalParsing.parse("1,234.5") == nil)
    }

    @Test("Returns nil for leading plus sign")
    func returnsNilForLeadingPlus() {
        #expect(DecimalParsing.parse("+1234.5") == nil)
    }

    @Test("Returns nil for multiple decimal points")
    func returnsNilForMultipleDecimalPoints() {
        #expect(DecimalParsing.parse("1.2.3") == nil)
    }

    @Test("Returns nil for bare decimal point")
    func returnsNilForBareDecimalPoint() {
        #expect(DecimalParsing.parse(".") == nil)
    }

    @Test("Returns nil for pure whitespace")
    func returnsNilForPureWhitespace() {
        #expect(DecimalParsing.parse("   ") == nil)
    }
}

// MARK: - @DecimalString round-trip via a test DTO

/// A minimal `Codable` DTO used only for round-trip testing of
/// `@DecimalString` and `@OptionalDecimalString`.
private struct MoneyDTO: Codable, Equatable {
    @DecimalString var amount: Decimal
    @OptionalDecimalString var optionalAmount: Decimal?
}

private func makeJSON(amount: String, optionalAmount: String?) -> Data {
    var json = "{\"amount\":\"\(amount)\""
    if let opt = optionalAmount {
        json += ",\"optionalAmount\":\"\(opt)\""
    } else {
        json += ",\"optionalAmount\":null"
    }
    json += "}"
    return json.data(using: .utf8)!
}

@Suite("@DecimalString property wrapper — Codable round-trip")
struct DecimalStringWrapperTests {

    @Test("Decodes a valid decimal string into Decimal")
    func decodesValidDecimalString() throws {
        let data = makeJSON(amount: "1234.56", optionalAmount: nil)
        let dto = try JSONDecoder().decode(MoneyDTO.self, from: data)
        #expect(dto.amount == Decimal(string: "1234.56"))
        #expect(dto.optionalAmount == nil)
    }

    @Test("Decodes optional field when present")
    func decodesOptionalWhenPresent() throws {
        let data = makeJSON(amount: "0.5", optionalAmount: "99.99")
        let dto = try JSONDecoder().decode(MoneyDTO.self, from: data)
        #expect(dto.optionalAmount == Decimal(string: "99.99"))
    }

    @Test("Decodes optional field as nil when null")
    func decodesOptionalAsNilWhenNull() throws {
        let data = makeJSON(amount: "1.0", optionalAmount: nil)
        let dto = try JSONDecoder().decode(MoneyDTO.self, from: data)
        #expect(dto.optionalAmount == nil)
    }

    @Test("Encodes Decimal back to JSON string token")
    func encodesDecimalAsString() throws {
        // Decode from JSON first, then re-encode, asserting the output is a String.
        let data = makeJSON(amount: "42.5", optionalAmount: nil)
        let dto = try JSONDecoder().decode(MoneyDTO.self, from: data)
        let reencoded = try JSONEncoder().encode(dto)
        let result = try JSONSerialization.jsonObject(with: reencoded) as? [String: Any]
        // The encoded value must be a String, not a Number.
        let encoded = result?["amount"]
        #expect(encoded is String)
        #expect((encoded as? String) == "42.5")
    }

    @Test("Decoding a numeric JSON token (not a string) throws DecodingError")
    func rejectsNumericToken() {
        let json = "{\"amount\":1234.56,\"optionalAmount\":null}".data(using: .utf8)!
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(MoneyDTO.self, from: json)
        }
    }

    @Test("Decoding malformed string throws DecodingError")
    func rejectsMalformedString() {
        let data = makeJSON(amount: "not-a-number", optionalAmount: nil)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(MoneyDTO.self, from: data)
        }
    }

    @Test("Round-trip: encode then decode preserves value")
    func roundTrip() throws {
        let sourceJSON = makeJSON(amount: "9876.54321", optionalAmount: "-0.001")
        let original = try JSONDecoder().decode(MoneyDTO.self, from: sourceJSON)
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(MoneyDTO.self, from: encoded)
        #expect(decoded == original)
    }

    @Test("Comma as grouping separator is rejected")
    func rejectsCommaGroupingSeparator() {
        let data = makeJSON(amount: "1,234.56", optionalAmount: nil)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(MoneyDTO.self, from: data)
        }
    }

    @Test("Leading plus sign is rejected")
    func rejectsLeadingPlusSign() {
        let data = makeJSON(amount: "+1234.56", optionalAmount: nil)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(MoneyDTO.self, from: data)
        }
    }
}
