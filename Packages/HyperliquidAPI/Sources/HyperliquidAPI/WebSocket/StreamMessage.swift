// SPDX-License-Identifier: MIT

import Foundation
import OpenHLCore

// MARK: - Public domain types surfaced by the WS layer

/// Live per-asset context emitted by the `activeAssetCtx` channel and
/// embedded inside `webData2.assetCtxs[]`.
///
/// This is the **public** counterpart to the internal `AssetContextDTO`
/// used by the REST `metaAndAssetCtxs` endpoint. We surface it as a
/// public type because the WS protocol exposes it (`HyperliquidStream`
/// returns it from `activeAssetCtx(coin:)`); REST callers never see it
/// directly — they consume the higher-level `Market` rollup.
///
/// All money fields are `Decimal`. `midPx`, `oraclePx`, and `premium`
/// are optional because the wire reports `null` for delisted/inactive
/// perps; the activeAssetCtx capture for BTC always populates them, but
/// the bulk `webData2.assetCtxs[]` array can include delisteds.
public struct AssetContext: Sendable, Equatable, Codable {
    public let funding: Decimal
    public let openInterest: Decimal
    public let prevDayPx: Decimal
    public let markPx: Decimal
    public let midPx: Decimal?
    public let oraclePx: Decimal?
    public let premium: Decimal?
    public let dayNotionalVolume: Decimal
    public let dayBaseVolume: Decimal?
    /// Two impact prices (bid impact / ask impact). Only present on the
    /// `activeAssetCtx` channel — `null`/absent in bulk `assetCtxs[]`.
    public let impactPxs: [Decimal]?

    public init(
        funding: Decimal,
        openInterest: Decimal,
        prevDayPx: Decimal,
        markPx: Decimal,
        midPx: Decimal?,
        oraclePx: Decimal?,
        premium: Decimal?,
        dayNotionalVolume: Decimal,
        dayBaseVolume: Decimal?,
        impactPxs: [Decimal]?
    ) {
        self.funding = funding
        self.openInterest = openInterest
        self.prevDayPx = prevDayPx
        self.markPx = markPx
        self.midPx = midPx
        self.oraclePx = oraclePx
        self.premium = premium
        self.dayNotionalVolume = dayNotionalVolume
        self.dayBaseVolume = dayBaseVolume
        self.impactPxs = impactPxs
    }

