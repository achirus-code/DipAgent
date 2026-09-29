import Foundation

/// Loosely typed JSON value for strategy parameters.
enum JSONValue: Codable, Hashable {
    case number(Double)
    case string(String)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let d = try? c.decode(Double.self) { self = .number(d) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else { self = .null }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .number(let d): try c.encode(d)
        case .string(let s): try c.encode(s)
        case .bool(let b): try c.encode(b)
        case .null: try c.encodeNil()
        }
    }

    var double: Double? {
        switch self {
        case .number(let d): return d
        case .string(let s): return Double(s)
        case .bool(let b): return b ? 1 : 0
        case .null: return nil
        }
    }

    var bool: Bool { if case .bool(let b) = self { return b }; return (double ?? 0) != 0 }

    var string: String {
        switch self {
        case .string(let s): return s
        case .number(let d): return d.formatted()
        case .bool(let b): return b ? String(localized: "Yes") : String(localized: "No")
        case .null: return "–"
        }
    }
}

struct ServerStatus: Codable {
    let version: String
    let exchange: String
    let exchangeOk: Bool
    let exchangeError: String?
    let engineError: String?
    let liveTradingAllowed: Bool
    let lastTick: Int64?
    let tickSeconds: Int
    /// Exchange fee per order as a fraction (0.0009 = 0.09 %); older agents don't send it.
    let takerFee: Double?
    /// Whether the agent has an Anthropic API key for the "AI decides" strategy (nil: older agent).
    let aiConfigured: Bool?

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

struct CurrencyTotal: Codable, Identifiable {
    let currency: String
    let realized: Double
    let unrealized: Double
    let today: Double
    let invested: Double
    let total: Double
    /// Exchange fees paid so far; older agents don't send it.
    let fees: Double?
    var id: String { currency }
}

struct Summary: Codable {
    let currencies: [CurrencyTotal]
    let botsTotal: Int
    let botsActive: Int
    let openPositions: Int
    let maxOpenPositions: Int?
    let tradesCount: Int

    enum CodingKeys: String, CodingKey {
        case currencies
        case botsTotal = "bots_total"
        case botsActive = "bots_active"
        case openPositions = "open_positions"
        case maxOpenPositions = "max_open_positions"
        case tradesCount = "trades_count"
    }
}

struct BotPosition: Codable, Equatable {
    let qty: Double
    let cost: Double
    let entryPrice: Double
    let openedAt: Int64
    let value: Double
    let unrealizedPnl: Double
    let unrealizedPct: Double
    let paper: Bool?

    enum CodingKeys: String, CodingKey {
        case qty, cost, value, paper
        case entryPrice = "entry_price"
        case openedAt = "opened_at"
        case unrealizedPnl = "unrealized_pnl"
        case unrealizedPct = "unrealized_pct"
    }
}

struct MarketInfo: Codable, Equatable {
    let price: Double
    let change24h: Double

    enum CodingKeys: String, CodingKey {
        case price
        case change24h = "change_24h"
    }
}

struct Bot: Codable, Identifiable, Equatable {
    let id: Int
    let name: String
    let strategy: String
    let strategyName: String
    let strategyIcon: String
    let symbol: String
    let baseCurrency: String
    let quoteCurrency: String
    let params: [String: JSONValue]
    let enabled: Bool
    let paper: Bool
    let paperRequested: Bool
    let status: String
    let statusError: Bool?
    let hint: String? // e.g. a buy signal the limits blocked – shown until the limits allow it
    let lastCheck: Int64?
    let createdAt: Int64
    let pendingOrder: Bool
    let position: BotPosition?
    let realizedPnl: Double
    let tradesCount: Int
    let wins: Int
    let losses: Int
    let market: MarketInfo?

    enum CodingKeys: String, CodingKey {
        case id, name, strategy, symbol, params, enabled, paper, status, hint, position, wins, losses, market
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

    var totalPnl: Double { realizedPnl + (position?.unrealizedPnl ?? 0) }
}

struct Trade: Codable, Identifiable, Equatable {
    let id: Int
    let botId: Int
    let botName: String
    let symbol: String
    let side: String
    let price: Double
    let baseQty: Double
    let quoteAmount: Double
    let fee: Double
    let pnl: Double?
    let orderId: String?
    let paper: Bool
    let reason: String
    let createdAt: Int64

    enum CodingKeys: String, CodingKey {
        case id, symbol, side, price, fee, pnl, paper, reason
        case botId = "bot_id"
        case botName = "bot_name"
        case baseQty = "base_qty"
        case quoteAmount = "quote_amount"
        case orderId = "order_id"
        case createdAt = "created_at"
    }

