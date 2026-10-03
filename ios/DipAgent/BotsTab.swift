import DipAgentKit
import SwiftUI

/// The total result on top, then the bots – running ones first. Swipe to start/stop or delete, tap for details.
struct BotsTab: View {
    @Environment(AppStore.self) private var store
    @AppStorage("botSort") private var sortKey = BotSort.running.rawValue
    @State private var path = NavigationPath()
    @State private var creating = false
    @State private var deleting: Bot?
    @State private var error: String?

    private var sort: BotSort { BotSort(rawValue: sortKey) ?? .running }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if !store.isConnected {
                    Section { ConnectionLabel() }
                }
                if let summary = store.summary {
                    Section {
                        SummaryCard(
                            summary: summary,
                            liveAllowed: store.status?.liveTradingAllowed ?? false,
                            balances: store.balances,
                            bots: store.bots,
                            trades: store.trades,
                            limits: store.limits,
                            isDemo: store.status?.exchange == "mock",
                            showHistory: { path.append(Route.history) }
                        )
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                    } footer: {
                        Text("Realized plus open result of all bots, fees already deducted.")
                    }
                }
                if let error {
                    Section { ErrorLabel(message: error) }
                }
                if store.isConnected && store.bots.isEmpty {
                    Section {
                        EmptyStateView(icon: "cpu", title: "No bots yet", message: "Create your first bot – e.g. a dip buyer for ETH-EUR.")
                        Button { creating = true } label: { Label("New bot", systemImage: "plus") }
                    }
                }
                group("Active", bots: store.bots.filter(\.enabled))
                group("Stopped", bots: store.bots.filter { !$0.enabled })
            }
            .navigationTitle("Bots")
            .refreshable { await store.refresh() }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if store.bots.count > 1 { sortMenu }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { creating = true } label: { Image(systemName: "plus") }
                        .disabled(!store.isConnected)
                        .accessibilityLabel(Text("New bot"))
                }
            }
            .sheet(isPresented: $creating) {
                BotEditorSheet(bot: nil) { savedId in
                    if let savedId { path.append(Route.bot(savedId)) }
                }
            }
            .confirmationDialog(
                deleting?.position != nil ? "The open position stays in your account – delete anyway?" : "Really delete this bot?",
                isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                titleVisibility: .visible,
                presenting: deleting
            ) { bot in
                Button("Delete bot", role: .destructive) {
                    Task {
                        do { try await store.deleteBot(bot, force: bot.position != nil); error = nil } catch { self.error = error.localizedDescription }
                    }
                }
            }
            .routeDestinations()
        }
    }

    @ViewBuilder
    private func group(_ title: LocalizedStringKey, bots: [Bot]) -> some View {
        if !bots.isEmpty {
            Section {
                ForEach(sort.apply(bots)) { bot in
                    NavigationLink(value: Route.bot(bot.id)) {
                        BotRow(bot: bot)
                    }
                    .swipeActions(edge: .leading) {
                        Button {
                            Task {
                                do { try await store.setRunning(bot, !bot.enabled); error = nil } catch { self.error = error.localizedDescription }
                            }
                        } label: {
                            bot.enabled ? Label("Stop", systemImage: "pause.fill") : Label("Start", systemImage: "play.fill")
                        }
                        .tint(bot.enabled ? .orange : .green)
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) { deleting = bot } label: { Label("Delete", systemImage: "trash") }
                    }
                }
            } header: {
                Text(title)
            }
        }
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sort by", selection: $sortKey) {
                ForEach(BotSort.allCases) { option in
                    Text(option.title).tag(option.rawValue)
                }
            }
        } label: {
            Label("Sort bots", systemImage: "arrow.up.arrow.down")
        }
    }
}

/// One bot in the list: name and mode, what it waits for, its result and status.
struct BotRow: View {
    let bot: Bot

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                IconTile(symbol: bot.strategyIcon, colors: strategyColors(bot.strategy), size: 40)
                    .grayscale(bot.enabled ? 0 : 1)
                    .opacity(bot.enabled ? 1 : 0.55)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(bot.name).font(.headline).lineLimit(1)
                        ModeBadge(paper: bot.paper)
                    }
                    Text(verbatim: "\(bot.symbol) · \(bot.strategyName)")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                PnLText(value: bot.totalPnl, currency: bot.quoteCurrency, font: .body.weight(.semibold))
            }
            if bot.enabled {
                GoalLines(bot: bot)
                StatusLine(bot: bot)
            }
            if !bot.openTrades.isEmpty {
                openTradesLine
            }
        }
        .padding(.vertical, 4)
    }

    /// "2 open trades · value 150.00 € · +0.52 %"
    private var openTradesLine: some View {
        let trades = bot.openTrades
        let value = trades.reduce(0) { $0 + $1.value }
        let cost = trades.reduce(0) { $0 + $1.cost }
        let pct = cost > 0 ? (value / cost - 1) * 100 : 0
        let live = trades.contains { $0.paper == false }
        return HStack(spacing: 6) {
            Image(systemName: "tray.full.fill")
            (trades.count == 1 ? Text("1 open trade") : Text("\(String(trades.count)) open trades"))
            Text(verbatim: "· \(Fmt.money(value, bot.quoteCurrency))")
            Text(Fmt.pct(pct)).foregroundStyle(pct.pnlColor)
        }
        .font(.footnote.weight(.medium))
        .monospacedDigit()
        .foregroundStyle(live ? Color.red : Color.secondary)
    }
}