    private enum CodingKeys: String, CodingKey {
        case funding, openInterest, prevDayPx, markPx, midPx, oraclePx, premium
        case dayNtlVlm, dayBaseVlm, impactPxs
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.funding = try DecimalFieldParser.requireDecimalString(c, .funding)
        self.openInterest = try DecimalFieldParser.requireDecimalString(c, .openInterest)
        self.prevDayPx = try DecimalFieldParser.requireDecimalString(c, .prevDayPx)
        self.markPx = try DecimalFieldParser.requireDecimalString(c, .markPx)
        self.midPx = try DecimalFieldParser.optionalDecimalString(c, .midPx)
        self.oraclePx = try DecimalFieldParser.optionalDecimalString(c, .oraclePx)
        self.premium = try DecimalFieldParser.optionalDecimalString(c, .premium)
        self.dayNotionalVolume = try DecimalFieldParser.requireDecimalString(c, .dayNtlVlm)
        self.dayBaseVolume = try DecimalFieldParser.optionalDecimalString(c, .dayBaseVlm)
        if let arr = try c.decodeIfPresent([String].self, forKey: .impactPxs) {
            self.impactPxs = try arr.map { s in
                guard let d = Decimal(string: s) else {
                    throw DecodingError.dataCorruptedError(
                        forKey: .impactPxs, in: c,
                        debugDescription: "impactPxs element not a decimal: '\(s)'"
                    )
                }
                return d
            }
        } else {
            self.impactPxs = nil
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode("\(funding)", forKey: .funding)
        try c.encode("\(openInterest)", forKey: .openInterest)
        try c.encode("\(prevDayPx)", forKey: .prevDayPx)
        try c.encode("\(markPx)", forKey: .markPx)
        try c.encodeIfPresent(midPx.map { "\($0)" }, forKey: .midPx)
        try c.encodeIfPresent(oraclePx.map { "\($0)" }, forKey: .oraclePx)
        try c.encodeIfPresent(premium.map { "\($0)" }, forKey: .premium)
        try c.encode("\(dayNotionalVolume)", forKey: .dayNtlVlm)
        try c.encodeIfPresent(dayBaseVolume.map { "\($0)" }, forKey: .dayBaseVlm)
        try c.encodeIfPresent(impactPxs.map { $0.map { "\($0)" } }, forKey: .impactPxs)
    }
}

// MARK: - WebData2

/// One snapshot from the `webData2` channel: a complete account dump
/// for the subscribed wallet.
///
/// **Why a separate type and not the existing `ClearinghouseState`.**
/// The wire `webData2` envelope carries the account snapshot *plus*
/// the user's `openOrders` *plus* the public `[Market]` list *plus*
/// many other fields (spot, twap, vault, leading-vaults). It is the
/// **only** address-scoped channel and is intended to be a one-shot
/// source-of-truth update for the Wallet tab. Surfacing those bundled
/// pieces in a single Sendable struct means the live store can supersede
/// REST snapshots atomically — there's no window where positions are
/// fresh but orders are stale.
///
/// **What's modeled, what's dropped.** v1 surfaces the three fields the
/// UI uses today: positions (via `clearinghouseState`), open orders, and
/// the public markets list (via `meta + assetCtxs`). The wire-level
/// `spotState`, `spotAssetCtxs`, `twapStates`, `leadingVaults`,
/// `cumLedger`, `agentAddress`, `agentValidUntil`, `isVault`,
/// `totalVaultEquity`, `perpsAtOpenInterestCap` are all decoded
/// **leniently** (the envelope tolerates their presence but ignores
/// their contents) so a future Hyperliquid addition to those fields
/// does not break the decoder. The outer DTO's `init(from:)` reads only
/// the four fields we surface; everything else is implicitly ignored.
public struct WebData2: Sendable, Equatable {
    public let user: Address
    /// Server-stamped time of this dump, derived from the top-level
    /// `serverTime` epoch-ms.
    public let serverTime: Date
    public let clearinghouseState: ClearinghouseState
    public let openOrders: [OpenOrder]
    /// Public markets list assembled by zipping `meta.universe` with
    /// `assetCtxs`. Same shape the REST `markets()` call produces.
    public let markets: [Market]

    public init(
        user: Address,
        serverTime: Date,
        clearinghouseState: ClearinghouseState,
        openOrders: [OpenOrder],
        markets: [Market]
    ) {
        self.user = user
        self.serverTime = serverTime
        self.clearinghouseState = clearinghouseState
        self.openOrders = openOrders
        self.markets = markets
    }
}

// MARK: - StreamMessage

/// One decoded WebSocket frame from `wss://api.hyperliquid.xyz/ws`.
///
/// The envelope is `{"channel": "<name>", "data": {...}}`. We dispatch
/// on `channel` and surface the typed payload. Hyperliquid also emits
/// a `subscriptionResponse` ack on subscribe; we surface it so the
/// stream actor can log it but otherwise treat it as informational.
/// Unknown channels are returned as `.unknown(channel:)` rather than
/// thrown so a future Hyperliquid channel does not crash the loop.
public enum StreamMessage: Sendable, Equatable {
    case mids([String: Decimal])
    case activeAssetCtx(coin: String, AssetContext)
    case candle(Candle)
    case webData2(WebData2)
    /// Server-acknowledged subscription. The associated string is the
    /// channel name we subscribed to (e.g. `"allMids"`).
    case subscriptionAck(String)
    /// Server reported an error (typically a malformed subscription).
    case error(String)
    /// Pong response — Hyperliquid emits these in response to client
    /// `{"method":"ping"}` frames. v1 does not heartbeat; included for
    /// completeness so the decoder doesn't throw on one.
    case pong
    /// A channel name we don't recognize. Logged by the stream actor;
    /// not fanned out to any subscriber.
    case unknown(channel: String)