    var isBuy: Bool { side == "buy" }
    var base: String { String(symbol.split(separator: "-").first ?? "") }
    var quote: String { String(symbol.split(separator: "-").last ?? "EUR") }
    var date: Date { Date(ms: createdAt) }
}

struct SelectOption: Codable, Hashable {
    let value: String
    let label: String
}

struct StrategyParam: Codable, Identifiable {
    let key: String
    let label: String
    let type: String
    let `default`: JSONValue
    let help: String?
    let min: Double?
    let max: Double?
    let step: Double?
    let options: [SelectOption]?
    let unit: String?
    var id: String { key }
}

struct Strategy: Codable, Identifiable {
    let key: String
    let name: String
    let description: String
    let icon: String
    let params: [StrategyParam]
    var id: String { key }
}

/// One answer of Claude for an "AI decides" bot.
struct AiDecision: Codable, Identifiable {
    let id: Int
    let action: String // buy | wait | hold | sell
    let confidence: Int // 0–100
    let reason: String
    let price: Double
    let profitPct: Double?
    let createdAt: Int64

    enum CodingKeys: String, CodingKey {
        case id, action, confidence, reason, price
        case profitPct = "profit_pct"
        case createdAt = "created_at"
    }
}

struct BotEvent: Codable, Identifiable {
    let id: Int
    let botId: Int?
    let level: String
    let message: String
    let createdAt: Int64

    enum CodingKeys: String, CodingKey {
        case id, level, message
        case botId = "bot_id"
        case createdAt = "created_at"
    }
}

struct Balance: Codable, Identifiable {
    let currency: String
    let available: Double
    let total: Double
    var id: String { currency }
}

/// Revolut X connection as configured on the agent. The private key never leaves the agent.
struct ExchangeInfo: Codable, Equatable {
    let source: String // "env" (.env on the agent), "app" (set up via this app) or "none"
    let apiKeyMasked: String?
    let publicKey: String?
    let pendingPublicKey: String?
    let mode: String // "revolutx" | "mock"
    let connected: Bool
    let error: String?
    let apiKeysUrl: String

    enum CodingKeys: String, CodingKey {
        case source, mode, connected, error
        case apiKeyMasked = "api_key_masked"
        case publicKey = "public_key"
        case pendingPublicKey = "pending_public_key"
        case apiKeysUrl = "api_keys_url"
    }
}

struct PublicIP: Codable { let ip: String }

/// Response of restoring a backup on the agent.
struct RestoreResult: Decodable {
    let bots: Int
    let trades: Int
    let liveTradingDisabled: Bool
    let credentialsRestored: Bool
    let createdAt: Int64?
    let agentVersion: String?

    enum CodingKeys: String, CodingKey {
        case bots, trades
        case liveTradingDisabled = "live_trading_disabled"
        case credentialsRestored = "credentials_restored"
        case createdAt = "created_at"
        case agentVersion = "agent_version"
    }
}

/// Response of switching the live mode; switching back to paper sells all open live positions.
struct LiveSwitchResult: Decodable {
    struct ClosedPosition: Decodable, Identifiable {
        let botId: Int
        let botName: String
        let ok: Bool
        let message: String
        var id: Int { botId }

        enum CodingKeys: String, CodingKey {
            case ok, message
            case botId = "bot_id"
            case botName = "bot_name"
        }
    }

    let closedPositions: [ClosedPosition]

    enum CodingKeys: String, CodingKey {
        case closedPositions = "closed_positions"
    }
}

/// Global risk limits enforced by the agent engine.
struct Limits: Codable, Equatable {
    var maxOpenPositions: Int
    var maxTotalInvested: Double
    var onePositionPerSymbol: Bool
    var openPositions: Int?
    var invested: Double?

    enum CodingKeys: String, CodingKey {
        case maxOpenPositions = "max_open_positions"
        case maxTotalInvested = "max_total_invested"
        case onePositionPerSymbol = "one_position_per_symbol"
        case openPositions = "open_positions"
        case invested
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(maxOpenPositions, forKey: .maxOpenPositions)
        try c.encode(maxTotalInvested, forKey: .maxTotalInvested)
        try c.encode(onePositionPerSymbol, forKey: .onePositionPerSymbol)
    }
}

struct BotInput: Encodable {
    var name: String
    var strategy: String
    var symbol: String
    var params: [String: JSONValue]
    var enabled: Bool
    var paper: Bool
}

extension Date {
    init(ms: Int64) { self.init(timeIntervalSince1970: TimeInterval(ms) / 1000) }
}
