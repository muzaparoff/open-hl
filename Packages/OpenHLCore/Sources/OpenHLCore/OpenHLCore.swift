// SPDX-License-Identifier: MIT

// OpenHLCore — shared value types, formatters, and error types.
//
// Phase 1 public API surface is split across:
//   - Address.swift           the `Address` value type
//   - Money.swift             the `Money = Decimal` typealias
//   - DecimalString.swift     the `@DecimalString` property wrapper
//   - Formatters.swift        `MoneyFormatter` namespace
//   - Clock.swift             `Clock` protocol + implementations
//
// This file retains only the module version constant.

/// The current semantic version of the OpenHLCore package.
/// Bumped alongside the app version; used in tests as a minimal
/// compile-time proof that the module is reachable.
public let openHLCoreVersion: String = "0.0.0"
