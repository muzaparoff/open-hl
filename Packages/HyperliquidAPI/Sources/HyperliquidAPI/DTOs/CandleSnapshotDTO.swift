// SPDX-License-Identifier: MIT

import Foundation
import OpenHLCore

/// Wire shape of one OHLCV bar in the `candleSnapshot` response.
///
/// Hyperliquid uses single-character keys to keep the payload small over
/// the wire. Money fields arrive as strings — `@DecimalString` parses
/// them with full precision.
internal struct CandleDTO: Decodable, Sendable {
    /// Open time, epoch milliseconds.
    let t: Int64
    /// Close time, epoch milliseconds. The wire key is uppercase `"T"` which
    /// is lower-camelCase-incompatible — remap via `CodingKeys`.
    let closeTime: Int64
    /// Coin symbol.
    let s: String
    /// Interval (e.g. "1h").
    let i: String
    @DecimalString var o: Decimal  // open
    @DecimalString var c: Decimal  // close
    @DecimalString var h: Decimal  // high
    @DecimalString var l: Decimal  // low
    @DecimalString var v: Decimal  // volume (coin units)
    /// Number of trades that contributed to this bar.
    let n: Int

    private enum CodingKeys: String, CodingKey {
        case t
        case closeTime = "T"
        case s, i, o, c, h, l, v, n
    }
}

extension CandleDTO {
    /// Map a single `CandleDTO` to a `Candle`, falling back to
    /// `.oneHour` if the wire interval is unknown (matches the
    /// defensive posture of `[CandleDTO].toCandles()` which drops
    /// unknown intervals — here we cannot drop because the WS
    /// `candle` channel emits a single bar per frame; an unknown
    /// interval is a forward-compat surprise we'd rather render than
    /// silently swallow).
    func toDomain() -> Candle {
        let interval = CandleInterval(rawValue: i) ?? .oneHour
        return Candle(
            coin: s,
            interval: interval,
            openTime: Date(timeIntervalSince1970: TimeInterval(t) / 1000.0),
            closeTime: Date(timeIntervalSince1970: TimeInterval(closeTime) / 1000.0),
            open: o,
            close: c,
            high: h,
            low: l,
            volume: v,
            tradeCount: n
        )
    }
}

extension Array where Element == CandleDTO {
    /// Map an array of `CandleDTO` to `[Candle]`, decoding the interval
    /// string. Drops bars with an unknown interval (defensive — in
    /// practice Hyperliquid only ever returns intervals we asked for).
    func toCandles() -> [Candle] {
        compactMap { dto in
            guard let interval = CandleInterval(rawValue: dto.i) else {
                return nil
            }
            return Candle(
                coin: dto.s,
                interval: interval,
                openTime: Date(timeIntervalSince1970: TimeInterval(dto.t) / 1000.0),
                closeTime: Date(timeIntervalSince1970: TimeInterval(dto.closeTime) / 1000.0),
                open: dto.o,
                close: dto.c,
                high: dto.h,
                low: dto.l,
                volume: dto.v,
                tradeCount: dto.n
            )
        }
    }
}