    // MARK: Decode entry point

    /// Decodes a single frame from raw `Data`. Throws on malformed JSON
    /// or on a known channel whose payload is shaped wrong (so tests
    /// can lock the contract); returns `.unknown` on an unknown channel.
    public static func decode(_ data: Data) throws -> StreamMessage {
        let decoder = JSONDecoder()
        let envelope = try decoder.decode(Envelope.self, from: data)
        switch envelope.channel {
        case "allMids":
            let payload = try decoder.decode(MidsEnvelope.self, from: data)
            return .mids(payload.data.mids)
        case "activeAssetCtx", "activeSpotAssetCtx":
            let payload = try decoder.decode(ActiveAssetCtxEnvelope.self, from: data)
            return .activeAssetCtx(coin: payload.data.coin, payload.data.ctx)
        case "candle":
            let payload = try decoder.decode(CandleEnvelope.self, from: data)
            return .candle(payload.data.toDomain())
        case "webData2":
            let payload = try decoder.decode(WebData2Envelope.self, from: data)
            return .webData2(try payload.data.toDomain())
        case "subscriptionResponse":
            let payload = try? decoder.decode(SubscriptionAckEnvelope.self, from: data)
            return .subscriptionAck(payload?.data.subscription.type ?? "")
        case "error":
            let payload = try? decoder.decode(ErrorEnvelope.self, from: data)
            return .error(payload?.data ?? "")
        case "pong":
            return .pong
        default:
            return .unknown(channel: envelope.channel)
        }
    }

    // MARK: Wire envelopes (file-private)

    private struct Envelope: Decodable {
        let channel: String
    }

    private struct MidsEnvelope: Decodable {
        let data: MidsData
        struct MidsData: Decodable {
            let mids: [String: Decimal]
            private enum CodingKeys: String, CodingKey { case mids }
            init(from decoder: any Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                let strings = try c.decode([String: String].self, forKey: .mids)
                var out: [String: Decimal] = [:]
                out.reserveCapacity(strings.count)
                for (k, v) in strings {
                    guard let d = Decimal(string: v) else {
                        throw DecodingError.dataCorruptedError(
                            forKey: .mids, in: c,
                            debugDescription: "mids['\(k)'] = '\(v)' is not a decimal"
                        )
                    }
                    out[k] = d
                }
                self.mids = out
            }
        }
    }

    private struct ActiveAssetCtxEnvelope: Decodable {
        let data: ActiveAssetCtxData
        struct ActiveAssetCtxData: Decodable {
            let coin: String
            let ctx: AssetContext
        }
    }

    private struct CandleEnvelope: Decodable {
        let data: CandleDTO
    }

    private struct WebData2Envelope: Decodable {
        let data: WebData2DTO
    }

    private struct SubscriptionAckEnvelope: Decodable {
        let data: AckData
        struct AckData: Decodable {
            let subscription: TypeOnly
            struct TypeOnly: Decodable { let type: String }
        }
    }

    private struct ErrorEnvelope: Decodable {
        let data: String
    }
}

// MARK: - WebData2 DTO and mapper

/// Wire shape of `webData2.data`. Lenient by construction: only the
/// four fields we surface in v1 are required; everything else is
/// silently ignored. Adding a future field (e.g. `spotState`) takes
/// one line here when the UI is ready for it.
private struct WebData2DTO: Decodable, Sendable {
    let clearinghouseState: WebData2ClearinghouseStateDTO
    let openOrders: [OpenOrderDTO]
    let meta: WebData2MetaDTO
    let assetCtxs: [AssetContext]
    let serverTime: Int64
    let user: String

