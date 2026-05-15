// SPDX-License-Identifier: MIT

import Foundation

/// Display formatters for `Decimal` values. These produce **localized**
/// strings — they respect the user's locale's grouping separator, decimal
/// separator, and (for currency) symbol position. They are not for
/// parsing — parsing money is `DecimalString`'s job and is locale-agnostic.
///
/// Three concerns drive this namespace:
///
/// 1. **Locale.** All formatters take an explicit `Locale` parameter and
///    default it to `.autoupdatingCurrent` so the output tracks the user
///    changing their region in Settings without a relaunch.
///
/// 2. **Decimal places.** Hyperliquid prices and sizes have variable
///    precision per asset; account values are always USD. Phase 1 ships
///    with two fixed precisions (USD = 2 fraction digits; PnL = 2;
///    percent = 2) because Phase 1 does not yet need per-asset precision.
///    Per-asset precision lands in Phase 2 alongside per-asset metadata.
///
/// 3. **Signed PnL.** Negative PnL must render with a leading `-` (or
///    locale-specific negative form); positive PnL must render with a
///    leading `+` to communicate gain/loss at a glance. The unsigned-zero
///    case renders without a sign. The percent formatter follows the
///    same rule.
///
/// Naming: every formatter takes a `Decimal` and returns a `String`. None
/// of them throw. `nil`-input variants return the empty string.
public enum MoneyFormatter {

    /// USD currency style: `"$1,234.56"`, `"-$1,234.56"`, `"$0.00"`.
    /// Two fraction digits, fixed. Used for account value, margin used,
    /// individual position values where the value is denominated in USD.
    /// **Not signed** — for unrealized PnL use `signedUSD`.
    public static func usd(
        _ value: Decimal,
        locale: Locale = .autoupdatingCurrent
    ) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter.string(from: value as NSDecimalNumber) ?? value.description
    }

    /// Signed USD: `"+$1,234.56"`, `"-$1,234.56"`, `"$0.00"`. Two fraction
    /// digits. Used for unrealized and realized PnL displays.
    public static func signedUSD(
        _ value: Decimal,
        locale: Locale = .autoupdatingCurrent
    ) -> String {
        let formatted = usd(value, locale: locale)
        if value > 0 {
            return "+\(formatted)"
        }
        return formatted
    }

    /// Signed percent: `"+12.34%"`, `"-1.20%"`, `"0.00%"`. Two fraction
    /// digits. Input is a raw ratio (`0.1234` -> `"+12.34%"`), not a
    /// pre-multiplied percent.
    public static func signedPercent(
        _ ratio: Decimal,
        locale: Locale = .autoupdatingCurrent
    ) -> String {
        // .percent style multiplies by 100 by default: 0.1234 -> "12.34%"
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .percent
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        let formatted = formatter.string(from: ratio as NSDecimalNumber) ?? "\(ratio)%"
        if ratio > 0 {
            return "+\(formatted)"
        }
        return formatted
    }

    /// Generic decimal with configurable precision; used for sizes and
    /// prices in Phase 1 placeholder displays. Locale-aware grouping and
    /// decimal separators. Not signed.
    public static func decimal(
        _ value: Decimal,
        minimumFractionDigits: Int,
        maximumFractionDigits: Int,
        locale: Locale = .autoupdatingCurrent
    ) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = minimumFractionDigits
        formatter.maximumFractionDigits = maximumFractionDigits
        return formatter.string(from: value as NSDecimalNumber) ?? value.description
    }
}

/// Optional-input convenience overloads. Return the empty string for
/// `nil`. Keeps view code free of `if let` ladders for fields like
/// `liquidationPx`.
extension MoneyFormatter {
    public static func usd(_ value: Decimal?, locale: Locale = .autoupdatingCurrent) -> String {
        value.map { usd($0, locale: locale) } ?? ""
    }
    public static func signedUSD(
        _ value: Decimal?,
        locale: Locale = .autoupdatingCurrent
    ) -> String {
        value.map { signedUSD($0, locale: locale) } ?? ""
    }
    public static func signedPercent(
        _ ratio: Decimal?,
        locale: Locale = .autoupdatingCurrent
    ) -> String {
        ratio.map { signedPercent($0, locale: locale) } ?? ""
    }
}
