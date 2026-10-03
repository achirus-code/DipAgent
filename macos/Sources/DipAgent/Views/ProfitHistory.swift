import AppKit
import Charts
import SwiftUI

// MARK: - Curve

/// One point of a profit curve: the realized result summed up until `date`.
struct ProfitPoint: Identifiable {
    let id: String
    let date: Date
    let value: Double
    let trade: Trade? // nil for the points that only stretch the line (start of the range, now)
}

enum ProfitCurve {
    /// Running sum of the realized results – sales carry the result, buys keep the level. One point per trade, plus
    /// one at the start of the range and one now, so the line spans the whole range. Trades before `start` only set
    /// the starting level; `offset` is added for results of trades that were not loaded.
    static func points(_ trades: [Trade], key: String = "total", offset: Double = 0, from start: Date? = nil, to end: Date = Date()) -> [ProfitPoint] {
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

struct ProfitSparkline: View {
    let points: [ProfitPoint]
    var open: (() -> Void)?
    /// 0 → 1 when the curve appears: it grows out of the zero line.
    @State private var reveal = 0.0

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("Profit history").font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                if let open {
                    Button(action: open) {
                        Label("Chart", systemImage: "chart.xyaxis.line")
                            .font(.system(size: 10.5, weight: .medium))
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
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
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

// MARK: - Window

/// The profit chart in a window of its own – there is no room for it in the menu bar panel.
@MainActor
enum ProfitWindow {
    private static var window: NSWindow?

    static func show(store: AppStore) {
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1140, height: 720),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered, defer: false
            )
            window.title = String(localized: "Profit history")
            window.contentMinSize = NSSize(width: 900, height: 560)
            window.isReleasedWhenClosed = false
            let host = NSHostingView(rootView: ProfitHistoryView().environment(store))
            host.sizingOptions = [] // the window decides the size
            window.contentView = host
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

enum HistoryRange: String, CaseIterable, Identifiable {
    case week, month, quarter, year, all
    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .week: return "7 days"
        case .month: return "30 days"
        case .quarter: return "90 days"
        case .year: return "1 year"
        case .all: return "All"
        }
    }

    var start: Date? {
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

struct ProfitHistoryView: View {
    @Environment(AppStore.self) private var store
    /// The whole history as far as the agent hands it out; until it is loaded the trades of the panel are shown.
    @State private var history: [Trade]?
    @State private var loading = false
    @State private var live = false
    @State private var currency = "EUR"
    @State private var range: HistoryRange = .month
    @State private var perBot = true
    @State private var hidden: Set<Int> = []
    @State private var hoveredId: String?
    /// 0 → 1 when the curves (re)appear: they grow out of the zero line.
    @State private var reveal = 0.0
    /// The trade whose details are shown next to the chart.
    @State private var detail: Trade?

    private static let historyLimit = 1000
    private static let palette: [Color] = [.blue, .orange, .green, .purple, .pink, .teal, .yellow, .red, .indigo, .mint, .brown, .cyan]

    private struct Curve: Identifiable {
        let id: Int // bot id, -1 = all shown bots together
        let color: Color
        let points: [ProfitPoint]
    }

    private struct BotStats: Identifiable {
        let id: Int
        let name: String
        let deleted: Bool
        let buys: Int
        let sells: Int
        let wins: Int
        let volume: Double
        let pnl: Double
        let fees: Double
        let last: Date?
    }

    // MARK: Data

    private var trades: [Trade] { history ?? store.trades }
    private var modeTrades: [Trade] { trades.filter { $0.paper != live } }

    private var currencies: [String] {
        let order = store.summary?.currencies.map(\.currency) ?? []
        return Set(modeTrades.map(\.quote)).sorted { (order.firstIndex(of: $0) ?? .max, $0) < (order.firstIndex(of: $1) ?? .max, $1) }
    }

    /// The trades of the chosen mode and currency, over the whole history.
    private var scoped: [Trade] { modeTrades.filter { $0.quote == currency } }

    /// Every bot that ever traded, in a fixed order – so a bot keeps its color when the mode or range changes.
    private var allBotIds: [Int] {
        var seen: [Int] = []
        for trade in trades.sorted(by: { $0.createdAt < $1.createdAt }) where !seen.contains(trade.botId) {
            seen.append(trade.botId)
        }
        return seen
    }

    private var botIds: [Int] {
        let ids = Set(scoped.map(\.botId))
        return allBotIds.filter { ids.contains($0) }
    }

    private func color(_ botId: Int) -> Color {
        Self.palette[(allBotIds.firstIndex(of: botId) ?? 0) % Self.palette.count]
    }

    private func name(_ botId: Int) -> String {
        store.bots.first { $0.id == botId }?.name
            ?? trades.filter { $0.botId == botId }.max { $0.createdAt < $1.createdAt }?.botName
            ?? "#\(botId)"
    }

    private var shown: [Trade] { scoped.filter { !hidden.contains($0.botId) } }

    private var curves: [Curve] {
        let start = range.start
        if perBot {
            return botIds.filter { !hidden.contains($0) }.map { id in
                Curve(id: id, color: color(id), points: ProfitCurve.points(scoped.filter { $0.botId == id }, key: String(id), from: start))
            }
        }
        let points = ProfitCurve.points(shown, from: start)
        return points.isEmpty ? [] : [Curve(id: -1, color: .accentColor, points: points)]
    }

    private var inRange: [Trade] {
        guard let start = range.start else { return scoped }
        return scoped.filter { $0.date >= start }
    }

    private var stats: [BotStats] {
        botIds.map { id in
            let own = inRange.filter { $0.botId == id }
            let sales = own.compactMap(\.pnl)
            return BotStats(
                id: id, name: name(id), deleted: store.bots.isEmpty == false && !store.bots.contains { $0.id == id },
                buys: own.filter(\.isBuy).count, sells: sales.count, wins: sales.filter { $0 > 0 }.count,
                volume: own.reduce(0) { $0 + $1.quoteAmount }, pnl: sales.reduce(0, +),
                fees: own.reduce(0) { $0 + $1.fee }, last: own.map(\.date).max()
            )
        }
    }

    // MARK: Layout

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            controls
            if scoped.isEmpty {
                Spacer()
                EmptyStateView(icon: "chart.xyaxis.line", title: "No trades yet", message: "As soon as a bot buys or sells, its curve shows up here.")
                Spacer()
            } else {
                HStack(alignment: .top, spacing: 14) {
                    VStack(alignment: .leading, spacing: 14) {
                        tiles
                        chart
                            .frame(minHeight: 260, maxHeight: .infinity)
                        legend
                        botTable
                    }
                    if let detail {
                        TradeDetailPanel(
                            trade: detail, links: links, botName: name(detail.botId), botColor: color(detail.botId),
                            market: store.bots.first { $0.id == detail.botId && $0.symbol == detail.symbol }?.market?.price,
                            close: { self.detail = nil }
                        )
                        .frame(width: 320)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
                .animation(.snappy(duration: 0.25), value: detail == nil)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task(id: store.trades.first?.id) { await load() }
        .onAppear {
            live = store.summary?.mode == "live"
            currency = store.summary?.currencies.first?.currency ?? currencies.first ?? currency
            replay()
        }
        .onChange(of: perBot) { replay() }
        .onChange(of: currencies) { _, available in
            if !available.contains(currency), let first = available.first { currency = first }
        }
        .onChange(of: live) { detail = nil; replay() }
        .onChange(of: currency) { detail = nil; replay() }
    }

    /// Lets the curves grow out of the zero line again – when the window opens or other data is shown.
    private func replay() {
        reveal = 0
        DispatchQueue.main.async {
            withAnimation(.spring(duration: 0.9, bounce: 0.15)) { reveal = 1 }
        }
    }

    private func load() async {
        loading = true
        if let all = await store.allTrades(limit: Self.historyLimit) { history = all }
        loading = false
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Picker("Mode", selection: $live) {
                Text("Paper").tag(false)
                Text("Live").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Paper and live results are kept apart.")
            if currencies.count > 1 {
                Picker("Currency", selection: $currency) {
                    ForEach(currencies, id: \.self) { Text(verbatim: $0).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }
            Spacer()
            Picker("Period", selection: $range) {
                ForEach(HistoryRange.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Picker("View", selection: $perBot) {
                Text("Per bot").tag(true)
                Text("Combined").tag(false)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("One line per bot, or the shown bots added up to one line.")
            Button {
                Task { await load() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .disabled(loading)
            .help("Refresh")
        }
        .controlSize(.small)
    }

    private var tiles: some View {
        let shownStats = stats.filter { !hidden.contains($0.id) }
        let pnl = shownStats.reduce(0) { $0 + $1.pnl }
        let sells = shownStats.reduce(0) { $0 + $1.sells }
        let wins = shownStats.reduce(0) { $0 + $1.wins }
        return HStack(alignment: .top, spacing: 10) {
            tile("Profit/loss", help: "Realized result of the shown bots in this period, fees already deducted.") {
                PnLText(value: pnl, currency: currency, font: .system(size: 20, weight: .bold, design: .rounded))
            }
            tile("Volume", help: "Value of all buys and sales of the shown bots in this period.") {
                tileText(Fmt.money(shownStats.reduce(0) { $0 + $1.volume }, currency))
            }
            tile("Trades", help: nil) {
                VStack(alignment: .leading, spacing: 1) {
                    tileText(String(shownStats.reduce(0) { $0 + $1.buys + $1.sells }))
                    Text("\(String(shownStats.reduce(0) { $0 + $1.buys })) buys · \(String(sells)) sales")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            tile("Win rate", help: "Share of the sales that ended with a profit.") {
                tileText(sells > 0 ? Fmt.rate(Double(wins) / Double(sells) * 100) : "–")
            }
            tile("Fees", help: "Exchange fees – already included in the result.") {
                tileText(Fmt.money(shownStats.reduce(0) { $0 + $1.fees }, currency))
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .animation(.snappy(duration: 0.4), value: pnl)
        .animation(.snappy(duration: 0.4), value: sells)
    }

    private func tile<Content: View>(_ title: LocalizedStringKey, help: LocalizedStringKey?, @ViewBuilder value: () -> Content) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 10.5)).foregroundStyle(.secondary)
                value()
            }
            .frame(maxHeight: .infinity, alignment: .topLeading)
        }
        .help(help.map { Text($0) } ?? Text(verbatim: ""))
    }

    private func tileText(_ text: String) -> some View {
        Text(verbatim: text).font(.system(size: 20, weight: .bold, design: .rounded)).monospacedDigit()
            .contentTransition(.numericText())
    }

    // MARK: Chart

    private var markers: [(curve: Curve, point: ProfitPoint)] {
        curves.flatMap { curve in curve.points.filter { $0.trade != nil }.map { (curve, $0) } }
    }

    /// The trade under the mouse.
    private var selected: (curve: Curve, point: ProfitPoint)? {
        guard let hoveredId else { return nil }
        return markers.first { $0.point.id == hoveredId }
    }

    /// Buys and sales linked to each other – over the whole history, not just the shown range.
    private var links: TradeLinks { TradeLinks(scoped) }

    /// The trade shown in the details and the trades it belongs to – emphasized in the chart.
    private var related: Set<Int> {
        guard let detail else { return [] }
        let links = links
        let parts = detail.isBuy ? links.salesOfBuy[detail.id] : links.buysOfSale[detail.id]
        return Set([detail.id] + (parts ?? []).map(\.trade.id))
    }

    /// The marker closest to `location` (within reach of the pointer), in the coordinates of the chart overlay.
    private func nearestMarker(_ location: CGPoint, _ proxy: ChartProxy, _ geo: GeometryProxy) -> (curve: Curve, point: ProfitPoint)? {
        guard let plotFrame = proxy.plotFrame else { return nil }
        let origin = geo[plotFrame].origin
        var best: (marker: (curve: Curve, point: ProfitPoint), distance: CGFloat)?
        for marker in markers {
            guard let x = proxy.position(forX: marker.point.date), let y = proxy.position(forY: marker.point.value) else { continue }
            let distance = hypot(origin.x + x - location.x, origin.y + y - location.y)
            if distance < 24, distance < best?.distance ?? .infinity { best = (marker, distance) }
        }
        return best?.marker
    }

    /// The values of the shown curves plus the zero line, with a little air above and below.
    private var yDomain: ClosedRange<Double> {
        let values: [Double] = curves.flatMap { curve in curve.points.map(\.value) } + [0]
        let low = values.min() ?? 0, high = values.max() ?? 0
        let pad = max((high - low) * 0.08, 1)
        return (low - pad)...(high + pad)
    }

    private var xDomain: ClosedRange<Date> {
        let now = Date()
        let lower = range.start ?? scoped.map(\.date).min() ?? now
        return min(lower, now.addingTimeInterval(-3600))...now
    }

    private var chart: some View {
        Chart {
            RuleMark(y: .value("Result", 0))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 4]))
                .foregroundStyle(Color.secondary.opacity(0.6))
            ForEach(curves) { curve in
                ForEach(curve.points) { point in
                    LineMark(x: .value("Date", point.date), y: .value("Result", point.value * reveal), series: .value("Bot", curve.id))
                        .interpolationMethod(.monotone)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                        .foregroundStyle(curve.color)
                }
            }
            let related = related
            ForEach(markers, id: \.point.id) { marker in
                let emphasized = marker.point.trade.map { related.contains($0.id) } ?? false
                PointMark(x: .value("Date", marker.point.date), y: .value("Result", marker.point.value * reveal))
                    .symbol(TradeSymbol(isBuy: marker.point.trade?.isBuy == true))
                    .symbolSize(emphasized ? 120 : perBot ? 36 : 44)
                    .foregroundStyle(markerColor(marker))
                    .opacity((related.isEmpty || emphasized ? 1 : 0.3) * reveal)
            }
            if let selected, let trade = selected.point.trade {
                RuleMark(x: .value("Date", selected.point.date))
                    .foregroundStyle(Color.secondary.opacity(0.35))
                PointMark(x: .value("Date", selected.point.date), y: .value("Result", selected.point.value * reveal))
                    .symbol(TradeSymbol(isBuy: trade.isBuy))
                    .symbolSize(140)
                    .foregroundStyle(markerColor(selected))
                    .annotation(position: .top, spacing: 8, overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                        tooltip(trade, total: selected.point.value)
                            .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: .bottom)))
                    }
            }
        }
        .chartXScale(domain: xDomain)
        .chartYScale(domain: yDomain) // fixed, so the curves grow instead of the axis rescaling with them
        .animation(.smooth(duration: 0.5), value: range)
        .animation(.smooth(duration: 0.4), value: hidden)
        .animation(.spring(duration: 0.35, bounce: 0.3), value: related)
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let amount = value.as(Double.self) { Text(verbatim: Fmt.money(amount, currency)) }
                }
            }
        }
        .chartLegend(.hidden)
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        var hit: String?
                        if case .active(let location) = phase { hit = nearestMarker(location, proxy, geo)?.point.id }
                        (hit == nil ? NSCursor.arrow : NSCursor.pointingHand).set()
                        if hit != hoveredId {
                            withAnimation(.easeOut(duration: 0.15)) { hoveredId = hit }
                        }
                    }
                    .onTapGesture { location in
                        // a click next to the markers closes the details
                        detail = nearestMarker(location, proxy, geo)?.point.trade
                    }
            }
        }
    }

    /// Buys green, sales red.
    private func markerColor(_ marker: (curve: Curve, point: ProfitPoint)) -> Color {
        marker.point.trade?.isBuy == false ? .red : .profit // the same in every view – they stand out on every line
    }

    private func tooltip(_ trade: Trade, total: Double) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Circle().fill(color(trade.botId)).frame(width: 7, height: 7)
                Text(verbatim: name(trade.botId)).font(.system(size: 11.5, weight: .semibold))
            }
            (trade.isBuy ? Text("Buy \(trade.base)") : Text("Sell \(trade.base)"))
                .font(.system(size: 11, weight: .medium))
            Text(verbatim: "\(Fmt.qty(trade.baseQty)) @ \(Fmt.price(trade.price, trade.quote)) = \(Fmt.money(trade.quoteAmount, trade.quote))")
                .font(.system(size: 10.5)).monospacedDigit().foregroundStyle(.secondary)
            if let pnl = trade.pnl {
                HStack(spacing: 4) {
                    Text("Result").font(.system(size: 10.5)).foregroundStyle(.secondary)
                    PnLText(value: pnl, currency: trade.quote, font: .system(size: 10.5, weight: .semibold))
                    if let pct = trade.pnlPct {
                        Text(Fmt.pct(pct)).font(.system(size: 10.5)).monospacedDigit().foregroundStyle(pct.pnlColor)
                    }
                }
            }
            HStack(spacing: 4) {
                Text(perBot ? "Bot total" : "Total").font(.system(size: 10.5)).foregroundStyle(.secondary)
                PnLText(value: total, currency: trade.quote, font: .system(size: 10.5, weight: .semibold))
            }
            Text(verbatim: trade.date.formatted(date: .abbreviated, time: .shortened))
                .font(.system(size: 10)).foregroundStyle(.tertiary)
            if detail?.id != trade.id {
                Text("Click for details").font(.system(size: 10)).foregroundStyle(Color.accentColor)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.background).shadow(color: .black.opacity(0.15), radius: 4, y: 1))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
    }

    private var legend: some View {
        HStack(spacing: 14) {
            HStack(spacing: 4) {
                Image(systemName: "triangle.fill").font(.system(size: 8)).foregroundStyle(Color.profit)
                Text("Buy")
            }
            HStack(spacing: 4) {
                Image(systemName: "triangle.fill").rotationEffect(.degrees(180)).font(.system(size: 8)).foregroundStyle(.red)
                Text("Sale")
            }
            Text("The line shows the realized result, fees deducted – it moves with every sale.")
                .foregroundStyle(.tertiary)
            Spacer()
            if trades.count >= Self.historyLimit {
                Text("Latest \(String(Self.historyLimit)) trades").foregroundStyle(.tertiary)
            }
        }
        .font(.system(size: 10.5))
        .foregroundStyle(.secondary)
    }

    // MARK: Bots

    private var botTable: some View {
        Card(padding: 8) {
            ScrollView {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 0) {
                    GridRow {
                        HStack(spacing: 8) {
                            Text("Bot")
                            Button(hidden.isEmpty ? "Hide all" : "Show all") {
                                withAnimation(.smooth(duration: 0.4)) { hidden = hidden.isEmpty ? Set(botIds) : [] }
                            }
                            .buttonStyle(.link)
                            .font(.system(size: 10.5))
                        }
                        Text("Trades").gridColumnAlignment(.trailing)
                        Text("Volume").gridColumnAlignment(.trailing)
                        Text("Profit/loss").gridColumnAlignment(.trailing)
                        Text("Fees").gridColumnAlignment(.trailing)
                        Text("Last trade").gridColumnAlignment(.trailing)
                    }
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 5)
                    Divider().gridCellUnsizedAxes(.horizontal).opacity(0.5)
                    ForEach(stats) { row in
                        botRow(row)
                    }
                }
                .padding(.horizontal, 6)
            }
            .frame(maxHeight: 220)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func botRow(_ row: BotStats) -> some View {
        let isShown = !hidden.contains(row.id)
        return GridRow {
            HStack(spacing: 8) {
                Image(systemName: isShown ? "checkmark.square.fill" : "square")
                    .font(.system(size: 13))
                    .foregroundStyle(isShown ? color(row.id) : Color.secondary)
                Text(verbatim: row.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                if row.deleted {
                    Text("Deleted").font(.system(size: 10)).foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(verbatim: "\(row.buys) / \(row.sells)")
                .help("Buys / sales in this period")
            Text(verbatim: Fmt.money(row.volume, currency))
            PnLText(value: row.pnl, currency: currency, font: .system(size: 12, weight: .semibold))
            Text(verbatim: Fmt.money(row.fees, currency)).foregroundStyle(.secondary)
            Text(verbatim: row.last?.formatted(date: .abbreviated, time: .shortened) ?? "–").foregroundStyle(.secondary)
        }
        .font(.system(size: 12))
        .monospacedDigit()
        .padding(.vertical, 6)
        .opacity(isShown ? 1 : 0.5)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.smooth(duration: 0.4)) {
                if isShown { hidden.insert(row.id) } else { hidden.remove(row.id) }
            }
        }
        .help(isShown ? "Click to hide this bot in the chart" : "Click to show this bot in the chart")
    }
}

