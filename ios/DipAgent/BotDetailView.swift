import DipAgentKit
import SwiftUI

/// Everything about one bot: what it waits for, its open trades (each can be sold), result, Claude's answers,
/// rules, recent trades and activity. Edit in the toolbar, reset and delete at the bottom.
struct BotDetailView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let botId: Int

    @State private var events: [BotEvent] = []
    @State private var decisions: [AiDecision] = []
    @State private var error: String?
    @State private var editing = false
    @State private var busy = false
    /// The pending confirmation – every one of them changes something on the agent.
    @State private var confirming: Confirmation?
    /// A sale failed (for this trade id, or "position") – only then "discard without a sale" is offered.
    @State private var sellFailed: String?

    private enum Confirmation: Identifiable {
        case sell(String?), discard(String?), ask, reset, delete
        var id: String {
            switch self {
            case .sell(let trade): return "sell-\(trade ?? "")"
            case .discard(let trade): return "discard-\(trade ?? "")"
            case .ask: return "ask"
            case .reset: return "reset"
            case .delete: return "delete"
            }
        }
    }

    var body: some View {
        if let bot = store.bots.first(where: { $0.id == botId }) {
            List {
                hero(bot)
                if let error {
                    Section { ErrorLabel(message: error) }
                }
                openTrades(bot)
                result(bot)
                if bot.strategy == "ai" { claude(bot) }
                rules(bot)
                recentTrades(bot)
                activity
                actions(bot)
            }
            .navigationTitle(bot.name)
            .navigationBarTitleDisplayMode(.inline)
            .refreshable { await store.refresh() }
            .toolbar {
                Button("Edit") { editing = true }
            }
            .sheet(isPresented: $editing) {
                BotEditorSheet(bot: bot) { _ in }
            }
            .confirmationDialog(title(confirming, bot), isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
                                titleVisibility: .visible, presenting: confirming) { action in
                confirmButton(action, bot)
            }
            .task(id: store.lastUpdate) {
                events = await store.events(for: botId)
                if bot.strategy == "ai" { decisions = await store.decisions(for: botId) }
            }
        } else {
            EmptyStateView(icon: "questionmark.circle", title: "Bot not found", message: "The bot has been deleted.")
        }
    }

    // MARK: Sections

    private func hero(_ bot: Bot) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    IconTile(symbol: bot.strategyIcon, colors: strategyColors(bot.strategy), size: 48)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(bot.symbol).font(.title3.bold())
                            ModeBadge(paper: bot.paper)
                        }
                        Text(bot.strategyName).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                if bot.enabled, bot.goal != nil || bot.targets?.note != nil {
                    GoalLines(bot: bot, large: true)
                } else if let market = bot.market {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(Fmt.price(market.price, bot.quoteCurrency)).font(.title2.weight(.semibold)).monospacedDigit()
                        Text("\(Fmt.pct(market.change24h)) in 24 h").font(.subheadline.weight(.medium))
                            .foregroundStyle(market.change24h.pnlColor)
                    }
                }
                StatusLine(bot: bot)
                if bot.paper && !bot.paperRequested {
                    Label("Paper trading is off, but live trading is disabled in the settings – the bot trades simulated.", systemImage: "testtube.2")
                        .font(.footnote).foregroundStyle(.orange)
                }
                Button {
                    run { try await store.setRunning(bot, !bot.enabled) }
                } label: {
                    HStack {
                        Spacer()
                        if busy { ProgressView().tint(.white) } else {
                            Label(bot.enabled ? LocalizedStringKey("Stop bot") : LocalizedStringKey("Start bot"),
                                  systemImage: bot.enabled ? "pause.fill" : "play.fill")
                                .bold()
                        }
                        Spacer()
                    }
                    .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .tint(bot.enabled ? .orange : .green)
                .disabled(busy)
            }
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private func openTrades(_ bot: Bot) -> some View {
        let trades = bot.openTrades
        if !trades.isEmpty {
            let several = bot.tradesMode
            ForEach(Array(trades.enumerated()), id: \.offset) { index, trade in
                // older agents: one position without an id – sold as a whole
                let tradeId: String? = several ? (trade.id ?? "") : nil
                Section {
                    LabeledContent("Amount", value: "\(Fmt.qty(trade.qty)) \(bot.baseCurrency)")
                    LabeledContent("Entry", value: Fmt.price(trade.entryPrice, bot.quoteCurrency))
                    LabeledContent("Invested", value: Fmt.money(trade.cost, bot.quoteCurrency))
                    LabeledContent("Value", value: Fmt.money(trade.value, bot.quoteCurrency))
                    LabeledContent("Result") {
                        HStack(spacing: 6) {
                            PnLText(value: trade.unrealizedPnl, currency: bot.quoteCurrency, font: .body.weight(.semibold))
                            Text(Fmt.pct(trade.unrealizedPct)).foregroundStyle(trade.unrealizedPct.pnlColor).monospacedDigit()
                        }
                    }
                    if let target = OpenTradeRow.targetText(trade, bot: bot) {
                        LabeledContent("Target", value: target)
                    }
                    LabeledContent("Since", value: Date(ms: trade.openedAt).formatted(.relative(presentation: .named)))
                    Button(role: .destructive) { confirming = .sell(tradeId) } label: {
                        Label(several ? "Sell this trade now" : "Sell position now", systemImage: "arrow.up.right.circle")
                    }
                    if sellFailed == (tradeId ?? "position") {
                        // the sale didn't go through – for a position that is wrong in the books the way out is to
                        // forget it without selling
                        Button { confirming = .discard(tradeId) } label: {
                            Label("Discard position (no sale)", systemImage: "xmark.bin")
                        }
                        .tint(.orange)
                    }
                } header: {
                    if several {
                        Text("Trade \(String(index + 1)) of \(String(bot.maxTrades ?? trades.count))")
                    } else {
                        Text(trade.paper == false ? "Open live position" : "Open position")
                    }
                }
            }
        }
    }

    private func result(_ bot: Bot) -> some View {
        Section("Result") {
            LabeledContent("Total") { PnLText(value: bot.totalPnl, currency: bot.quoteCurrency, font: .body.weight(.bold)) }
            LabeledContent("Realized") { PnLText(value: bot.realizedPnl, currency: bot.quoteCurrency, font: .body) }
            LabeledContent("Trades", value: String(bot.tradesCount))
            LabeledContent("Winners", value: bot.wins + bot.losses == 0 ? "–" : "\(bot.wins)/\(bot.wins + bot.losses)")
        }
    }

    /// Claude's answers: the latest three, the rest on their own page – plus a fresh answer on request.
    private func claude(_ bot: Bot) -> some View {
        Section {
            if decisions.isEmpty {
                Text("No answers yet – Claude is asked at the next check.")
                    .font(.footnote).foregroundStyle(.secondary)
            } else {
                ForEach(decisions.prefix(3)) { DecisionRow(decision: $0, currency: bot.quoteCurrency) }
                if decisions.count > 3 {
                    NavigationLink {
                        List(decisions) { DecisionRow(decision: $0, currency: bot.quoteCurrency) }
                            .navigationTitle("Claude's decisions")
                    } label: {
                        Text("All \(String(decisions.count)) answers")
                    }
                }
            }
            if bot.enabled {
                Button { confirming = .ask } label: { Label("Ask Claude now", systemImage: "brain") }
                    .disabled(bot.pendingOrder || busy)
            }
        } header: {
            Text("Claude's decisions")
        } footer: {
            if !decisions.isEmpty {
                Text("Ø \(String(decisions.map(\.confidence).reduce(0, +) / max(decisions.count, 1))) % sure")
            }
        }
    }

    private func rules(_ bot: Bot) -> some View {
        Section("Rules") {
            ForEach(store.strategy(bot.strategy)?.params ?? []) { param in
                LabeledContent(param.label, value: ParamFormatting.display(param, bot.params[param.key] ?? param.default, currency: bot.quoteCurrency))
            }
        }
    }

    @ViewBuilder
    private func recentTrades(_ bot: Bot) -> some View {
        let trades = store.trades.filter { $0.botId == bot.id }.prefix(5)
        if !trades.isEmpty {
            Section("Recent trades") {
                ForEach(Array(trades)) { trade in
                    NavigationLink(value: Route.trade(trade.id)) { TradeListRow(trade: trade, showBot: false) }
                }
            }
        }
    }

    @ViewBuilder
    private var activity: some View {
        if !events.isEmpty {
            Section("Activity") {
                ForEach(events.prefix(5)) { EventRow(event: $0) }
                if events.count > 5 {
                    NavigationLink {
                        List(events) { EventRow(event: $0) }.navigationTitle("Activity")
                    } label: {
                        Text("Show all")
                    }
                }
            }
        }
    }

    private func actions(_ bot: Bot) -> some View {
        Section {
            if bot.paper, bot.tradesCount > 0 || !bot.openTrades.isEmpty {
                Button { confirming = .reset } label: { Label("Reset paper result", systemImage: "arrow.counterclockwise") }
                    .tint(.orange)
            }
            Button(role: .destructive) { confirming = .delete } label: { Label("Delete bot", systemImage: "trash") }
        }
    }

    // MARK: Confirmations

    private func title(_ confirmation: Confirmation?, _ bot: Bot) -> Text {
        switch confirmation {
        case .sell: return Text("Really sell at the market price?")
        case .discard: return Text("Remove the position from the books without selling? Coins on the exchange stay there.")
        case .ask: return Text("Ask Claude for a fresh decision now? This costs one extra check.")
        case .reset: return Text("Delete all paper trades of this bot and reset its result to zero? Open paper trades are discarded. This cannot be undone.")
        case .delete: return Text(bot.position != nil ? "The open position stays in your account – delete anyway?" : "Really delete this bot?")
        case nil: return Text(verbatim: "")
        }
    }

    @ViewBuilder
    private func confirmButton(_ confirmation: Confirmation, _ bot: Bot) -> some View {
        switch confirmation {
        case .sell(let tradeId):
            Button("Sell now", role: .destructive) {
                let key = tradeId ?? "position"
                run(onError: { sellFailed = key }) {
                    try await store.closePosition(bot, positionId: tradeId)
                    sellFailed = nil
                }
            }
        case .discard(let tradeId):
            Button("Discard position (no sale)", role: .destructive) {
                run {
                    try await store.discardPosition(bot, positionId: tradeId)
                    sellFailed = nil
                }
            }
        case .ask:
            Button("Ask Claude") { run { try await store.askClaude(bot) } }
        case .reset:
            Button("Reset paper result", role: .destructive) { run { try await store.resetPaper(bot) } }
        case .delete:
            Button("Delete bot", role: .destructive) {
                run {
                    try await store.deleteBot(bot, force: bot.position != nil)
                    dismiss()
                }
            }
        }
    }

    private func run(onError: @escaping () -> Void = {}, _ action: @escaping () async throws -> Void) {
        busy = true
        Task {
            do {
                try await action()
                error = nil
            } catch {
                self.error = error.localizedDescription
                onError()
            }
            busy = false
        }
    }
}

/// One line of a bot's activity log.
struct EventRow: View {
    let event: BotEvent

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.message).font(.subheadline)
                Text(Date(ms: event.createdAt).formatted(date: .abbreviated, time: .shortened))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var icon: String {
        switch event.level {
        case "trade": return "arrow.left.arrow.right.circle.fill"
        case "error": return "exclamationmark.triangle.fill"
        default: return "info.circle.fill"
        }
    }

    private var color: Color {
        switch event.level {
        case "trade": return .accentColor
        case "error": return .red
        default: return .secondary
        }
    }
}
