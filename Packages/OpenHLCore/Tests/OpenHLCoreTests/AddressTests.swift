// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import OpenHLCore

// MARK: - Valid address acceptance

@Suite("Address — valid inputs")
struct AddressValidInputTests {

    @Test("Lowercase 0x + 40 hex chars is accepted and stored verbatim")
    func lowercaseAddressIsAccepted() throws {
        let raw = "0xabcdef1234567890abcdef1234567890abcdef12"
        let addr = try Address(raw)
        #expect(addr.rawValue == raw)
    }

    @Test("Mixed-case input is lowercased on storage")
    func mixedCaseIsNormalized() throws {
        let input = "0xABCDEF1234567890ABCDEF1234567890ABCDEF12"
        let addr = try Address(input)
        #expect(addr.rawValue == input.lowercased())
    }

    @Test("Failable init returns non-nil for valid address")
    func failableInitSucceeds() {
        let addr = Address(validating: "0xabcdef1234567890abcdef1234567890abcdef12")
        #expect(addr != nil)
    }

    @Test("Two addresses from same input (different case) are equal")
    func caseInsensitiveEquality() throws {
        let lower = try Address("0xabcdef1234567890abcdef1234567890abcdef12")
        let upper = try Address("0xABCDEF1234567890ABCDEF1234567890ABCDEF12")
        #expect(lower == upper)
    }

    @Test("Leading and trailing whitespace is trimmed before validation")
    func whitespaceIsTrimmed() throws {
        let raw = "  0xabcdef1234567890abcdef1234567890abcdef12  "
        let addr = try Address(raw)
        #expect(addr.rawValue == "0xabcdef1234567890abcdef1234567890abcdef12")
    }

    @Test("description equals rawValue")
    func descriptionMatchesRawValue() throws {
        let addr = try Address("0xabcdef1234567890abcdef1234567890abcdef12")
        #expect(addr.description == addr.rawValue)
    }

    @Test("Address rawValue is always exactly 42 characters")
    func rawValueIsAlways42Chars() throws {
        let addr = try Address("0x1234567890abcdef1234567890abcdef12345678")
        #expect(addr.rawValue.count == 42)
    }

    @Test(
        "Parameterized: all valid hex digit characters are accepted",
        arguments: [
            "0xabcdef1234567890abcdef1234567890abcdef12",
            "0x0000000000000000000000000000000000000000",
            "0xffffffffffffffffffffffffffffffffffffffff",
            "0x1234567890abcdef1234567890abcdef12345678",
            "0xABCDEF0123456789ABCDEF0123456789ABCDEF01",
        ])
    func validHexAddressAccepted(raw: String) throws {
        let addr = try Address(raw)
        #expect(addr.rawValue == raw.lowercased())
    }
}

// MARK: - Invalid address rejection

@Suite("Address — invalid inputs")
struct AddressInvalidInputTests {

