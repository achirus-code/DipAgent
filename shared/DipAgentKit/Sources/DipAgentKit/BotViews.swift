import SwiftUI

/// How the bot list is ordered (within "Active" and "Stopped").
public enum BotSort: String, CaseIterable, Identifiable {
    case running, result, name, newest
    public var id: String { rawValue }

    public var title: LocalizedStringKey {
        switch self {
        case .running: return "Running first"
        case .result: return "Result"
        case .name: return "Name"
        case .newest: return "Newest"
        }
    }

    /// Stable: bots that compare equal keep their order from the agent.
    public func apply(_ bots: [Bot]) -> [Bot] {
        let indexed = bots.enumerated().map { ($0.offset, $0.element) }
        let sorted: [(Int, Bot)]
        switch self {
        case .running:
            sorted = indexed.sorted { ($0.1.position == nil ? 1 : 0, $0.0) < ($1.1.position == nil ? 1 : 0, $1.0) }
        case .result:
            sorted = indexed.sorted { ($0.1.totalPnl, -$0.0) > ($1.1.totalPnl, -$1.0) }
        case .name:
            sorted = indexed.sorted { ($0.1.name.localizedCaseInsensitiveCompare($1.1.name), $0.0) < (.orderedSame, $1.0) }
        case .newest:
            sorted = indexed.sorted { ($0.1.createdAt, -$0.0) > ($1.1.createdAt, -$1.0) }
        }
        return sorted.map(\.1)
    }
}

extension ComparisonResult: @retroactive Comparable {
    public static func < (lhs: ComparisonResult, rhs: ComparisonResult) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// "−1.80% to buy" first, then the trigger price, the stop and the current price in small print.
/// Strategies without a fixed trigger show their note (or the price) instead.
public struct GoalLines: View {
    let bot: Bot
    var large = false

    public init(bot: Bot, large: Bool = false) {
        self.bot = bot
        self.large = large
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: large ? 3 : 2) {
            if let goal = bot.goal {
                Text(headline(goal))
                    .font(.ui(large ? 17 : 12, weight: .semibold, design: large ? .rounded : .default))
                    .foregroundStyle(goal.reached ? Color.accentColor : Color.primary)
            } else if let note = bot.targets?.note {
                Text(note).font(.ui(large ? 17 : 12, weight: .medium, design: large ? .rounded : .default))
            } else if let market = bot.market {
                Text(Fmt.price(market.price, bot.quoteCurrency)).font(.ui(12, weight: .medium))
            }
            if let details {
                // up to two lines: with open trades both buy conditions are listed
                Text(verbatim: details)
                    .font(.ui(large ? 11 : 10)).foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .monospacedDigit()
        .lineLimit(1)
    }

    private func headline(_ goal: BotGoal) -> String {
        let pct = Fmt.pct(goal.percent)
        switch (goal.kind, goal.reached) {
        case (.buy, false) where !bot.openTrades.isEmpty: return String(localized: "\(pct) to the next trade")
        case (.buy, false): return String(localized: "\(pct) to buy")
        case (.buy, true): return String(localized: "Buy price reached")
        case (.sell, false): return String(localized: "\(pct) to sell")
        case (.sell, true): return String(localized: "Sell price reached")
        case (.trailingStart, false): return String(localized: "\(pct) until trailing starts")
        case (.trailingStart, true): return String(localized: "Trailing starts")
        case (.trailingStop, false): return String(localized: "\(pct) to the trailing stop")
        case (.trailingStop, true): return String(localized: "Trailing stop reached")
        }
    }

    /// Trigger price, stop and current price; the 24 h change only while the line has room for it.
    private var details: String? {
        guard let market = bot.market else { return nil }
        let q = bot.quoteCurrency
        var parts: [String] = []
        if let goal = bot.goal {
            switch goal.kind {
            case .buy:
                if let signal = bot.targets?.signalPrice, let spacing = bot.targets?.spacingPrice {
                    // both must be reached – show each with its distance, so it is clear which one holds the buy back
                    func distance(_ price: Double) -> String {
                        market.price <= price ? String(localized: "already reached") : Fmt.pct((price / market.price - 1) * 100)
                    }
                    parts.append(String(localized: "Buy threshold ≤ \(Fmt.price(signal, q)) (\(distance(signal)))"))
                    parts.append(String(localized: "Distance to open trades ≤ \(Fmt.price(spacing, q)) (\(distance(spacing)))"))
                } else {
                    parts.append(String(localized: "Buy at ≤ \(Fmt.price(goal.target, q))"))
                }
            case .sell: parts.append(String(localized: "Sell at ≥ \(Fmt.price(goal.target, q))"))
            case .trailingStart: parts.append(String(localized: "Trailing from \(Fmt.price(goal.target, q))"))
            case .trailingStop: parts.append(String(localized: "Trailing stop \(Fmt.price(goal.target, q))"))
            }
        }
        if bot.position != nil, let stop = bot.targets?.stopPrice {
            parts.append(String(localized: "Stop \(Fmt.price(stop, q))"))
        }
        if !parts.isEmpty || bot.targets?.note != nil {
            parts.append(String(localized: "Price \(Fmt.price(market.price, q))"))
        }
        if parts.count < 3 {
            parts.append(String(localized: "\(Fmt.pct(market.change24h)) 24h"))
        }
        return parts.joined(separator: " · ")
    }
}

public struct StatusLine: View {
    let bot: Bot