    func toDomain() throws -> WebData2 {
        let address = try Address(user)
        let serverDate = Date(timeIntervalSince1970: TimeInterval(serverTime) / 1000.0)

        let positions = try clearinghouseState.assetPositions.map {
            assetPos -> ClearinghouseState.Position in
            guard assetPos.type == "oneWay" else {
                throw HyperliquidError.unexpectedResponse(
                    reason: "webData2: unknown assetPosition type '\(assetPos.type)'"
                )
            }
            let p = assetPos.position
            let leverage: ClearinghouseState.Position.LeverageMode
            switch p.leverage.type {
            case "cross": leverage = .cross(p.leverage.value)
            case "isolated": leverage = .isolated(p.leverage.value)
            default:
                throw HyperliquidError.unexpectedResponse(
                    reason: "webData2: unknown leverage type '\(p.leverage.type)'"
                )
            }
            let side: ClearinghouseState.Position.Side = p.szi >= 0 ? .long : .short
            return ClearinghouseState.Position(
                coin: p.coin,
                size: p.szi,
                side: side,
                entryPrice: p.entryPx,
                positionValue: p.positionValue,
                unrealizedPnL: p.unrealizedPnl,
                returnOnEquity: p.returnOnEquity,
                liquidationPrice: p.liquidationPx,
                marginUsed: p.marginUsed,
                leverage: leverage
            )
        }

        let summary = ClearinghouseState.AccountSummary(
            accountValue: clearinghouseState.marginSummary.accountValue,
            totalNotionalPosition: clearinghouseState.marginSummary.totalNtlPos,
            totalRawUSD: clearinghouseState.marginSummary.totalRawUsd,
            totalMarginUsed: clearinghouseState.marginSummary.totalMarginUsed,
            withdrawable: clearinghouseState.withdrawable
        )

        let clearing = ClearinghouseState(
            summary: summary,
            positions: positions,
            serverTime: serverDate,
            fetchedAt: serverDate
        )

        let orders = try openOrders.map { try Self.mapOpenOrder($0) }

        // Same shape as MetaAndAssetCtxsDTO.toMarkets() — kept inline
        // because the WebData2 meta has additional, ignorable fields
        // and we don't want to share the strict REST DTO struct.
        let perpCount = min(meta.universe.count, assetCtxs.count)
        var markets: [Market] = []
        markets.reserveCapacity(perpCount)
        for i in 0..<perpCount {
            let p = meta.universe[i]
            let c = assetCtxs[i]
            markets.append(
                Market(
                    coin: p.name,
                    maxLeverage: p.maxLeverage,
                    szDecimals: p.szDecimals,
                    onlyIsolated: p.onlyIsolated ?? false,
                    markPrice: c.markPx,
                    midPrice: c.midPx,
                    prevDayPrice: c.prevDayPx,
                    openInterest: c.openInterest,
                    dayNotionalVolume: c.dayNotionalVolume,
                    fundingRate: c.funding
                )
            )
        }

        return WebData2(
            user: address,
            serverTime: serverDate,
            clearinghouseState: clearing,
            openOrders: orders,
            markets: markets
        )
    }