    @Test("Empty string throws .empty")
    func emptyStringThrows() {
        #expect(throws: Address.ValidationError.empty) {
            try Address("")
        }
    }

    @Test("Whitespace-only string throws .empty")
    func whitespaceOnlyThrows() {
        #expect(throws: Address.ValidationError.empty) {
            try Address("   ")
        }
    }

    @Test("Missing 0x prefix throws .missingPrefix")
    func missingPrefixThrows() {
        #expect(throws: Address.ValidationError.missingPrefix) {
            try Address("abcdef1234567890abcdef1234567890abcdef12")
        }
    }

    @Test("0X uppercase prefix throws .missingPrefix (prefix is case-sensitive)")
    func uppercasePrefixThrows() {
        #expect(throws: Address.ValidationError.missingPrefix) {
            try Address("0Xabcdef1234567890abcdef1234567890abcdef12")
        }
    }

    @Test(
        "Parameterized: wrong-length inputs throw .wrongLength",
        arguments: [
            ("0x", 2),
            ("0xabc", 5),
            ("0xabcdef1234567890abcdef1234567890abcdef1", 41),  // 41 chars total (39 hex)
            ("0xabcdef1234567890abcdef1234567890abcdef123", 43),  // 43 chars total (41 hex)
            ("0xabcdef1234567890abcdef1234567890abcdef1234", 44),
        ])
    func wrongLengthThrows(raw: String, expectedLength: Int) throws {
        let result = Result { try Address(raw) }
        guard case .failure(let error) = result else {
            Issue.record("Expected ValidationError.wrongLength but got success for input: \(raw)")
            return
        }
        guard let ve = error as? Address.ValidationError,
            case .wrongLength(let actual) = ve
        else {
            Issue.record("Expected .wrongLength but got: \(error)")
            return
        }
        #expect(actual == expectedLength)
    }

    @Test("Non-hex character in body throws .nonHexCharacter")
    func nonHexCharThrows() {
        // 'g' is not in [0-9a-fA-F]
        #expect(throws: Address.ValidationError.nonHexCharacter) {
            try Address("0xgbcdef1234567890abcdef1234567890abcdef12")
        }
    }

    @Test("Space inside the hex body throws .nonHexCharacter")
    func spaceInBodyThrows() {
        #expect(throws: Address.ValidationError.nonHexCharacter) {
            try Address("0xabcdef 234567890abcdef1234567890abcdef12")
        }
    }

    @Test(
        "Failable init returns nil for invalid addresses",
        arguments: [
            "",
            "   ",
            "abcdef1234567890abcdef1234567890abcdef12",
            "0x",
            "0xabc",
            "0xgbcdef1234567890abcdef1234567890abcdef12",
        ])
    func failableInitReturnsNilForInvalid(raw: String) {
        #expect(Address(validating: raw) == nil)
    }
}

// MARK: - Property-style generator tests

@Suite("Address — property-style invariants")
struct AddressPropertyTests {

    private func randomHex(length: Int) -> String {
        let chars = Array("0123456789abcdef")
        return String((0..<length).map { _ in chars.randomElement()! })
    }

    @Test("Random valid 40-hex strings always parse (10 trials)")
    func randomValidAlwaysParses() throws {
        for _ in 0..<10 {
            let hex = randomHex(length: 40)
            let raw = "0x\(hex)"
            let addr = try Address(raw)
            #expect(addr.rawValue == raw)
        }
    }

    @Test("Random hex strings with length != 40 always reject (10 trials each side)")
    func randomWrongLengthAlwaysRejects() {
        for _ in 0..<10 {
            // Too short: 39
            let shortRaw = "0x\(randomHex(length: 39))"
            #expect(Address(validating: shortRaw) == nil)

            // Too long: 41
            let longRaw = "0x\(randomHex(length: 41))"
            #expect(Address(validating: longRaw) == nil)
        }
    }
}

// MARK: - Codable round-trip

@Suite("Address — Codable")
struct AddressCodableTests {

    @Test("Encodes as a JSON string and decodes back to equal value")
    func codableRoundTrip() throws {
        let original = try Address("0xabcdef1234567890abcdef1234567890abcdef12")
        let encoder = JSONEncoder()
        let data = try encoder.encode(original)
        let decoded = try JSONDecoder().decode(Address.self, from: data)
        #expect(decoded == original)
    }

    @Test("Decoded address from JSON bare string has lowercase rawValue")
    func decodedAddressIsLowercase() throws {
        // Address uses custom Codable synthesis encoding as a bare JSON string.
        // Construct from the mixed-case input and verify rawValue is lowercase.
        let addr = try Address("0xABCDEF1234567890ABCDEF1234567890ABCDEF12")
        let encoded = try JSONEncoder().encode(addr)
        let decoded = try JSONDecoder().decode(Address.self, from: encoded)
        #expect(decoded.rawValue == "0xabcdef1234567890abcdef1234567890abcdef12")
    }

    @Test("Custom Codable: encodes as bare string, not object")
    func encodesAsBareString() throws {
        let addr = try Address("0xabcdef1234567890abcdef1234567890abcdef12")
        let data = try JSONEncoder().encode(addr)
        let json = String(data: data, encoding: .utf8)!
        // Must be "\"0xabcdef...\"", not "{\"rawValue\":\"...\"}"
        #expect(json.hasPrefix("\"0x"))
    }
}
