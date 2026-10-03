import AppKit
import Charts
import DipAgentKit
import SwiftUI

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

    private typealias Curve = ProfitHistoryData.Curve

    // MARK: Data

    private var trades: [Trade] { history ?? store.trades }

    private var data: ProfitHistoryData {
        ProfitHistoryData(trades: trades, bots: store.bots, summary: store.summary, live: live, currency: currency,
                          range: range, perBot: perBot, hidden: hidden)
    }

    private var currencies: [String] { data.currencies }
    private var scoped: [Trade] { data.scoped }
    private var botIds: [Int] { data.botIds }
    private var curves: [Curve] { data.curves }
    private var stats: [ProfitHistoryData.BotStats] { data.stats }
    private func color(_ botId: Int) -> Color { data.color(botId) }
    private func name(_ botId: Int) -> String { data.name(botId) }

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

    private var markers: [ProfitHistoryData.Marker] { data.markers }

    /// The trade under the mouse.
    private var selected: (curve: Curve, point: ProfitPoint)? {
        guard let hoveredId else { return nil }
        return markers.first { $0.point.id == hoveredId }
    }

    private var links: TradeLinks { data.links }

    /// The trade shown in the details and the trades it belongs to – emphasized in the chart.
    private var related: Set<Int> { data.related(to: detail, links: links) }

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

    private var yDomain: ClosedRange<Double> { data.yDomain }
    private var xDomain: ClosedRange<Date> { data.xDomain }

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

    private func botRow(_ row: ProfitHistoryData.BotStats) -> some View {
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
