import Foundation

/// Loosely typed JSON value for strategy parameters.
public enum JSONValue: Codable, Hashable {
    case number(Double)
    case string(String)
    case bool(Bool)
    case null

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let d = try? c.decode(Double.self) { self = .number(d) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else { self = .null }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .number(let d): try c.encode(d)
        case .string(let s): try c.encode(s)
        case .bool(let b): try c.encode(b)
        case .null: try c.encodeNil()
        }
    }

    public var double: Double? {
        switch self {
        case .number(let d): return d
        case .string(let s): return Double(s)
        case .bool(let b): return b ? 1 : 0
        case .null: return nil
        }
    }

    public var bool: Bool { if case .bool(let b) = self { return b }; return (double ?? 0) != 0 }

    public var string: String {
        switch self {
        case .string(let s): return s
        case .number(let d): return d.formatted()
        case .bool(let b): return b ? String(localized: "Yes") : String(localized: "No")
        case .null: return "–"
        }
    }
}

public struct ServerStatus: Codable {
    public let version: String
    public let exchange: String
    public let exchangeOk: Bool
    public let exchangeError: String?
    public let engineError: String?
    public let liveTradingAllowed: Bool
    public let lastTick: Int64?
    public let tickSeconds: Int
    /// Exchange fee per order as a fraction (0.0009 = 0.09 %); older agents don't send it.
    public let takerFee: Double?
    /// Whether the agent has an Anthropic API key for the "AI decides" strategy (nil: older agent).
    public let aiConfigured: Bool?

    enum CodingKeys: String, CodingKey {
        case version, exchange
        case exchangeOk = "exchange_ok"
        case exchangeError = "exchange_error"
        case engineError = "engine_error"
        case liveTradingAllowed = "live_trading_allowed"
        case lastTick = "last_tick"
        case tickSeconds = "tick_seconds"
        case takerFee = "taker_fee"
        case aiConfigured = "ai_configured"
    }
}

public struct CurrencyTotal: Codable, Identifiable {
    public let currency: String
    public let realized: Double
    public let unrealized: Double
    public let today: Double
    public let invested: Double
    public let total: Double
    /// Exchange fees paid so far; older agents don't send it.
    public let fees: Double?
    public var id: String { currency }
}

public struct OtherModeTotal: Codable {
    public let currency: String
    public let total: Double
}

public struct Summary: Codable {
    public let currencies: [CurrencyTotal]
    /// "paper" or "live" – the mode the numbers above belong to (older agents mix both and send nothing).
    public let mode: String?
    /// The other mode's result per currency, and how many trades it has.
    public let otherMode: [OtherModeTotal]?
    public let otherModeTrades: Int?
    public let botsTotal: Int
    public let botsActive: Int
    public let openPositions: Int
    public let maxOpenPositions: Int?
    public let tradesCount: Int

    enum CodingKeys: String, CodingKey {
        case currencies, mode
        case otherMode = "other_mode"
        case otherModeTrades = "other_mode_trades"
        case botsTotal = "bots_total"
        case botsActive = "bots_active"
        case openPositions = "open_positions"
        case maxOpenPositions = "max_open_positions"
        case tradesCount = "trades_count"
    }
}

/// One open trade – or, as `Bot.position`, all of a bot's trades summed up.
public struct BotPosition: Codable, Equatable, Identifiable {
    public let id: String? // agent 1.13+; a bot can hold several trades at once
    public let qty: Double
    public let cost: Double
    public let entryPrice: Double
    public let openedAt: Int64
    public let value: Double
    public let unrealizedPnl: Double
    public let unrealizedPct: Double
    public let paper: Bool?
    // per trade (agent 1.13+): the price its sale waits for, its stop, or the strategy's note
    public let sellPrice: Double?
    public let stopPrice: Double?
    public let note: String?

    enum CodingKeys: String, CodingKey {
        case id, qty, cost, value, paper, note
        case entryPrice = "entry_price"
        case sellPrice = "sell_price"
        case stopPrice = "stop_price"
        case openedAt = "opened_at"
        case unrealizedPnl = "unrealized_pnl"
        case unrealizedPct = "unrealized_pct"
    }
}

public struct MarketInfo: Codable, Equatable {
    public let price: Double
    public let change24h: Double

    enum CodingKeys: String, CodingKey {
        case price
        case change24h = "change_24h"
    }
}

/// The prices a bot waits for – a buy below, a sale above, the stop below – or a note when there is no fixed price.
public struct BotTargets: Codable, Equatable {
    public let buyPrice: Double?
    public let sellPrice: Double?
    public let stopPrice: Double?
    public let note: String?
    // with open trades a further buy needs both: the strategy's own signal and the distance to the open trades
    // (agent 1.15+); `buyPrice` is the stricter of the two
    public let signalPrice: Double?
    public let spacingPrice: Double?

    enum CodingKeys: String, CodingKey {
        case buyPrice = "buy_price"
        case signalPrice = "signal_price"
        case spacingPrice = "spacing_price"
        case sellPrice = "sell_price"
        case stopPrice = "stop_price"
        case note
    }
}