// MARK: - Trade details

/// Which buys a sale closed and which sales a buy ended in. Since agent 1.17 buys and sales name their trade
/// (`positionId`); within it the oldest coins are sold first. Older trades have no such link, so it is rebuilt the way
/// the agent sells: a sale closes one trade with the same quantity (a bot holding several trades sells them one by one)
/// or, if none fits, the oldest coins first (several buys added up to one trade, or only a part sold).
struct TradeLinks {
    struct Part {
        let trade: Trade
        let qty: Double
    }

    private(set) var buysOfSale: [Int: [Part]] = [:]
    private(set) var salesOfBuy: [Int: [Part]] = [:]
    /// Buy id → coins of it not sold yet.
    private(set) var unsold: [Int: Double] = [:]

    init(_ trades: [Trade]) {
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

struct TradeDetailPanel: View {
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

    private var quote: String { trade.quote }

    var body: some View {
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
                Text(verbatim: botName).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Badge(text: trade.paper ? "PAPER" : "LIVE", color: trade.paper ? .paper : .profit)
                Spacer()
                if let close {
                    Button(action: close) {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold))
                            .frame(width: 22, height: 22)
                            .background(Circle().fill(Color.primary.opacity(0.06)))
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.cancelAction)
                    .help("Close")
                }
            }
            (trade.isBuy ? Text("Buy \(trade.base)") : Text("Sell \(trade.base)"))
                .font(.system(size: 18, weight: .bold, design: .rounded))
            Text(verbatim: trade.date.formatted(date: .complete, time: .shortened))
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    // MARK: Sale

