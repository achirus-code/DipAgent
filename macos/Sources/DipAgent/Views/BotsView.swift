import SwiftUI

struct BotsView: View {
    @Environment(AppStore.self) private var store
    let open: (Route?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !store.isConnected {
                EmptyStateView(icon: "bolt.horizontal.circle", title: "Not connected", message: "Connect the app to your agent in the settings.")
            } else {
                SectionLabel("My bots", trailing: AnyView(
                    Button { open(.editor(nil)) } label: {
                        Label("New bot", systemImage: "plus").font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                ))
                if store.bots.isEmpty {
                    EmptyStateView(icon: "cpu", title: "No bots yet", message: "Create your first bot – e.g. a dip buyer for ETH-EUR.")
                } else {
                    ForEach(store.bots) { bot in
                        BotCard(bot: bot)
                            .contentShape(Rectangle())
                            .onTapGesture { open(.bot(bot.id)) }
                    }
                }
            }
        }
    }
}

struct BotCard: View {
    @Environment(AppStore.self) private var store
    let bot: Bot
    @State private var hovering = false

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    IconTile(symbol: bot.strategyIcon, colors: strategyColors(bot.strategy), size: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 5) {
                            Text(bot.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                            if bot.paper { Badge(text: "PAPER", color: .orange) } else { Badge(text: "LIVE", color: .red, icon: "bolt.fill") }
                        }
                        Text(verbatim: "\(bot.symbol) · \(bot.strategyName)")
                            .font(.system(size: 10.5)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    RunToggle(bot: bot)
                }

                HStack(alignment: .firstTextBaseline) {
                    if let market = bot.market {
                        Text(Fmt.price(market.price, bot.quoteCurrency))
                            .font(.system(size: 12, weight: .medium)).monospacedDigit()
                        Text(verbatim: "\(Fmt.pct(market.change24h)) 24h")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(market.change24h.pnlColor)
                    }
                    Spacer()
                    PnLText(value: bot.totalPnl, currency: bot.quoteCurrency, font: .system(size: 13, weight: .bold, design: .rounded))
                }

                StatusLine(bot: bot)

                if let position = bot.position {
                    PositionStrip(bot: bot, position: position)
                }
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(hovering ? 0.35 : 0), lineWidth: 1)
        )
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }
}

struct RunToggle: View {
    @Environment(AppStore.self) private var store
    let bot: Bot
    @State private var busy = false

    var body: some View {
        Toggle("", isOn: Binding(
            get: { bot.enabled },
            set: { newValue in
                busy = true
                Task {
                    try? await store.setRunning(bot, newValue)
                    busy = false
                }
            }
        ))
        .toggleStyle(.switch)
        .controlSize(.mini)
        .labelsHidden()
        .disabled(busy)
        .help(bot.enabled ? Text("Stop bot") : Text("Start bot"))
    }
}

struct StatusLine: View {
    let bot: Bot
    @State private var pulse = false

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
                .opacity(bot.enabled && pulse ? 0.35 : 1)
                .padding(.top, 4)
                .animation(bot.enabled ? .easeInOut(duration: 1).repeatForever() : .default, value: pulse)
                .onAppear { pulse = true }
            Text(statusText)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
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

struct PositionStrip: View {
    let bot: Bot
    let position: BotPosition

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                (position.paper == false ? Text("Open live position") : Text("Open position"))
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(position.paper == false ? Color.red : .secondary)
                Text("\(Fmt.qty(position.qty)) \(bot.baseCurrency) · entry \(Fmt.price(position.entryPrice, bot.quoteCurrency))")
                    .font(.system(size: 10.5)).monospacedDigit()
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                PnLText(value: position.unrealizedPnl, currency: bot.quoteCurrency, font: .system(size: 11, weight: .semibold))
                Text(Fmt.pct(position.unrealizedPct))
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(position.unrealizedPct.pnlColor)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.accentColor.opacity(0.08)))
    }
}

// MARK: - Detail

struct BotDetailView: View {
    @Environment(AppStore.self) private var store
    let botId: Int
    let open: (Route?) -> Void
    @State private var events: [BotEvent] = []
    @State private var error: String?

