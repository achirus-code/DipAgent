import SwiftUI

/// Everything the profit chart shows, computed from the trade history and the chosen filters – the same numbers
/// on the Mac (window) and the iPhone (page).
public struct ProfitHistoryData {
    public struct Curve: Identifiable {
        public let id: Int // bot id, -1 = all shown bots together
        public let color: Color
        public let points: [ProfitPoint]
    }

    public struct BotStats: Identifiable {
        public let id: Int
        public let name: String
        public let deleted: Bool
        public let buys: Int
        public let sells: Int
        public let wins: Int
        public let volume: Double
        public let pnl: Double
        public let fees: Double
        public let last: Date?
    }

    public typealias Marker = (curve: Curve, point: ProfitPoint)

    public static let palette: [Color] = [.blue, .orange, .green, .purple, .pink, .teal, .yellow, .red, .indigo, .mint, .brown, .cyan]

    public let trades: [Trade]
    public let bots: [Bot]
    public let live: Bool
    public let currency: String
    public let range: HistoryRange
    public let perBot: Bool
    public let hidden: Set<Int>
    /// The currencies in the order of the agent's summary.
    let currencyOrder: [String]

    public init(trades: [Trade], bots: [Bot], summary: Summary?, live: Bool, currency: String, range: HistoryRange,
                perBot: Bool, hidden: Set<Int>) {
        self.trades = trades
        self.bots = bots
        self.live = live
        self.currency = currency
        self.range = range
        self.perBot = perBot
        self.hidden = hidden
        currencyOrder = summary?.currencies.map(\.currency) ?? []
    }

    public var modeTrades: [Trade] { trades.filter { $0.paper != live } }

    public var currencies: [String] {
        let order = currencyOrder
        return Set(modeTrades.map(\.quote)).sorted { (order.firstIndex(of: $0) ?? .max, $0) < (order.firstIndex(of: $1) ?? .max, $1) }
    }

    /// The trades of the chosen mode and currency, over the whole history.
    public var scoped: [Trade] { modeTrades.filter { $0.quote == currency } }

    /// Every bot that ever traded, in a fixed order – so a bot keeps its color when the mode or range changes.
    public var allBotIds: [Int] {
        var seen: [Int] = []
        for trade in trades.sorted(by: { $0.createdAt < $1.createdAt }) where !seen.contains(trade.botId) {
            seen.append(trade.botId)
        }
        return seen
    }

    public var botIds: [Int] {
        let ids = Set(scoped.map(\.botId))
        return allBotIds.filter { ids.contains($0) }
    }

    public func color(_ botId: Int) -> Color {
        Self.palette[(allBotIds.firstIndex(of: botId) ?? 0) % Self.palette.count]
    }

    public func name(_ botId: Int) -> String {
        bots.first { $0.id == botId }?.name
            ?? trades.filter { $0.botId == botId }.max { $0.createdAt < $1.createdAt }?.botName
            ?? "#\(botId)"
    }

    public var shown: [Trade] { scoped.filter { !hidden.contains($0.botId) } }

    public var curves: [Curve] {
        let start = range.start
        if perBot {
            return botIds.filter { !hidden.contains($0) }.map { id in
                Curve(id: id, color: color(id), points: ProfitCurve.points(scoped.filter { $0.botId == id }, key: String(id), from: start))
            }
        }
        let points = ProfitCurve.points(shown, from: start)
        return points.isEmpty ? [] : [Curve(id: -1, color: .accentColor, points: points)]
    }

    public var inRange: [Trade] {
        guard let start = range.start else { return scoped }
        return scoped.filter { $0.date >= start }
    }

    public var stats: [BotStats] {
        botIds.map { id in
            let own = inRange.filter { $0.botId == id }
            let sales = own.compactMap(\.pnl)
            return BotStats(
                id: id, name: name(id), deleted: bots.isEmpty == false && !bots.contains { $0.id == id },
                buys: own.filter(\.isBuy).count, sells: sales.count, wins: sales.filter { $0 > 0 }.count,
                volume: own.reduce(0) { $0 + $1.quoteAmount }, pnl: sales.reduce(0, +),
                fees: own.reduce(0) { $0 + $1.fee }, last: own.map(\.date).max()
            )
        }
    }

    /// Every buy and sale on the shown curves.
    public var markers: [Marker] {
        curves.flatMap { curve in curve.points.filter { $0.trade != nil }.map { (curve, $0) } }
    }

    /// Buys and sales linked to each other – over the whole history, not just the shown range.
    public var links: TradeLinks { TradeLinks(scoped) }

    /// The trade shown in the details and the trades it belongs to – emphasized in the chart.
    public func related(to detail: Trade?, links: TradeLinks) -> Set<Int> {
        guard let detail else { return [] }
        let parts = detail.isBuy ? links.salesOfBuy[detail.id] : links.buysOfSale[detail.id]
        return Set([detail.id] + (parts ?? []).map(\.trade.id))
    }

    /// The values of the shown curves plus the zero line, with a little air above and below.
    public var yDomain: ClosedRange<Double> {
        let values: [Double] = curves.flatMap { curve in curve.points.map(\.value) } + [0]
        let low = values.min() ?? 0, high = values.max() ?? 0
        let pad = max((high - low) * 0.08, 1)
        return (low - pad)...(high + pad)
    }

    public var xDomain: ClosedRange<Date> {
        let now = Date()
        let lower = range.start ?? scoped.map(\.date).min() ?? now
        return min(lower, now.addingTimeInterval(-3600))...now
    }

    /// Totals of the shown bots in the period – the tiles above the chart.
    public var totals: (pnl: Double, volume: Double, buys: Int, sells: Int, wins: Int, fees: Double) {
        let shownStats = stats.filter { !hidden.contains($0.id) }
        return (
            shownStats.reduce(0) { $0 + $1.pnl }, shownStats.reduce(0) { $0 + $1.volume },
            shownStats.reduce(0) { $0 + $1.buys }, shownStats.reduce(0) { $0 + $1.sells },
            shownStats.reduce(0) { $0 + $1.wins }, shownStats.reduce(0) { $0 + $1.fees }
        )
    }
}
