import Charts
import SwiftUI

// MARK: - Curve

/// One point of a profit curve: the realized result summed up until `date`.
public struct ProfitPoint: Identifiable {
    public let id: String
    public let date: Date
    public let value: Double
    public let trade: Trade? // nil for the points that only stretch the line (start of the range, now)
}

public enum ProfitCurve {
    /// Running sum of the realized results – sales carry the result, buys keep the level. One point per trade, plus
    /// one at the start of the range and one now, so the line spans the whole range. Trades before `start` only set
    /// the starting level; `offset` is added for results of trades that were not loaded.
    public static func points(_ trades: [Trade], key: String = "total", offset: Double = 0, from start: Date? = nil, to end: Date = Date()) -> [ProfitPoint] {
        let sorted = trades.sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
        guard let first = sorted.first else { return [] }
        let origin = start ?? first.date
        var running = offset
        var points: [ProfitPoint] = []
        for trade in sorted {
            if trade.date < origin {
                running += trade.pnl ?? 0
                continue
            }
            if points.isEmpty { points.append(ProfitPoint(id: "\(key)-start", date: origin, value: running, trade: nil)) }
            running += trade.pnl ?? 0
            points.append(ProfitPoint(id: "\(key)-\(trade.id)", date: trade.date, value: running, trade: trade))
        }
        if points.isEmpty { points.append(ProfitPoint(id: "\(key)-start", date: origin, value: running, trade: nil)) }
        points.append(ProfitPoint(id: "\(key)-end", date: max(end, points.last!.date), value: running, trade: nil))
        return points
    }
}

// MARK: - Small curve in the summary card

public struct ProfitSparkline: View {
    let points: [ProfitPoint]
    var open: (() -> Void)?

    public init(points: [ProfitPoint], open: (() -> Void)? = nil) {
        self.points = points
        self.open = open
    }
    /// 0 → 1 when the curve appears: it grows out of the zero line.
    @State private var reveal = 0.0