    /// Local copy of the OpenOrderDTO -> OpenOrder mapper. We can't
    /// reach the private static `URLSessionHyperliquidClient.mapOpenOrderDTO`
    /// from here; duplicating the four-case switch is cheaper than
    /// hoisting it into a fileprivate-shared helper that would then need
    /// access to the OpenOrder enum cases anyway.
    private static func mapOpenOrder(_ dto: OpenOrderDTO) throws -> OpenOrder {
        let side: OpenOrder.Side
        switch dto.side {
        case "B": side = .buy
        case "A": side = .sell
        default:
            throw HyperliquidError.unexpectedResponse(
                reason: "webData2.openOrders: unknown side '\(dto.side)'"
            )
        }
        let orderType: OpenOrder.OrderType
        switch dto.orderType {
        case nil, "Limit": orderType = .limit
        case "Trigger": orderType = .trigger
        case "Stop Limit": orderType = .stopLimit
        case "Stop Market": orderType = .stopMarket
        case "Take Profit Limit": orderType = .takeProfitLimit
        case "Take Profit Market": orderType = .takeProfitMarket
        default: orderType = .unknown(dto.orderType ?? "")
        }
        return OpenOrder(
            oid: dto.oid,
            coin: dto.coin,
            side: side,
            limitPrice: dto.limitPx,
            size: dto.sz,
            origSize: dto.origSz,
            orderType: orderType,
            reduceOnly: dto.reduceOnly ?? false,
            triggerPrice: dto.triggerPx,
            placedAt: Date(timeIntervalSince1970: TimeInterval(dto.timestamp) / 1000.0)
        )
    }
}

/// Mirror of `ClearinghouseStateDTO` plus one extra wire field
/// (`crossMaintenanceMarginUsed`) that the WS variant carries. We keep
/// it as a separate type so the REST DTO doesn't grow a field it
/// doesn't need.
private struct WebData2ClearinghouseStateDTO: Decodable, Sendable {
    struct MarginSummaryDTO: Decodable, Sendable {
        @DecimalString var accountValue: Decimal
        @DecimalString var totalNtlPos: Decimal
        @DecimalString var totalRawUsd: Decimal
        @DecimalString var totalMarginUsed: Decimal
    }

    struct AssetPositionDTO: Decodable, Sendable {
        let type: String
        let position: PositionDTO
    }

    struct PositionDTO: Decodable, Sendable {
        let coin: String
        @DecimalString var szi: Decimal
        @DecimalString var entryPx: Decimal
        @DecimalString var positionValue: Decimal
        @DecimalString var unrealizedPnl: Decimal
        @DecimalString var returnOnEquity: Decimal
        @OptionalDecimalString var liquidationPx: Decimal?
        @DecimalString var marginUsed: Decimal
        let leverage: LeverageDTO
    }

    struct LeverageDTO: Decodable, Sendable {
        let type: String
        let value: Int
    }

    let marginSummary: MarginSummaryDTO
    @DecimalString var withdrawable: Decimal
    let assetPositions: [AssetPositionDTO]
}

/// Lenient meta block. The webData2 `meta.universe[]` items carry
/// extra wire fields (`marginTableId`, `isDelisted`) absent from the
/// REST counterpart; ignoring them via `decode` (vs. `init(from:)` with
/// strict CodingKeys) keeps us forward-compatible.
private struct WebData2MetaDTO: Decodable, Sendable {
    let universe: [PerpInfoDTO]

    struct PerpInfoDTO: Decodable, Sendable {
        let name: String
        let szDecimals: Int
        let maxLeverage: Int
        let onlyIsolated: Bool?
    }
}

// MARK: - Decimal parsing helpers used by AssetContext

/// Local helpers: AssetContext can't use `@DecimalString` property
/// wrappers because we need a hand-rolled `init(from:)` (the impactPxs
/// array decode forces it). These helpers mirror what
/// `@DecimalString` / `@OptionalDecimalString` do internally — string
/// token in, `Decimal` out, path-aware error on malformed input.
private enum DecimalFieldParser {
    static func requireDecimalString<K: CodingKey>(
        _ c: KeyedDecodingContainer<K>,
        _ key: K
    ) throws -> Decimal {
        let s = try c.decode(String.self, forKey: key)
        guard let d = Decimal(string: s) else {
            throw DecodingError.dataCorruptedError(
                forKey: key, in: c,
                debugDescription: "Field '\(key.stringValue)' = '\(s)' is not a decimal"
            )
        }
        return d
    }

    static func optionalDecimalString<K: CodingKey>(
        _ c: KeyedDecodingContainer<K>,
        _ key: K
    ) throws -> Decimal? {
        guard let s = try c.decodeIfPresent(String.self, forKey: key) else { return nil }
        guard let d = Decimal(string: s) else {
            throw DecodingError.dataCorruptedError(
                forKey: key, in: c,
                debugDescription: "Field '\(key.stringValue)' = '\(s)' is not a decimal"
            )
        }
        return d
    }
}