    public init(bot: Bot) { self.bot = bot }
    @State private var pulse = false

    public var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
                .opacity(bot.enabled && pulse ? 0.35 : 1)
                .padding(.top, 4)
                .animation(bot.enabled ? .easeInOut(duration: 1).repeatForever() : .default, value: pulse)
                .onAppear { pulse = true }
            VStack(alignment: .leading, spacing: 3) {
                Text(statusText)
                    .font(.ui(10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if bot.enabled, let hint = bot.hint {
                    Label(hint, systemImage: "exclamationmark.triangle.fill")
                        .font(.ui(10.5, weight: .medium))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var statusText: String {
        guard bot.enabled else { return String(localized: "Stopped") }
        return bot.status.isEmpty ? String(localized: "Waiting for the first check …") : bot.status
    }

    private var color: Color {
        if !bot.enabled { return .gray }
        if bot.statusError == true { return .red }
        if bot.pendingOrder { return .yellow }
        return .green
    }
}

public struct PositionStrip: View {
    let bot: Bot
    let position: BotPosition

    public init(bot: Bot, position: BotPosition) {
        self.bot = bot
        self.position = position
    }

    public var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                (position.paper == false ? Text("Open live position") : Text("Open position"))
                    .font(.ui(9.5, weight: .semibold))
                    .foregroundStyle(position.paper == false ? Color.red : .secondary)
                // how big the position is: its current value and what went in
                Text("Value \(Fmt.money(position.value, bot.quoteCurrency)) · invested \(Fmt.money(position.cost, bot.quoteCurrency))")
                    .font(.ui(10.5, weight: .medium)).monospacedDigit()
                Text("\(Fmt.qty(position.qty)) \(bot.baseCurrency) · entry \(Fmt.price(position.entryPrice, bot.quoteCurrency))")
                    .font(.ui(9.5)).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                PnLText(value: position.unrealizedPnl, currency: bot.quoteCurrency, font: .ui(11, weight: .semibold))
                Text(Fmt.pct(position.unrealizedPct))
                    .font(.ui(9.5, weight: .medium))
                    .foregroundStyle(position.unrealizedPct.pnlColor)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.accentColor.opacity(0.08)))
    }
}

/// Several open trades on the card: the count and their result, then one line per trade.
public struct TradesStrip: View {
    let bot: Bot

    public init(bot: Bot) { self.bot = bot }

    public var body: some View {
        let trades = bot.openTrades
        let live = trades.contains { $0.paper == false }
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                (live ? Text("Open live trades \(String(trades.count))/\(String(bot.maxTrades ?? trades.count))")
                      : Text("Open trades \(String(trades.count))/\(String(bot.maxTrades ?? trades.count))"))
                    .font(.ui(9.5, weight: .semibold))
                    .foregroundStyle(live ? Color.red : .secondary)
                Spacer()
                PnLText(value: trades.reduce(0) { $0 + $1.unrealizedPnl }, currency: bot.quoteCurrency,
                        font: .ui(11, weight: .semibold))
            }
            ForEach(Array(trades.enumerated()), id: \.offset) { index, trade in
                OpenTradeRow(bot: bot, trade: trade, number: index + 1)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.accentColor.opacity(0.08)))
    }
}

/// "1  Value 251.20 € · +1.20 %      Target 2,460 €"
public struct OpenTradeRow: View {
    let bot: Bot
    let trade: BotPosition
    let number: Int