    public var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("Profit history").font(.ui(10)).foregroundStyle(.secondary)
                Spacer()
                if let open {
                    Button(action: open) {
                        Label("Chart", systemImage: "chart.xyaxis.line")
                            .font(.ui(10.5, weight: .medium))
                            .labelStyle(CompactLabelStyle())
                            .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                    .help("Opens the profit chart with every buy and sale – per bot, each one can be switched on and off.")
                }
            }
            if points.contains(where: { $0.trade?.pnl != nil }) {
                chart
                    .frame(height: 42)
                    .contentShape(Rectangle())
                    .onTapGesture { open?() }
                    .help("Realized result over time, fees already deducted.")
                    .onAppear { withAnimation(.easeOut(duration: 0.9).delay(0.15)) { reveal = 1 } }
            } else {
                Text("The curve starts with the first sale.")
                    .font(.ui(10)).foregroundStyle(.tertiary)
            }
        }
    }

    private var chart: some View {
        let values = points.map(\.value)
        let low = min(values.min() ?? 0, 0)
        let high = max(values.max() ?? 0, 0)
        return Chart {
            RuleMark(y: .value("Result", 0))
                .lineStyle(StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                .foregroundStyle(Color.secondary.opacity(0.5))
            ForEach(points) { point in
                AreaMark(x: .value("Date", point.date), yStart: .value("Result", 0), yEnd: .value("Result", point.value * reveal))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(LinearGradient(colors: [Color.accentColor.opacity(0.25), Color.accentColor.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                LineMark(x: .value("Date", point.date), y: .value("Result", point.value * reveal))
                    .interpolationMethod(.monotone)
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
                    .foregroundStyle(Color.accentColor)
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .chartYScale(domain: low == high ? -1...1 : low...high)
    }
}

public enum HistoryRange: String, CaseIterable, Identifiable {
    case week, month, quarter, year, all
    public var id: String { rawValue }

    public var title: LocalizedStringKey {
        switch self {
        case .week: return "7 days"
        case .month: return "30 days"
        case .quarter: return "90 days"
        case .year: return "1 year"
        case .all: return "All"
        }
    }

    public var start: Date? {
        let days: Int
        switch self {
        case .week: days = 7
        case .month: days = 30
        case .quarter: days = 90
        case .year: days = 365
        case .all: return nil
        }
        return Calendar.current.date(byAdding: .day, value: -days, to: Date())
    }
}

// MARK: - Trade details

/// Which buys a sale closed and which sales a buy ended in. Since agent 1.17 buys and sales name their trade
/// (`positionId`); within it the oldest coins are sold first. Older trades have no such link, so it is rebuilt the way
/// the agent sells: a sale closes one trade with the same quantity (a bot holding several trades sells them one by one)
/// or, if none fits, the oldest coins first (several buys added up to one trade, or only a part sold).
public struct TradeLinks {
    public struct Part {
        public let trade: Trade
        public let qty: Double
    }

    public private(set) var buysOfSale: [Int: [Part]] = [:]
    public private(set) var salesOfBuy: [Int: [Part]] = [:]
    /// Buy id → coins of it not sold yet.
    public private(set) var unsold: [Int: Double] = [:]

    public init(_ trades: [Trade]) {
        let groups = Dictionary(grouping: trades) { trade in
            trade.positionId.map { "\(trade.botId)|\($0)" } ?? "\(trade.botId)|\(trade.symbol)|\(trade.paper)|unlinked"
        }
        for (key, group) in groups {
            link(group, byQuantity: key.hasSuffix("|unlinked"))
        }
    }

    private mutating func link(_ group: [Trade], byQuantity: Bool) {
        var lots: [(trade: Trade, qty: Double)] = []
        for trade in group.sorted(by: { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }) {
            if trade.isBuy {
                lots.append((trade, trade.baseQty))
                continue
            }
            var rest = trade.baseQty
            let tolerance = rest * 0.005
            let cost = trade.quoteAmount - (trade.pnl ?? 0)
            func lotCost(_ i: Int) -> Double { lots[i].trade.quoteAmount * lots[i].qty / lots[i].trade.baseQty }
            let fitting = lots.indices.filter { abs(lots[$0].qty - rest) <= tolerance }
            let single = byQuantity ? fitting.min { abs(lotCost($0) - cost) < abs(lotCost($1) - cost) } : nil
            for i in single.map({ [$0] }) ?? Array(lots.indices) where rest > tolerance {
                let taken = single != nil ? lots[i].qty : min(lots[i].qty, rest)
                buysOfSale[trade.id, default: []].append(Part(trade: lots[i].trade, qty: taken))
                salesOfBuy[lots[i].trade.id, default: []].append(Part(trade: trade, qty: taken))
                lots[i].qty -= taken
                rest -= taken
            }
            lots.removeAll { $0.qty <= $0.trade.baseQty * 0.005 } // only dust left
        }
        for lot in lots { unsold[lot.trade.id] = lot.qty }
    }
}

public struct TradeDetailPanel: View {
    let trade: Trade
    let links: TradeLinks
    let botName: String
    let botColor: Color
    /// Current price of the bot's pair – for coins that are not sold yet.
    let market: Double?
    /// nil: no close button (the panel's trade page has "Back" instead).
    let close: (() -> Void)?
    /// In a card with its own scrolling (next to the chart) – or plain, inside a page that scrolls.
    var framed = true

    public init(trade: Trade, links: TradeLinks, botName: String, botColor: Color, market: Double?, close: (() -> Void)?, framed: Bool = true) {
        self.trade = trade
        self.links = links
        self.botName = botName
        self.botColor = botColor
        self.market = market
        self.close = close
        self.framed = framed
    }

    private var quote: String { trade.quote }

    public var body: some View {
        if framed {
            Card(padding: 14) {
                ScrollView { content }
                    .scrollIndicators(.never)
            }
        } else {
            content
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            if trade.isBuy { buyContent } else { saleContent }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle().fill(botColor).frame(width: 8, height: 8)
                Text(verbatim: botName).font(.ui(12, weight: .semibold)).lineLimit(1)
                Badge(text: trade.paper ? "PAPER" : "LIVE", color: trade.paper ? .paper : .profit)
                Spacer()
                if let close {
                    Button(action: close) {
                        Image(systemName: "xmark")
                            .font(.ui(10, weight: .bold))
                            .frame(width: 22, height: 22)
                            .background(Circle().fill(Color.primary.opacity(0.06)))
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.cancelAction)
                    .help("Close")
                }
            }
            (trade.isBuy ? Text("Buy \(trade.base)") : Text("Sell \(trade.base)"))
                .font(.ui(18, weight: .bold, design: .rounded))
            Text(verbatim: trade.date.formatted(date: .complete, time: .shortened))
                .font(.ui(11)).foregroundStyle(.secondary)
        }
    }

    // MARK: Sale

    @ViewBuilder
    private var saleContent: some View {
        let buys = links.buysOfSale[trade.id] ?? []
        let qty = buys.reduce(0) { $0 + $1.qty }
        if let pnl = trade.pnl {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                PnLText(value: pnl, currency: quote, font: .ui(24, weight: .bold, design: .rounded))
                if let pct = trade.pnlPct {
                    Text(Fmt.pct(pct)).font(.ui(13, weight: .semibold)).monospacedDigit().foregroundStyle(pct.pnlColor)
                }
            }
        }
        section("Sold") {
            row("Time", trade.date.formatted(date: .abbreviated, time: .shortened))
            row("Price", Fmt.price(trade.price, quote))
            row("Quantity", "\(Fmt.qty(trade.baseQty)) \(trade.base)")
            row("Proceeds", Fmt.money(trade.quoteAmount, quote))
            row("Fee", Fmt.money(trade.fee, quote))
            reason(trade)
        }
        section("Bought") {
            if buys.isEmpty {
                note("The matching buy is older than the loaded trades.")
            } else {
                ForEach(buys, id: \.trade.id) { part in linked(part, share: nil) }
            }
        }
        if !buys.isEmpty, qty > 0 {
            let average = buys.reduce(0) { $0 + $1.trade.price * $1.qty } / qty
            let buyFees = buys.reduce(0) { $0 + $1.trade.fee * $1.qty / $1.trade.baseQty }
            let firstBuy = buys.map(\.trade.date).min() ?? trade.date
            section("Summary") {
                row("Held for", Self.duration(trade.date.timeIntervalSince(firstBuy)))
                row(buys.count > 1 ? "Average buy price" : "Buy price", Fmt.price(average, quote))
                row("Price change", Fmt.pct((trade.price / average - 1) * 100), color: (trade.price / average - 1).pnlColor)
                row("Fees (buy + sale)", Fmt.money(buyFees + trade.fee, quote))
            }
        }
    }

    // MARK: Buy

    @ViewBuilder
    private var buyContent: some View {
        let sales = links.salesOfBuy[trade.id] ?? []
        let open = links.unsold[trade.id] ?? 0
        let shares = sales.map { share(of: $0) }
        section("Bought") {
            row("Time", trade.date.formatted(date: .abbreviated, time: .shortened))
            row("Price", Fmt.price(trade.price, quote))
            row("Quantity", "\(Fmt.qty(trade.baseQty)) \(trade.base)")
            row("Amount", Fmt.money(trade.quoteAmount, quote))
            row("Fee", Fmt.money(trade.fee, quote))
            reason(trade)
        }
        section("Sold") {
            if sales.isEmpty {
                note("Not sold yet.")
            } else {
                ForEach(Array(sales.enumerated()), id: \.element.trade.id) { index, part in linked(part, share: shares[index]) }
            }
            if open > 0 {
                row("Still open", "\(Fmt.qty(open)) \(trade.base)")
                if let market {
                    row("Current price", Fmt.price(market, quote))
                    row("Since the buy", Fmt.pct((market / trade.price - 1) * 100), color: (market / trade.price - 1).pnlColor)
                }
            }
        }
        if !sales.isEmpty {
            let lastSale = sales.map(\.trade.date).max() ?? trade.date
            section("Summary") {
                row("Result so far", Fmt.money(shares.reduce(0, +), quote, signed: true), color: shares.reduce(0, +).pnlColor)
                row(open > 0 ? "Held until the last sale" : "Held for", Self.duration(lastSale.timeIntervalSince(trade.date)))
            }
        } else {
            section("Summary") {
                row("Held for", Self.duration(Date().timeIntervalSince(trade.date)))
            }
        }
    }

    /// The part of a sale's result that belongs to this buy.
    private func share(of part: TradeLinks.Part) -> Double {
        guard let pnl = part.trade.pnl, part.trade.baseQty > 0 else { return 0 }
        return pnl * part.qty / part.trade.baseQty
    }

    // MARK: Building blocks

    private func section<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .textCase(.uppercase)
                .font(.ui(10, weight: .semibold))
                .kerning(0.6)
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func row(_ title: LocalizedStringKey, _ value: String, color: Color = .primary) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(verbatim: value).monospacedDigit().foregroundStyle(color).multilineTextAlignment(.trailing)
        }
        .font(.ui(11.5))
    }

    @ViewBuilder
    private func reason(_ trade: Trade) -> some View {
        if !trade.reason.isEmpty {
            Text(verbatim: trade.reason)
                .font(.ui(11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.04)))
        }
    }

    private func note(_ text: LocalizedStringKey) -> some View {
        Text(text).font(.ui(11)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
    }

    /// A linked buy or sale, shown in full – no need to open it.
    private func linked(_ part: TradeLinks.Part, share: Double?) -> some View {
        let other = part.trade
        let partial = abs(part.qty - other.baseQty) > other.baseQty * 0.005
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: other.isBuy ? "arrow.down.left" : "arrow.up.right")
                    .font(.ui(9, weight: .bold))
                    .foregroundStyle(other.isBuy ? Color.profit : .red)
                Text(verbatim: other.date.formatted(date: .abbreviated, time: .shortened))
                    .font(.ui(11.5, weight: .semibold))
                Spacer(minLength: 4)
                if let share {
                    PnLText(value: share, currency: other.quote, font: .ui(11.5, weight: .semibold))
                }
            }
            row("Price", Fmt.price(other.price, other.quote))
            row("Quantity", "\(Fmt.qty(other.baseQty)) \(other.base)")
            if partial {
                row(other.isBuy ? "Of it sold here" : "Of it from this buy", "\(Fmt.qty(part.qty)) \(other.base)")
            }
            row(other.isBuy ? "Amount" : "Proceeds", Fmt.money(other.quoteAmount, other.quote))
            row("Fee", Fmt.money(other.fee, other.quote))
            reason(other)
        }
        .padding(9)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.05)))
    }

    private static func duration(_ seconds: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .full
        formatter.allowedUnits = seconds >= 86_400 ? [.day, .hour] : [.hour, .minute]
        formatter.maximumUnitCount = 2
        return formatter.string(from: max(seconds, 60)) ?? "–"
    }
}

/// Chart symbol for a trade: a buy points up, a sale points down.
public struct TradeSymbol: ChartSymbolShape {
    let isBuy: Bool

    public init(isBuy: Bool) { self.isBuy = isBuy }

    public var perceptualUnitRect: CGRect { CGRect(x: 0, y: 0, width: 1, height: 1) }

    public func path(in rect: CGRect) -> Path {
        var path = Path()
        if isBuy {
            path.move(to: CGPoint(x: rect.midX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        } else {
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        }
        path.closeSubpath()
        return path
    }
}
