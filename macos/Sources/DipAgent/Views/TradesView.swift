import DipAgentKit
import SwiftUI

struct TradesView: View {
    @Environment(AppStore.self) private var store
    var open: (Route?) -> Void = { _ in }
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
        VStack(alignment: .leading, spacing: 12) {
            if !store.isConnected {
                EmptyStateView(icon: "bolt.horizontal.circle", title: "Not connected", message: "Connect the app to your agent in the settings.")
            } else {
                filterBar
                if filtered.isEmpty {
                    EmptyStateView(icon: "tray", title: "No trades yet", message: "As soon as a bot buys or sells, it shows up here.")
                } else {
                    ForEach(grouped, id: \.day) { group in
                        VStack(alignment: .leading, spacing: 6) {
                            SectionLabel(verbatim: dayTitle(group.day), trailing: AnyView(dayResult(group.trades)))
                            Card(padding: 4) {
                                VStack(spacing: 0) {
                                    ForEach(Array(group.trades.enumerated()), id: \.element.id) { index, trade in
                                        TradeRow(trade: trade, open: { open(.trade(trade.id, from: nil)) })
                                        if index < group.trades.count - 1 {
                                            Divider().opacity(0.4).padding(.leading, 44)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private var filterBar: some View {
        HStack {
            Menu {
                Button("All bots") { botFilter = nil }
                Divider()
                ForEach(store.bots) { bot in
                    Button(bot.name) { botFilter = bot.id }
                }
            } label: {
                Label(store.bots.first { $0.id == botFilter }?.name ?? String(localized: "All bots"), systemImage: "line.3.horizontal.decrease.circle")
                    .font(.system(size: 11.5))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            Spacer()
            Text("\(String(filtered.count)) trades").font(.system(size: 10.5)).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func dayResult(_ trades: [Trade]) -> some View {
        let sells = trades.filter { $0.pnl != nil }
        if let quote = sells.first?.quote {
            PnLText(value: sells.compactMap(\.pnl).reduce(0, +), currency: quote, font: .system(size: 10.5, weight: .semibold))
        }
    }

    private func dayTitle(_ day: Date) -> String {
        if Calendar.current.isDateInToday(day) { return String(localized: "Today") }
        if Calendar.current.isDateInYesterday(day) { return String(localized: "Yesterday") }
        return day.formatted(.dateTime.weekday(.wide).day().month(.wide))
    }
}

struct TradeRow: View {
    let trade: Trade
    /// Shows the trade's details; nil = not clickable.
    var open: (() -> Void)?
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(tint.opacity(0.15)).frame(width: 30, height: 30)
                Image(systemName: trade.isBuy ? "arrow.down.left" : "arrow.up.right")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(tint)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    (trade.isBuy ? Text("Buy \(trade.base)") : Text("Sell \(trade.base)"))
                        .font(.system(size: 12.5, weight: .semibold))
                    if trade.paper { Badge(text: "PAPER", color: .paper) }
                }
                Text(verbatim: "\(trade.botName) · \(Fmt.qty(trade.baseQty)) @ \(Fmt.price(trade.price, trade.quote))")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 2) {
                Text(verbatim: (trade.isBuy ? "−" : "+") + Fmt.money(trade.quoteAmount, trade.quote))
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
                if let pnl = trade.pnl {
                    HStack(spacing: 4) {
                        PnLText(value: pnl, currency: trade.quote, font: .system(size: 10.5, weight: .semibold))
                        if let pct = trade.pnlPct {
                            Text(Fmt.pct(pct))
                                .font(.system(size: 10, weight: .medium)).monospacedDigit()
                                .foregroundStyle(pct.pnlColor)
                        }
                    }
                } else {
                    Text(trade.date.formatted(date: .omitted, time: .shortened))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
            }
            if open != nil {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 10).fill(hovering ? Color.primary.opacity(0.05) : .clear))
        .onHover { hovering = $0 }
        .contentShape(Rectangle())
        .onTapGesture { open?() }
        .help("\(trade.reason)\n\(trade.date.formatted(date: .abbreviated, time: .standard)) · Fee \(Fmt.money(trade.fee, trade.quote))")
    }

    private var tint: Color { trade.isBuy ? .blue : .orange }
}