/// How far the price still has to move until the bot trades – what the card shows first.
public struct BotGoal {
    public enum Kind { case buy, sell, trailingStart, trailingStop }

    public let kind: Kind
    public let target: Double
    public let percent: Double // target relative to the current price
    public let reached: Bool
}

public struct Bot: Codable, Identifiable, Equatable {
    public let id: Int
    public let name: String
    public let strategy: String
    public let strategyName: String
    public let strategyIcon: String
    public let symbol: String
    public let baseCurrency: String
    public let quoteCurrency: String
    public let params: [String: JSONValue]
    public let enabled: Bool
    public let paper: Bool
    public let paperRequested: Bool
    public let status: String
    public let statusError: Bool?
    public let hint: String? // e.g. a buy signal the limits blocked – shown until the limits allow it
    public let targets: BotTargets? // what the bot waits for (agent 1.12+)
    public let lastCheck: Int64?
    public let createdAt: Int64
    public let pendingOrder: Bool
    public let position: BotPosition? // all open trades summed up
    public let positions: [BotPosition]? // the open trades one by one (agent 1.13+)
    public let maxTrades: Int? // how many trades the bot may hold at once (agent 1.13+)
    public let realizedPnl: Double
    public let tradesCount: Int
    public let wins: Int
    public let losses: Int
    public let market: MarketInfo?

    enum CodingKeys: String, CodingKey {
        case id, name, strategy, symbol, params, enabled, paper, status, hint, targets, position, positions, wins, losses, market
        case maxTrades = "max_trades"
        case strategyName = "strategy_name"
        case strategyIcon = "strategy_icon"
        case baseCurrency = "base_currency"
        case quoteCurrency = "quote_currency"
        case paperRequested = "paper_requested"
        case statusError = "status_error"
        case lastCheck = "last_check"
        case createdAt = "created_at"
        case pendingOrder = "pending_order"
        case realizedPnl = "realized_pnl"
        case tradesCount = "trades_count"
    }

    public var totalPnl: Double { realizedPnl + (position?.unrealizedPnl ?? 0) }

    /// The open trades one by one – older agents only send the single position.
    public var openTrades: [BotPosition] { positions ?? (position.map { [$0] } ?? []) }

    /// True when the bot may hold more than one trade (or does) – the card then lists them.
    public var tradesMode: Bool { (maxTrades ?? 1) > 1 || openTrades.count > 1 }

    /// The next trade trigger with a fixed price: the buy price while waiting, the sale (or the trailing stop) with a
    /// position. Nil for strategies without one (AI decides, the savings plan's next instalment) or old agents.
    public var goal: BotGoal? {
        guard let targets, let price = market?.price, price > 0 else { return nil }
        let kind: BotGoal.Kind
        let target: Double
        // a buy price comes only while the bot may open another trade
        if let buy = targets.buyPrice {
            kind = .buy
            target = buy
        } else if position != nil, let sell = targets.sellPrice {
            // the trailing strategy first waits for the activation price above, then sells when the stop below is hit
            kind = strategy == "trailing" ? (sell < price ? .trailingStop : .trailingStart) : .sell
            target = sell
        } else {
            return nil
        }
        let reached: Bool
        switch kind {
        case .buy, .trailingStop: reached = price <= target
        case .sell, .trailingStart: reached = price >= target
        }
        return BotGoal(kind: kind, target: target, percent: (target / price - 1) * 100, reached: reached)
    }
}

public struct Trade: Codable, Identifiable, Equatable {
    /// A sale's result relative to what the sold coins cost (proceeds after fees minus the result = their cost).
    public var pnlPct: Double? {
        guard let pnl, quoteAmount - pnl > 0 else { return nil }
        return pnl / (quoteAmount - pnl) * 100
    }

    public let id: Int
    public let botId: Int
    public let botName: String
    public let symbol: String
    public let side: String
    public let price: Double
    public let baseQty: Double
    public let quoteAmount: Double
    public let fee: Double
    public let pnl: Double?
    public let orderId: String?
    public let paper: Bool
    public let reason: String
    public let createdAt: Int64
    /// The trade (position) a buy opened or added to and a sale closed – agent 1.17+; nil for older trades.
    public let positionId: String?

    enum CodingKeys: String, CodingKey {
        case id, symbol, side, price, fee, pnl, paper, reason
        case positionId = "position_id"
        case botId = "bot_id"
        case botName = "bot_name"
        case baseQty = "base_qty"
        case quoteAmount = "quote_amount"
        case orderId = "order_id"
        case createdAt = "created_at"
    }

    public var isBuy: Bool { side == "buy" }
    public var base: String { String(symbol.split(separator: "-").first ?? "") }
    public var quote: String { String(symbol.split(separator: "-").last ?? "EUR") }
    public var date: Date { Date(ms: createdAt) }
}

public struct SelectOption: Codable, Hashable {
    public let value: String
    public let label: String
}