    public init(bot: Bot, trade: BotPosition, number: Int) {
        self.bot = bot
        self.trade = trade
        self.number = number
    }

    public var body: some View {
        HStack(spacing: 6) {
            Text(verbatim: "\(number)")
                .font(.ui(9, weight: .bold)).foregroundStyle(.secondary)
                .frame(width: 14, height: 14)
                .background(Circle().fill(Color.primary.opacity(0.08)))
            Text("Value \(Fmt.money(trade.value, bot.quoteCurrency))")
                .font(.ui(10.5, weight: .medium))
            Text(Fmt.pct(trade.unrealizedPct))
                .font(.ui(10, weight: .medium)).foregroundStyle(trade.unrealizedPct.pnlColor)
            Spacer(minLength: 4)
            if let line = Self.targetText(trade, bot: bot) {
                Text(verbatim: line).font(.ui(10)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .monospacedDigit()
    }

    /// The trade's own goal: its sale price, else its stop, else the strategy's note.
    public static func targetText(_ trade: BotPosition, bot: Bot) -> String? {
        let q = bot.quoteCurrency
        if let sell = trade.sellPrice, let price = bot.market?.price, price > 0 {
            let label = bot.strategy == "trailing" && sell < price
                ? String(localized: "Trailing stop \(Fmt.price(sell, q))")
                : String(localized: "Target \(Fmt.price(sell, q))")
            return "\(label) (\(Fmt.pct((sell / price - 1) * 100)))"
        }
        if let stop = trade.stopPrice { return String(localized: "Stop \(Fmt.price(stop, q))") }
        return trade.note
    }
}

/// One of Claude's answers: action badge, confidence bar, reason, price and time.
public struct DecisionRow: View {
    let decision: AiDecision
    let currency: String

    public init(decision: AiDecision, currency: String) {
        self.decision = decision
        self.currency = currency
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Badge(text: actionText, color: actionColor, icon: actionIcon)
                ConfidenceBar(value: decision.confidence, color: actionColor)
                Text(verbatim: "\(decision.confidence) %")
                    .font(.ui(10.5, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(actionColor)
                Spacer()
                Text(Date(ms: decision.createdAt).formatted(date: .abbreviated, time: .shortened))
                    .font(.ui(9.5)).foregroundStyle(.tertiary)
            }
            Text(decision.reason)
                .font(.ui(10.5))
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Text(Fmt.price(decision.price, currency)).monospacedDigit()
                if let profit = decision.profitPct {
                    Text(verbatim: "·")
                    Text(Fmt.pct(profit)).foregroundStyle(profit.pnlColor).monospacedDigit()
                }
            }
            .font(.ui(9.5)).foregroundStyle(.secondary)
        }
    }

    private var actionText: LocalizedStringKey {
        switch decision.action {
        case "buy": return "BUY"
        case "sell": return "SELL"
        case "hold": return "HOLD"
        default: return "WAIT"
        }
    }

    private var actionColor: Color {
        switch decision.action {
        case "buy": return .green
        case "sell": return .orange
        case "hold": return .blue
        default: return .gray
        }
    }

    private var actionIcon: String {
        switch decision.action {
        case "buy": return "arrow.down.circle.fill"
        case "sell": return "arrow.up.circle.fill"
        case "hold": return "hand.raised.fill"
        default: return "clock.fill"
        }
    }
}

/// 0–100 as a thin bar – the "score" of a decision.
public struct ConfidenceBar: View {
    let value: Int
    let color: Color

    public init(value: Int, color: Color) {
        self.value = value
        self.color = color
    }

    public var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule().fill(color.opacity(0.8)).frame(width: geo.size.width * CGFloat(max(0, min(value, 100))) / 100)
            }
        }
        .frame(width: 60, height: 5)
    }
}
