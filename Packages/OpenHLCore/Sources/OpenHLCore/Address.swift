// SPDX-License-Identifier: MIT

import Foundation

/// A Hyperliquid wallet address: `0x` prefix followed by exactly 40 lowercase
/// hexadecimal characters. The canonical string form is always lowercase; the
/// throwing initializer accepts mixed case and lowercases on construction.
///
/// `Address` is a value type, `Sendable`, `Hashable`, and `Codable`. The
/// `Codable` form is the canonical lowercase string — never wrap it in an
/// object. Equality is over the canonical string, so two `Address` values
/// constructed from `"0xABC..."` and `"0xabc..."` compare equal.
///
/// Validation rules (enforced by the throwing initializer):
/// - Must start with `0x` (lowercase prefix; case-sensitive on the prefix).
/// - Must be exactly 42 characters total (`0x` + 40 hex digits).
/// - Every character after the prefix must be in `[0-9a-fA-F]`.
/// - No EIP-55 checksum verification in Phase 1. (We accept any case; we
///   normalize to lowercase. Checksum verification is a post-v1 nicety,
///   logged as a decision and deferred.)
///
/// Validation rules deliberately do NOT include:
/// - Whether the address has any on-chain activity.
/// - Whether the address is a contract or an EOA.
/// - EIP-55 mixed-case checksum verification.
public struct Address: Sendable, Hashable, CustomStringConvertible {

    /// Errors raised by the throwing initializer. Stable cases — view models
    /// match on these to choose user-facing copy for inline validation.
    public enum ValidationError: Error, Sendable, Equatable {
        /// Input is empty or contains only whitespace.
        case empty
        /// Input does not begin with the lowercase `0x` prefix.
        case missingPrefix
        /// Input is not exactly 42 characters (`0x` + 40 hex digits).
        case wrongLength(actual: Int)
        /// Input contains a non-hex character after the `0x` prefix.
        case nonHexCharacter
    }

    /// The canonical lowercase string form, including the `0x` prefix.
    /// Always 42 characters.
    public let rawValue: String

    /// Throwing initializer. Accepts mixed-case input; stores lowercase.
    /// Trims leading/trailing whitespace before validating.
    public init(_ string: String) throws {
        let trimmed = string.trimmingCharacters(in: .whitespaces)

        if trimmed.isEmpty {
            throw ValidationError.empty
        }

        // Prefix check is case-sensitive on the "0x" literal per the doc contract.
        // The hex digits after the prefix are case-insensitive and normalised to lowercase.
        guard trimmed.hasPrefix("0x") else {
            throw ValidationError.missingPrefix
        }

        let lowercased = trimmed.lowercased()

        guard lowercased.count == 42 else {
            throw ValidationError.wrongLength(actual: lowercased.count)
        }

        let hexPart = lowercased.dropFirst(2)
        let hexCharacters = CharacterSet(charactersIn: "0123456789abcdef")
        for char in hexPart.unicodeScalars {
            guard hexCharacters.contains(char) else {
                throw ValidationError.nonHexCharacter
            }
        }

        self.rawValue = lowercased
    }

    /// Non-throwing failable initializer. Returns `nil` for any input the
    /// throwing form would reject. Use this where the caller does not need
    /// to distinguish error cases (e.g. quick guards in tests).
    public init?(validating string: String) {
        guard let validated = try? Address(string) else { return nil }
        self = validated
    }

    public var description: String { rawValue }
}

// MARK: - Codable

/// `Address` encodes as a bare JSON string (`"0x..."`) — not as an object
/// (`{"rawValue":"..."}`). This ensures request bodies produced by
/// `InfoRequest` and any future encoding site emit the correct wire format
/// without extra layers of indirection. The initializer validates on decode,
/// so a malformed stored JSON string throws `DecodingError`.
extension Address: Codable {

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        do {
            try self.init(raw)
        } catch let error as ValidationError {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid Address string '\(raw)': \(error)"
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