    var body: some View {
        if let bot = store.bots.first(where: { $0.id == botId }) {
            VStack(spacing: 0) {
                PageHeader(title: "\(bot.name)", back: { open(nil) }, trailing: AnyView(
                    Button("Edit") { open(.editor(bot.id)) }
                        .buttonStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.accentColor)
                ))
                Divider().opacity(0.5)
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        hero(bot)
                        if let error {
                            Text(error).font(.system(size: 11)).foregroundStyle(.red)
                        }
                        if let position = bot.position { positionCard(bot, position) }
                        stats(bot)
                        parameters(bot)
                        recentTrades(bot)
                        activity
                        deleteSection(bot)
                    }
                    .padding(14)
                }
                .scrollIndicators(.never)
            }
            .task(id: store.lastUpdate) { events = await store.events(for: botId) }
        } else {
            VStack {
                PageHeader(title: "Bot", back: { open(nil) })
                EmptyStateView(icon: "questionmark.circle", title: "Bot not found", message: "The bot has been deleted.")
                Spacer()
            }
        }
    }

    private func hero(_ bot: Bot) -> some View {
        Card(padding: 14) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    IconTile(symbol: bot.strategyIcon, colors: strategyColors(bot.strategy), size: 42)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 5) {
                            Text(bot.symbol).font(.system(size: 15, weight: .bold, design: .rounded))
                            if bot.paper { Badge(text: "PAPER", color: .orange) } else { Badge(text: "LIVE", color: .red, icon: "bolt.fill") }
                        }
                        Text(bot.strategyName).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        Task { try? await store.setRunning(bot, !bot.enabled) }
                    } label: {
                        Label(bot.enabled ? LocalizedStringKey("Stop") : LocalizedStringKey("Start"), systemImage: bot.enabled ? "pause.fill" : "play.fill")
                            .font(.system(size: 11.5, weight: .semibold))
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .foregroundStyle(.white)
                            .background(Capsule().fill(bot.enabled ? Color.orange.gradient : Color.green.gradient))
                    }
                    .buttonStyle(.plain)
                }
                if let market = bot.market {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(Fmt.price(market.price, bot.quoteCurrency))
                            .font(.system(size: 20, weight: .semibold, design: .rounded)).monospacedDigit()
                        Text("\(Fmt.pct(market.change24h)) in 24 h")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(market.change24h.pnlColor)
                    }
                }
                StatusLine(bot: bot)
                if bot.paper && !bot.paperRequested {
                    Label("Paper trading is off, but live trading is disabled in the settings – the bot trades simulated.", systemImage: "testtube.2")
                        .font(.system(size: 10.5)).foregroundStyle(.orange)
                }
            }
        }
    }

    private func positionCard(_ bot: Bot, _ position: BotPosition) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel("Open position")
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        detail("Amount", "\(Fmt.qty(position.qty)) \(bot.baseCurrency)")
                        detail("Entry", Fmt.price(position.entryPrice, bot.quoteCurrency))
                        detail("Invested", Fmt.money(position.cost, bot.quoteCurrency))
                    }
                    HStack {
                        detail("Value", Fmt.money(position.value, bot.quoteCurrency))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Result").font(.system(size: 10)).foregroundStyle(.secondary)
                            HStack(spacing: 4) {
                                PnLText(value: position.unrealizedPnl, currency: bot.quoteCurrency)
                                Text(Fmt.pct(position.unrealizedPct)).font(.system(size: 10)).foregroundStyle(position.unrealizedPct.pnlColor)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        detail("Since", Date(ms: position.openedAt).formatted(.relative(presentation: .named)))
                    }
                    ConfirmButton(title: "Sell position now", confirmTitle: "Really sell at the market price?", icon: "arrow.up.right.circle") {
                        do { try await store.closePosition(bot); error = nil } catch { self.error = error.localizedDescription }
                    }
                }
            }
        }
    }

    private func stats(_ bot: Bot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel("Result")
            Card {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Total").font(.system(size: 10)).foregroundStyle(.secondary)
                        PnLText(value: bot.totalPnl, currency: bot.quoteCurrency, font: .system(size: 13, weight: .bold, design: .rounded))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Realized").font(.system(size: 10)).foregroundStyle(.secondary)
                        PnLText(value: bot.realizedPnl, currency: bot.quoteCurrency)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    detail("Trades", String(bot.tradesCount))
                    detail("Winners", bot.wins + bot.losses == 0 ? "–" : "\(bot.wins)/\(bot.wins + bot.losses)")
                }
            }
        }
    }

    private func parameters(_ bot: Bot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel("Rules")
            Card {
                VStack(spacing: 7) {
                    ForEach(store.strategy(bot.strategy)?.params ?? []) { param in
                        HStack {
                            Text(param.label).font(.system(size: 11)).foregroundStyle(.secondary)
                            Spacer()
                            Text(ParamFormatting.display(param, bot.params[param.key] ?? param.default, currency: bot.quoteCurrency))
                                .font(.system(size: 11, weight: .medium)).monospacedDigit()
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func recentTrades(_ bot: Bot) -> some View {
        let trades = store.trades.filter { $0.botId == bot.id }.prefix(5)
        if !trades.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                SectionLabel("Recent trades")
                Card(padding: 4) {
                    VStack(spacing: 0) {
                        ForEach(Array(trades)) { TradeRow(trade: $0) }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var activity: some View {
        if !events.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                SectionLabel("Activity")
                Card {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(events.prefix(12)) { event in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: icon(for: event.level))
                                    .font(.system(size: 10))
                                    .foregroundStyle(color(for: event.level))
                                    .frame(width: 12)
                                    .padding(.top, 1)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(event.message).font(.system(size: 10.5)).fixedSize(horizontal: false, vertical: true)
                                    Text(Date(ms: event.createdAt).formatted(date: .abbreviated, time: .shortened))
                                        .font(.system(size: 9.5)).foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func deleteSection(_ bot: Bot) -> some View {
        ConfirmButton(
            title: "Delete bot",
            confirmTitle: bot.position != nil ? "The open position stays in your account – delete anyway?" : "Really delete this bot?",
            icon: "trash",
            tint: .red
        ) {
            do {
                try await store.deleteBot(bot, force: bot.position != nil)
                open(nil)
            } catch {
                self.error = error.localizedDescription
            }
        }
        .padding(.top, 4)
    }

    private func detail(_ title: LocalizedStringKey, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 10)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 11.5, weight: .medium)).monospacedDigit().lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func icon(for level: String) -> String {
        switch level {
        case "trade": return "arrow.left.arrow.right.circle.fill"
        case "error": return "exclamationmark.triangle.fill"
        default: return "info.circle.fill"
        }
    }

    private func color(for level: String) -> Color {
        switch level {
        case "trade": return .accentColor
        case "error": return .red
        default: return .secondary
        }
    }
}

/// Button that asks for an inline confirmation (alerts are unreliable inside menu bar panels).
struct ConfirmButton: View {
    let title: LocalizedStringKey
    let confirmTitle: LocalizedStringKey
    let icon: String
    var tint: Color = .accentColor
    let action: () async -> Void
    @State private var confirming = false
    @State private var busy = false

    var body: some View {
        Group {
            if confirming {
                VStack(spacing: 6) {
                    Text(confirmTitle).font(.system(size: 11)).foregroundStyle(.secondary)
                    HStack {
                        Button("Cancel") { confirming = false }
                            .buttonStyle(.bordered)
                        Button {
                            busy = true
                            Task {
                                await action()
                                busy = false
                                confirming = false
                            }
                        } label: {
                            if busy { ProgressView().controlSize(.small) } else { Text("Confirm") }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(tint)
                    }
                    .controlSize(.small)
                }
                .frame(maxWidth: .infinity)
            } else {
                Button { confirming = true } label: {
                    Label(title, systemImage: icon)
                        .font(.system(size: 11.5, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .foregroundStyle(tint)
                        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(tint.opacity(0.1)))
                }
                .buttonStyle(.plain)
            }
        }
        .animation(.snappy(duration: 0.2), value: confirming)
    }
}
