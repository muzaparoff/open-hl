// SPDX-License-Identifier: MIT

import Foundation
import OpenHLCore

/// Outbound subscription frame.
///
/// Hyperliquid's WebSocket protocol wraps every subscribe call in
/// `{"method": "subscribe", "subscription": { "type": "...", ... }}`.
/// We model the discriminator + parameters as an `enum` with associated
/// values and a custom `encode(to:)` that emits the flat wire shape —
/// same pattern as `InfoRequest` for the REST side. This guarantees
/// the discriminator and the parameters cannot drift apart.
///
/// Unsubscribe frames are intentionally not modeled. v1 keeps every
/// subscription alive for the lifetime of the WS task; channel switches
/// (e.g. user navigates from one Coin Detail to another) tear down the
/// stream's subscriber bookkeeping but leave the wire subscription in
/// place until the stream disconnects. This avoids a class of races where
/// an unsubscribe-then-resubscribe inside a single tick produces a
/// message gap.
public enum SubscriptionRequest: Encodable, Sendable, Equatable {
    case allMids
    case activeAssetCtx(coin: String)
    case candle(coin: String, interval: CandleInterval)
    case webData2(user: Address)

    private enum TopKeys: String, CodingKey {
        case method, subscription
    }

    private enum SubKeys: String, CodingKey {
        case type, coin, interval, user
    }

    public func encode(to encoder: any Encoder) throws {
        var top = encoder.container(keyedBy: TopKeys.self)
        try top.encode("subscribe", forKey: .method)
        var sub = top.nestedContainer(keyedBy: SubKeys.self, forKey: .subscription)
        switch self {
        case .allMids:
            try sub.encode("allMids", forKey: .type)
        case .activeAssetCtx(let coin):
            try sub.encode("activeAssetCtx", forKey: .type)
            try sub.encode(coin, forKey: .coin)
        case .candle(let coin, let interval):
            try sub.encode("candle", forKey: .type)
            try sub.encode(coin, forKey: .coin)
            try sub.encode(interval.rawValue, forKey: .interval)
        case .webData2(let user):
            try sub.encode("webData2", forKey: .type)
            try sub.encode(user.rawValue, forKey: .user)
        }
    }

    /// Stable identity key used by `URLSessionHyperliquidStream` to
    /// deduplicate wire subscriptions and to look up the subscriber set
    /// when a message arrives. Two `.candle("BTC", .oneHour)` values
    /// share a key so a second subscriber doesn't re-send the same
    /// subscribe frame.
    public var subscriptionKey: String {
        switch self {
        case .allMids: return "allMids"
        case .activeAssetCtx(let coin): return "activeAssetCtx:\(coin)"
        case .candle(let coin, let interval): return "candle:\(coin):\(interval.rawValue)"
        case .webData2(let user): return "webData2:\(user.rawValue)"
        }
    }
}