    @ViewBuilder
    private var saleContent: some View {
        let buys = links.buysOfSale[trade.id] ?? []
        let qty = buys.reduce(0) { $0 + $1.qty }
        if let pnl = trade.pnl {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                PnLText(value: pnl, currency: quote, font: .system(size: 24, weight: .bold, design: .rounded))
                if let pct = trade.pnlPct {
                    Text(Fmt.pct(pct)).font(.system(size: 13, weight: .semibold)).monospacedDigit().foregroundStyle(pct.pnlColor)
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
                .font(.system(size: 10, weight: .semibold))
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
        .font(.system(size: 11.5))
    }

    @ViewBuilder
    private func reason(_ trade: Trade) -> some View {
        if !trade.reason.isEmpty {
            Text(verbatim: trade.reason)
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.04)))
        }
    }

    private func note(_ text: LocalizedStringKey) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
    }

    /// A linked buy or sale, shown in full – no need to open it.
    private func linked(_ part: TradeLinks.Part, share: Double?) -> some View {
        let other = part.trade
        let partial = abs(part.qty - other.baseQty) > other.baseQty * 0.005
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: other.isBuy ? "arrow.down.left" : "arrow.up.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(other.isBuy ? Color.profit : .red)
                Text(verbatim: other.date.formatted(date: .abbreviated, time: .shortened))
                    .font(.system(size: 11.5, weight: .semibold))
                Spacer(minLength: 4)
                if let share {
                    PnLText(value: share, currency: other.quote, font: .system(size: 11.5, weight: .semibold))
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

/// A trade's details as a page of the menu bar panel – opened from the trade list or a bot's recent trades.
struct TradeDetailPage: View {
    @Environment(AppStore.self) private var store
    let tradeId: Int
    let back: () -> Void
    /// The longer history, so the buy that belongs to an older sale is found too.
    @State private var history: [Trade]?

    private var trades: [Trade] { history ?? store.trades }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "Trade", back: back)
            Divider().opacity(0.5)
            if let trade = trades.first(where: { $0.id == tradeId }) {
                let bot = store.bots.first { $0.id == trade.botId }
                ScrollView {
                    TradeDetailPanel(
                        trade: trade, links: TradeLinks(trades), botName: bot?.name ?? trade.botName,
                        botColor: bot.map { strategyColors($0.strategy)[0] } ?? .secondary,
                        market: bot?.symbol == trade.symbol ? bot?.market?.price : nil,
                        close: nil, framed: false
                    )
                    .padding(14)
                }
                .scrollIndicators(.never)
            } else if history == nil {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                EmptyStateView(icon: "tray", title: "Trade not found", message: "It is no longer among the loaded trades.")
                Spacer()
            }
        }
        .task { history = await store.allTrades(limit: 1000) ?? store.trades }
    }
}

/// Chart symbol for a trade: a buy points up, a sale points down.
struct TradeSymbol: ChartSymbolShape {
    let isBuy: Bool

    var perceptualUnitRect: CGRect { CGRect(x: 0, y: 0, width: 1, height: 1) }

    func path(in rect: CGRect) -> Path {
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
