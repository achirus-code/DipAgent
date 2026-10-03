import Charts
import DipAgentKit
import SwiftUI

/// The realized result over time – one line per bot (or all together), every buy ▲ and sale ▼ as a point.
/// Tap a point for the trade's details; bots can be switched off below the chart.
struct ProfitHistoryScreen: View {
    @Environment(AppStore.self) private var store
    @State private var history: [Trade]?
    @State private var live = false
    @State private var currency = "EUR"
    @State private var range: HistoryRange = .month
    @State private var perBot = true
    @State private var hidden: Set<Int> = []
    @State private var detail: Trade?
    @State private var reveal = 0.0

    private static let historyLimit = 1000

    private var data: ProfitHistoryData {
        ProfitHistoryData(trades: history ?? store.trades, bots: store.bots, summary: store.summary, live: live,
                          currency: currency, range: range, perBot: perBot, hidden: hidden)
    }

    var body: some View {
        let data = data
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Picker("Period", selection: $range) {
                    ForEach(HistoryRange.allCases) { Text($0.shortTitle).tag($0) }
                }
                .pickerStyle(.segmented)

                if data.scoped.isEmpty {
                    EmptyStateView(icon: "chart.xyaxis.line", title: "No trades yet", message: "As soon as a bot buys or sells, its curve shows up here.")
                } else {
                    tiles(data)
                    chart(data)
                        .frame(height: 280)
                    legend(data)
                    botList(data)
                }
            }
            .padding()
        }
        .navigationTitle("Profit history")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { optionsMenu(data) }
        }
        .sheet(item: $detail) { trade in
            NavigationStack {
                ScrollView {
                    TradeDetailPanel(trade: trade, links: data.links, botName: data.name(trade.botId), botColor: data.color(trade.botId),
                                     market: store.bots.first { $0.id == trade.botId && $0.symbol == trade.symbol }?.market?.price,
                                     close: nil, framed: false)
                        .padding()
                }
                .navigationTitle("Trade")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { Button("Done") { detail = nil } }
            }
            .presentationDetents([.medium, .large])
        }
        .refreshable { await load() }
        .task(id: store.trades.first?.id) { await load() }
        .onAppear {
            live = store.summary?.mode == "live"
            currency = store.summary?.currencies.first?.currency ?? data.currencies.first ?? currency
            replay()
        }
        .onChange(of: data.currencies) { _, available in
            if !available.contains(currency), let first = available.first { currency = first }
        }
        .onChange(of: live) { detail = nil; replay() }
        .onChange(of: currency) { detail = nil; replay() }
        .onChange(of: perBot) { replay() }
    }

    private func load() async {
        if let all = await store.allTrades(limit: Self.historyLimit) { history = all }
    }

    /// The curves grow out of the zero line again.
    private func replay() {
        reveal = 0
        DispatchQueue.main.async {
            withAnimation(.spring(duration: 0.9, bounce: 0.15)) { reveal = 1 }
        }
    }

    private func optionsMenu(_ data: ProfitHistoryData) -> some View {
        Menu {
            Picker("Mode", selection: $live) {
                Text("Paper").tag(false)
                Text("Live").tag(true)
            }
            Picker("View", selection: $perBot) {
                Text("Per bot").tag(true)
                Text("Combined").tag(false)
            }
            if data.currencies.count > 1 {
                Picker("Currency", selection: $currency) {
                    ForEach(data.currencies, id: \.self) { Text(verbatim: $0).tag($0) }
                }
            }
        } label: {
            Label("Options", systemImage: "slider.horizontal.3")
        }
    }

    // MARK: Tiles

    private func tiles(_ data: ProfitHistoryData) -> some View {
        let t = data.totals
        return VStack(alignment: .leading, spacing: 6) {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                tile(live ? "Profit/loss (live)" : "Profit/loss (paper)") {
                    PnLText(value: t.pnl, currency: currency, font: .title3.weight(.bold))
                }
                tile("Trades") {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(verbatim: String(t.buys + t.sells)).font(.title3.weight(.bold)).monospacedDigit()
                        Text("\(String(t.buys)) buys · \(String(t.sells)) sales").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                tile("Win rate") {
                    Text(verbatim: t.sells > 0 ? Fmt.rate(Double(t.wins) / Double(t.sells) * 100) : "–")
                        .font(.title3.weight(.bold)).monospacedDigit()
                }
                tile("Volume") {
                    Text(verbatim: Fmt.money(t.volume, currency)).font(.title3.weight(.bold)).monospacedDigit()
                        .minimumScaleFactor(0.7).lineLimit(1)
                }
            }
            Text("Fees \(Fmt.money(t.fees, currency)) – already included in the result.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func tile<Content: View>(_ title: LocalizedStringKey, @ViewBuilder value: () -> Content) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                value()
            }
            .frame(maxHeight: .infinity, alignment: .topLeading)
        }
    }

    // MARK: Chart

    private func chart(_ data: ProfitHistoryData) -> some View {
        let markers = data.markers
        let related = data.related(to: detail, links: data.links)
        return Chart {
            RuleMark(y: .value("Result", 0))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 4]))
                .foregroundStyle(Color.secondary.opacity(0.6))
            ForEach(data.curves) { curve in
                ForEach(curve.points) { point in
                    LineMark(x: .value("Date", point.date), y: .value("Result", point.value * reveal), series: .value("Bot", curve.id))
                        .interpolationMethod(.monotone)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                        .foregroundStyle(curve.color)
                }
            }
            ForEach(markers, id: \.point.id) { marker in
                let emphasized = marker.point.trade.map { related.contains($0.id) } ?? false
                PointMark(x: .value("Date", marker.point.date), y: .value("Result", marker.point.value * reveal))
                    .symbol(TradeSymbol(isBuy: marker.point.trade?.isBuy == true))
                    .symbolSize(emphasized ? 120 : 40)
                    .foregroundStyle(marker.point.trade?.isBuy == false ? Color.red : Color.profit)
                    .opacity((related.isEmpty || emphasized ? 1 : 0.3) * reveal)
            }
        }
        .chartXScale(domain: data.xDomain)
        .chartYScale(domain: data.yDomain)
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let amount = value.as(Double.self) { Text(verbatim: Fmt.money(amount, currency)) }
                }
            }
        }
        .chartLegend(.hidden)
        .animation(.smooth(duration: 0.5), value: range)
        .animation(.smooth(duration: 0.4), value: hidden)
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onTapGesture { location in
                        detail = nearest(location, markers, proxy, geo)?.point.trade
                    }
            }
        }
    }

    /// The marker closest to a tap – within reach of a finger.
    private func nearest(_ location: CGPoint, _ markers: [ProfitHistoryData.Marker], _ proxy: ChartProxy, _ geo: GeometryProxy) -> ProfitHistoryData.Marker? {
        guard let plotFrame = proxy.plotFrame else { return nil }
        let origin = geo[plotFrame].origin
        var best: (marker: ProfitHistoryData.Marker, distance: CGFloat)?
        for marker in markers {
            guard let x = proxy.position(forX: marker.point.date), let y = proxy.position(forY: marker.point.value) else { continue }
            let distance = hypot(origin.x + x - location.x, origin.y + y - location.y)
            if distance < 32, distance < best?.distance ?? .infinity { best = (marker, distance) }
        }
        return best?.marker
    }

    private func legend(_ data: ProfitHistoryData) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 14) {
                Label { Text("Buy") } icon: { Image(systemName: "arrowtriangle.up.fill").foregroundStyle(Color.profit) }
                Label { Text("Sale") } icon: { Image(systemName: "arrowtriangle.down.fill").foregroundStyle(.red) }
                Spacer()
                if data.trades.count >= Self.historyLimit {
                    Text("Latest \(String(Self.historyLimit)) trades")
                }
            }
            Text("Tap a point for the trade's details. The line shows the realized result, fees deducted – it moves with every sale.")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    // MARK: Bots

    private func botList(_ data: ProfitHistoryData) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionLabel("Bots")
                Spacer()
                Button(hidden.isEmpty ? "Hide all" : "Show all") {
                    withAnimation(.smooth(duration: 0.4)) { hidden = hidden.isEmpty ? Set(data.botIds) : [] }
                }
                .font(.footnote)
            }
            Card(padding: 4) {
                VStack(spacing: 0) {
                    ForEach(data.stats) { row in
                        let isShown = !hidden.contains(row.id)
                        Button {
                            withAnimation(.smooth(duration: 0.4)) {
                                if isShown { hidden.insert(row.id) } else { hidden.remove(row.id) }
                            }
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: isShown ? "checkmark.circle.fill" : "circle")
                                    .font(.title3)
                                    .foregroundStyle(isShown ? data.color(row.id) : Color.secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text(verbatim: row.name).font(.subheadline.weight(.medium)).foregroundStyle(.primary)
                                        if row.deleted { Text("Deleted").font(.caption).foregroundStyle(.tertiary) }
                                    }
                                    Text("\(String(row.buys)) buys · \(String(row.sells)) sales · fees \(Fmt.money(row.fees, currency))")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 4)
                                PnLText(value: row.pnl, currency: currency, font: .subheadline.weight(.semibold))
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .opacity(isShown ? 1 : 0.5)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

extension HistoryRange {
    /// For the segmented control on the narrow iPhone screen.
    var shortTitle: LocalizedStringKey {
        switch self {
        case .week: return "7 d"
        case .month: return "30 d"
        case .quarter: return "90 d"
        case .year: return "1 y"
        case .all: return "All"
        }
    }
}