public struct StrategyParam: Codable, Identifiable {
    public let key: String
    public let label: String
    public let type: String
    public let `default`: JSONValue
    public let help: String?
    public let min: Double?
    public let max: Double?
    public let step: Double?
    public let options: [SelectOption]?
    public let unit: String?
    public var id: String { key }
}

public struct Strategy: Codable, Identifiable {
    public let key: String
    public let name: String
    public let description: String
    public let icon: String
    public let params: [StrategyParam]
    public var id: String { key }
}

/// One answer of Claude for an "AI decides" bot.
public struct AiDecision: Codable, Identifiable {
    public let id: Int
    public let action: String // buy | wait | hold | sell
    public let confidence: Int // 0–100
    public let reason: String
    public let price: Double
    public let profitPct: Double?
    public let createdAt: Int64

    enum CodingKeys: String, CodingKey {
        case id, action, confidence, reason, price
        case profitPct = "profit_pct"
        case createdAt = "created_at"
    }
}

public struct BotEvent: Codable, Identifiable {
    public let id: Int
    public let botId: Int?
    public let level: String
    public let message: String
    public let createdAt: Int64

    enum CodingKeys: String, CodingKey {
        case id, level, message
        case botId = "bot_id"
        case createdAt = "created_at"
    }
}

public struct Balance: Codable, Identifiable {
    public let currency: String
    public let available: Double
    public let total: Double
    public var id: String { currency }
}

/// Revolut X connection as configured on the agent. The private key never leaves the agent.
public struct ExchangeInfo: Codable, Equatable {
    public let source: String // "env" (.env on the agent), "app" (set up via this app) or "none"
    public let apiKeyMasked: String?
    public let publicKey: String?
    public let pendingPublicKey: String?
    public let mode: String // "revolutx" | "mock"
    public let connected: Bool
    public let error: String?
    public let apiKeysUrl: String

    enum CodingKeys: String, CodingKey {
        case source, mode, connected, error
        case apiKeyMasked = "api_key_masked"
        case publicKey = "public_key"
        case pendingPublicKey = "pending_public_key"
        case apiKeysUrl = "api_keys_url"
    }
}

public struct PublicIP: Codable { public let ip: String }

/// Response of restoring a backup on the agent.
public struct RestoreResult: Decodable {
    public let bots: Int
    public let trades: Int
    public let liveTradingDisabled: Bool
    public let credentialsRestored: Bool
    public let createdAt: Int64?
    public let agentVersion: String?

    enum CodingKeys: String, CodingKey {
        case bots, trades
        case liveTradingDisabled = "live_trading_disabled"
        case credentialsRestored = "credentials_restored"
        case createdAt = "created_at"
        case agentVersion = "agent_version"
    }
}

/// Response of switching the live mode; switching back to paper sells all open live positions.
public struct LiveSwitchResult: Decodable {
    public struct ClosedPosition: Decodable, Identifiable {
        public let botId: Int
        public let botName: String
        public let ok: Bool
        public let message: String
        public var id: Int { botId }

        enum CodingKeys: String, CodingKey {
            case ok, message
            case botId = "bot_id"
            case botName = "bot_name"
        }
    }

    public let closedPositions: [ClosedPosition]

    enum CodingKeys: String, CodingKey {
        case closedPositions = "closed_positions"
    }
}

/// Global risk limits enforced by the agent engine.
public struct Limits: Codable, Equatable {
    public var maxOpenPositions: Int
    public var maxTotalInvested: Double
    public var onePositionPerSymbol: Bool
    public var openPositions: Int?
    public var invested: Double?

    enum CodingKeys: String, CodingKey {
        case maxOpenPositions = "max_open_positions"
        case maxTotalInvested = "max_total_invested"
        case onePositionPerSymbol = "one_position_per_symbol"
        case openPositions = "open_positions"
        case invested
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(maxOpenPositions, forKey: .maxOpenPositions)
        try c.encode(maxTotalInvested, forKey: .maxTotalInvested)
        try c.encode(onePositionPerSymbol, forKey: .onePositionPerSymbol)
    }
}

/// Fees the simulation (paper mode) charges, as fractions (0.0009 = 0.09 %).
public struct PaperFees: Codable, Equatable {
    public var buy: Double
    public var sell: Double

    public init(buy: Double, sell: Double) {
        self.buy = buy
        self.sell = sell
    }
}

public struct BotInput: Encodable {
    public var name: String
    public var strategy: String
    public var symbol: String
    public var params: [String: JSONValue]
    public var enabled: Bool
    public var paper: Bool

    public init(name: String, strategy: String, symbol: String, params: [String: JSONValue], enabled: Bool, paper: Bool) {
        self.name = name
        self.strategy = strategy
        self.symbol = symbol
        self.params = params
        self.enabled = enabled
        self.paper = paper
    }
}

extension Date {
    public init(ms: Int64) { self.init(timeIntervalSince1970: TimeInterval(ms) / 1000) }
}
