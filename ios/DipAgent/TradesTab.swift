import DipAgentKit
import SwiftUI

/// All buys and sales, newest first, by day with the day's result. Filter by bot; the chart in the toolbar.
struct TradesTab: View {
    @Environment(AppStore.self) private var store
    @State private var botFilter: Int?

    private var filtered: [Trade] {
        guard let botFilter else { return store.trades }
        return store.trades.filter { $0.botId == botFilter }
    }

    private var grouped: [(day: Date, trades: [Trade])] {
        let groups = Dictionary(grouping: filtered) { Calendar.current.startOfDay(for: $0.date) }
        return groups.keys.sorted(by: >).map { ($0, groups[$0]!) }
    }

    var body: some View {
        NavigationStack {
            List {
                if !store.isConnected {
                    Section { ConnectionLabel() }
                }
                if store.isConnected && filtered.isEmpty {
                    EmptyStateView(icon: "tray", title: "No trades yet", message: "As soon as a bot buys or sells, it shows up here.")
                        .listRowBackground(Color.clear)
                }
                ForEach(grouped, id: \.day) { group in
                    Section {
                        ForEach(group.trades) { trade in
                            NavigationLink(value: Route.trade(trade.id)) { TradeListRow(trade: trade) }
                        }
                    } header: {
                        HStack {
                            Text(verbatim: dayTitle(group.day))
                            Spacer()
                            dayResult(group.trades)
                        }
                    }
                }
            }
            .navigationTitle(botFilter.flatMap { id in store.bots.first { $0.id == id }?.name } ?? String(localized: "Trades"))
            .refreshable { await store.refresh() }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Picker("Bot", selection: $botFilter) {
                            Text("All bots").tag(Int?.none)
                            ForEach(store.bots) { bot in
                                Text(bot.name).tag(Int?.some(bot.id))
                            }
                        }
                    } label: {
                        Label("Filter", systemImage: botFilter == nil ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink(value: Route.history) {
                        Label("Profit history", systemImage: "chart.xyaxis.line")
                    }
                }
            }
            .routeDestinations()
        }
    }

    @ViewBuilder
    private func dayResult(_ trades: [Trade]) -> some View {
        let sells = trades.filter { $0.pnl != nil }
        if let quote = sells.first?.quote {
            PnLText(value: sells.compactMap(\.pnl).reduce(0, +), currency: quote, font: .footnote.weight(.semibold))
                .textCase(nil)
        }
    }

    private func dayTitle(_ day: Date) -> String {
        if Calendar.current.isDateInToday(day) { return String(localized: "Today") }
        if Calendar.current.isDateInYesterday(day) { return String(localized: "Yesterday") }
        return day.formatted(.dateTime.weekday(.wide).day().month(.wide))
    }
}

/// "▲ Buy ETH · ETH Dip · 0.02 @ 2,450 €" with the amount and – for sales – the result on the right.
struct TradeListRow: View {
    let trade: Trade
    var showBot = true

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: trade.isBuy ? "arrowtriangle.up.fill" : "arrowtriangle.down.fill")
                .font(.footnote)
                .foregroundStyle(tint)
                .frame(width: 30, height: 30)
                .background(Circle().fill(tint.opacity(0.15)))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    (trade.isBuy ? Text("Buy \(trade.base)") : Text("Sell \(trade.base)"))
                        .font(.subheadline.weight(.semibold))
                    if trade.paper { Badge(text: "PAPER", color: .paper) }
                }
                Text(verbatim: showBot ? "\(trade.botName) · \(Fmt.qty(trade.baseQty)) @ \(Fmt.price(trade.price, trade.quote))"
                                       : "\(Fmt.qty(trade.baseQty)) @ \(Fmt.price(trade.price, trade.quote))")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 2) {
                Text(verbatim: (trade.isBuy ? "−" : "+") + Fmt.money(trade.quoteAmount, trade.quote))
                    .font(.subheadline.weight(.medium)).monospacedDigit()
                if let pnl = trade.pnl {
                    HStack(spacing: 4) {
                        PnLText(value: pnl, currency: trade.quote, font: .caption.weight(.semibold))
                        if let pct = trade.pnlPct {
                            Text(Fmt.pct(pct)).font(.caption).monospacedDigit().foregroundStyle(pct.pnlColor)
                        }
                    }
                } else {
                    Text(trade.date.formatted(date: showBot ? .omitted : .abbreviated, time: .shortened))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Buys green ▲, sales red ▼ – the same as in the chart.
    private var tint: Color { trade.isBuy ? .profit : .red }
}

/// A trade's details: when and at what price it was bought and sold, how long it was held, fees and result.
struct TradeDetailScreen: View {
    @Environment(AppStore.self) private var store
    let tradeId: Int
    /// The longer history, so the buy that belongs to an older sale is found too.
    @State private var history: [Trade]?

    private var trades: [Trade] { history ?? store.trades }

    var body: some View {
        Group {
            if let trade = trades.first(where: { $0.id == tradeId }) {
                let bot = store.bots.first { $0.id == trade.botId }
                ScrollView {
                    TradeDetailPanel(
                        trade: trade, links: TradeLinks(trades), botName: bot?.name ?? trade.botName,
                        botColor: bot.map { strategyColors($0.strategy)[0] } ?? .secondary,
                        market: bot?.symbol == trade.symbol ? bot?.market?.price : nil,
                        close: nil, framed: false
                    )
                    .padding()
                }
            } else if history == nil {
                ProgressView()
            } else {
                EmptyStateView(icon: "tray", title: "Trade not found", message: "It is no longer among the loaded trades.")
            }
        }
        .navigationTitle("Trade")
        .navigationBarTitleDisplayMode(.inline)
        .task { history = await store.allTrades(limit: 1000) ?? store.trades }
    }
}
