// SPDX-License-Identifier: MIT

import Foundation

/// Property-wrapper-style `Codable` helper that decodes a JSON string
/// (`"1234.5"`) into a `Decimal` and re-encodes a `Decimal` back to a
/// JSON string. Use on every money field in every DTO.
///
/// Hyperliquid returns numbers as JSON strings (`"1234.5"`, `"-0.000123"`,
/// `"0"`). Decoding via the default `Decimal: Codable` conformance would
/// either fail (wrong type) or, via `Double`, lose precision. This wrapper
/// is the single approved path.
///
/// Usage:
/// ```swift
/// struct PositionDTO: Decodable, Sendable {
///     @DecimalString public var size: Decimal
///     @DecimalString public var entryPx: Decimal
///     @DecimalString public var unrealizedPnl: Decimal
/// }
/// ```
///
/// The wrapper:
/// - Decodes from `String`. Rejects `Double`/`Int` JSON tokens — if the
///   API ever switches to numeric tokens, we want to fail loudly and
///   re-decide the contract, not silently lose precision.
/// - Encodes as `String`. (We do not currently send money in request
///   bodies, but symmetry is cheap and useful in tests.)
/// - Trims surrounding whitespace before parsing.
/// - Accepts a leading `-` for negatives; does not accept `+`.
/// - Decimal grouping separators are rejected (Hyperliquid never emits
///   them; accepting them would invite locale bugs).
///
/// On decode failure, throws `DecodingError.dataCorruptedError` with a
/// path-aware message so `HyperliquidError.decoding` carries useful
/// context.
///
/// `Sendable` because `Decimal` is `Sendable`. `Equatable` and `Hashable`
/// pass through.
@propertyWrapper
public struct DecimalString: Codable, Sendable, Hashable {
    public var wrappedValue: Decimal

    public init(wrappedValue: Decimal) {
        self.wrappedValue = wrappedValue
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let value = DecimalParsing.parse(raw) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Could not parse '\(raw)' as Decimal at \(decoder.codingPath)"
            )
        }
        self.wrappedValue = value
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(wrappedValue.description)
    }
}

/// Optional variant: decodes `null` and missing keys as `nil`; otherwise
/// behaves exactly like `DecimalString`. Use for fields the API may omit
/// (e.g. `liquidationPx` on a position with no liquidation risk).
@propertyWrapper
public struct OptionalDecimalString: Codable, Sendable, Hashable {
    public var wrappedValue: Decimal?

    public init(wrappedValue: Decimal?) {
        self.wrappedValue = wrappedValue
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self.wrappedValue = nil
            return
        }
        let raw = try container.decode(String.self)
        guard let value = DecimalParsing.parse(raw) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription:
                    "Could not parse '\(raw)' as optional Decimal at \(decoder.codingPath)"
            )
        }
        self.wrappedValue = value
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        if let value = wrappedValue {
            try container.encode(value.description)
        } else {
            try container.encodeNil()
        }
    }
}

/// Sites that need to decode a money string outside a `Codable` context
/// (custom decoders, tests, ad-hoc parsing) call this. Same rules as
/// `DecimalString`. Returns `nil` for malformed input — callers decide
/// whether `nil` is fatal in their context.
public enum DecimalParsing {
    /// Parses a string into a `Decimal` using locale-agnostic rules.
    ///
    /// Accepted format: optional leading `-`, then one or more digits `0-9`,
    /// then an optional decimal point `.` followed by one or more digits.
    ///
    /// Rejected: leading `+`; grouping separators (`,`); scientific notation
    /// (`e`, `E`); multiple decimal points; bare `.`; empty or whitespace-only.
    ///
    /// Locale-agnostic: `.` is the only accepted decimal separator, regardless
    /// of system locale. Hyperliquid never uses locale-specific separators.
    public static func parse(_ string: String) -> Decimal? {
        let trimmed = string.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        // Validate the format strictly using a character-by-character scan.
        // Pattern: [-]digits[.digits]
        var index = trimmed.startIndex

        // Optional leading minus
        if trimmed[index] == "-" {
            index = trimmed.index(after: index)
        }

        guard index < trimmed.endIndex else { return nil }

        // Must start with a digit after optional minus
        let digits = CharacterSet.decimalDigits
        guard
            trimmed[index].unicodeScalars.first.map({ digits.contains($0) }) ?? false
        else { return nil }

        // Consume digits before optional decimal point
        while index < trimmed.endIndex,
            trimmed[index].unicodeScalars.first.map({ digits.contains($0) }) ?? false
        {
            index = trimmed.index(after: index)
        }

        // Optional decimal point followed by one or more digits
        if index < trimmed.endIndex {
            guard trimmed[index] == "." else { return nil }
            index = trimmed.index(after: index)
            guard index < trimmed.endIndex else { return nil }
            guard trimmed[index].unicodeScalars.first.map({ digits.contains($0) }) ?? false
            else { return nil }
            while index < trimmed.endIndex,
                trimmed[index].unicodeScalars.first.map({ digits.contains($0) }) ?? false
            {
                index = trimmed.index(after: index)
            }
        }

        // Must have consumed the entire string
        guard index == trimmed.endIndex else { return nil }

        // All validation passed — parse with Decimal(string:) locale-agnostically
        return Decimal(string: trimmed, locale: Locale(identifier: "en_US_POSIX"))
    }
}
