// SPDX-License-Identifier: MIT

import Foundation

/// All monetary quantities in open-hl are `Decimal`. We deliberately do
/// NOT wrap `Decimal` in a newtype for v1.
///
/// Why a typealias and not a newtype:
/// - Hyperliquid mixes several quantity kinds in one response (USD account
///   value, asset position size, mark price, PnL, fees). A single `Money`
///   newtype would either lump them all together (no type-level safety) or
///   require a family of newtypes (`USDValue`, `AssetSize`, `Price`, etc.).
///   The family is a non-trivial design exercise we are not ready to
///   commit to in Phase 1, and Phase 1 does no arithmetic across kinds —
///   we display values, we do not multiply prices by sizes yet.
/// - `Decimal` already gives us what we actually care about: no binary-
///   floating-point rounding, `Codable`, `Sendable`, `Hashable`,
///   `Comparable`, and direct `Decimal.FormatStyle` support.
/// - The typealias documents intent at every use site without imposing a
///   wrapping/unwrapping tax on every call site. When Phase 2/3 introduces
///   arithmetic that would benefit from kind-level safety, we revisit.
///
/// Rule, enforced by code review and by the absence of `Double` in any
/// DTO or domain type: nothing on a money path may be a `Double` or
/// `Float`. Hyperliquid returns numeric strings; we decode them to
/// `Decimal` via `DecimalString` (see `DecimalString.swift`).
public typealias Money = Decimal
