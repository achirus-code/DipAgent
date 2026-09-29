import SwiftUI

/// How the bot list is ordered (within "Active" and "Stopped").
enum BotSort: String, CaseIterable, Identifiable {
    case running, result, name, newest
    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .running: return "Running first"
        case .result: return "Result"
        case .name: return "Name"
        case .newest: return "Newest"
        }
    }

    /// Stable: bots that compare equal keep their order from the agent.
    func apply(_ bots: [Bot]) -> [Bot] {
        let indexed = bots.enumerated().map { ($0.offset, $0.element) }
        let sorted: [(Int, Bot)]
        switch self {
        case .running:
            sorted = indexed.sorted { ($0.1.position == nil ? 1 : 0, $0.0) < ($1.1.position == nil ? 1 : 0, $1.0) }
        case .result:
            sorted = indexed.sorted { ($0.1.totalPnl, -$0.0) > ($1.1.totalPnl, -$1.0) }
        case .name:
            sorted = indexed.sorted { ($0.1.name.localizedCaseInsensitiveCompare($1.1.name), $0.0) < (.orderedSame, $1.0) }
        case .newest:
            sorted = indexed.sorted { ($0.1.createdAt, -$0.0) > ($1.1.createdAt, -$1.0) }
        }
        return sorted.map(\.1)
    }
}

extension ComparisonResult: @retroactive Comparable {
    public static func < (lhs: ComparisonResult, rhs: ComparisonResult) -> Bool { lhs.rawValue < rhs.rawValue }
}

struct BotsView: View {
    @Environment(AppStore.self) private var store
    let open: (Route?) -> Void
    @AppStorage("botSort") private var sortKey = BotSort.running.rawValue

    private var sort: BotSort { BotSort(rawValue: sortKey) ?? .running }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !store.isConnected {
                EmptyStateView(icon: "bolt.horizontal.circle", title: "Not connected", message: "Connect the app to your agent in the settings.")
            } else {
                SectionLabel("My bots", trailing: store.bots.count > 1 ? AnyView(sortMenu) : nil)
                if store.bots.isEmpty {
                    EmptyStateView(icon: "cpu", title: "No bots yet", message: "Create your first bot – e.g. a dip buyer for ETH-EUR.")
                } else {
                    let active = sort.apply(store.bots.filter(\.enabled))
                    let stopped = sort.apply(store.bots.filter { !$0.enabled })
                    if !active.isEmpty {
                        BotGroupLabel(title: "Active", count: active.count, color: .green)
                        ForEach(active) { bot in
                            BotCard(bot: bot, open: open)
                        }
                    }
                    if !stopped.isEmpty {
                        BotGroupLabel(title: "Stopped", count: stopped.count, color: .gray)
                            .padding(.top, active.isEmpty ? 0 : 6)
                        ForEach(stopped) { bot in
                            BotCard(bot: bot, open: open)
                        }
                    }
                }
                newBotButton
            }
        }
        .animation(.snappy(duration: 0.25), value: store.bots.map(\.enabled))
        .animation(.snappy(duration: 0.25), value: sortKey)
    }

    /// Below the list: a quiet, full-width "+ New bot" in the look of the cards.
    private var newBotButton: some View {
        Button { open(.editor(nil)) } label: {
            Label("New bot", systemImage: "plus")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.accentColor.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, 2)
    }

    /// Compact, borderless: "⇅ Result ⌄" in the section header.
    private var sortMenu: some View {
        Menu {
            Picker("Sort by", selection: $sortKey) {
                ForEach(BotSort.allCases) { option in
                    Text(option.title).tag(option.rawValue)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "arrow.up.arrow.down").font(.system(size: 9, weight: .semibold))
                Text(sort.title).font(.system(size: 11, weight: .medium))
                Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold))
            }
            .foregroundStyle(.secondary)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Sort bots")
    }
}

/// "● Active · 3" – separates running bots from stopped ones in the list.
struct BotGroupLabel: View {
    let title: LocalizedStringKey
    let count: Int
    let color: Color

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(title).font(.system(size: 11, weight: .semibold))
            Text(verbatim: String(count))
                .font(.system(size: 10, weight: .semibold)).monospacedDigit()
                .foregroundStyle(.secondary)
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(Capsule().fill(Color.primary.opacity(0.07)))
            Spacer()
        }
        .padding(.horizontal, 4)
    }
}

struct BotCard: View {
    @Environment(AppStore.self) private var store
    let bot: Bot
    let open: (Route?) -> Void
    @State private var hovering = false
    @State private var confirmingDelete = false
    @State private var asking = false
    @State private var confirmingAsk = false
    @State private var error: String?

    var body: some View {
        // Stopped bots get a compact, dimmed card: no market line and no status line – the group header
        // already says "Stopped". Result and an open position stay visible, they still matter.
        Card {
            VStack(alignment: .leading, spacing: bot.enabled ? 10 : 8) {
                HStack(spacing: 10) {
                    IconTile(symbol: bot.strategyIcon, colors: strategyColors(bot.strategy), size: bot.enabled ? 34 : 28)
                        .grayscale(bot.enabled ? 0 : 1)
                        .opacity(bot.enabled ? 1 : 0.55)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 5) {
                            Text(bot.name)
                                .font(.system(size: bot.enabled ? 13 : 12.5, weight: .semibold))
                                .foregroundStyle(bot.enabled ? Color.primary : Color.secondary)
                                .lineLimit(1)
                            if bot.paper { Badge(text: "PAPER", color: .orange) } else { Badge(text: "LIVE", color: .green, icon: "bolt.fill") }
                        }
                        Text(verbatim: "\(bot.symbol) · \(bot.strategyName)")
                            .font(.system(size: 10.5)).foregroundStyle(.secondary)
                    }
                    .opacity(bot.enabled ? 1 : 0.8)
                    Spacer()
                    if !bot.enabled {
                        PnLText(value: bot.totalPnl, currency: bot.quoteCurrency, font: .system(size: 12, weight: .semibold, design: .rounded))
                            .opacity(0.8)
                    }
                    RunToggle(bot: bot)
                }

                if bot.enabled {
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
                    if bot.strategy == "ai" {
                        HStack(spacing: 6) {
                            Spacer(minLength: 0)
                            // a fresh decision right now – one extra Claude call
                            Button {
                                withAnimation { confirmingAsk = true; confirmingDelete = false; error = nil }
                            } label: {
                                Group {
                                    if asking {
                                        ProgressView().controlSize(.mini)
                                    } else {
                                        Image(systemName: "brain")
                                            .font(.system(size: 10, weight: .medium))
                                    }
                                }
                                .frame(width: 22, height: 22)
                                .background(Circle().fill(Color.accentColor.opacity(0.12)))
                                .foregroundStyle(Color.accentColor)
                            }
                            .buttonStyle(.plain)
                            .disabled(asking || confirmingAsk || bot.pendingOrder)
                            .help("Ask Claude now – a fresh decision right away (costs one check)")
                            Button { open(.bot(bot.id)) } label: {
                                Label("Decisions", systemImage: "sparkles")
                                    .font(.system(size: 10.5, weight: .medium))
                                    .padding(.horizontal, 8).padding(.vertical, 4)
                                    .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                                    .foregroundStyle(Color.accentColor)
                            }
                            .buttonStyle(.plain)
                            .help("Claude's answers and how sure it was")
                        }
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if let position = bot.position {
                    PositionStrip(bot: bot, position: position)
                }

                if confirmingDelete {
                    deleteConfirmation
                }
                if confirmingAsk {
                    askConfirmation
                }
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 10.5)).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(hovering ? 0.35 : 0), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture { open(.bot(bot.id)) }
        .contextMenu {
            Button { open(.editor(bot.id)) } label: { Label("Edit", systemImage: "pencil") }
            Button {
                Task { try? await store.setRunning(bot, !bot.enabled) }
            } label: {
                bot.enabled ? Label("Stop bot", systemImage: "pause.circle") : Label("Start bot", systemImage: "play.circle")
            }
            Divider()
            Button(role: .destructive) { withAnimation { confirmingDelete = true; error = nil } } label: {
                Label("Delete bot", systemImage: "trash")
            }
        }
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .animation(.snappy(duration: 0.2), value: confirmingDelete)
    }

    /// Inline confirmation (alerts are unreliable inside menu bar panels) – the same wording as in the bot view.
    /// Every extra check costs money – ask before calling Claude.
    private var askConfirmation: some View {
        VStack(spacing: 6) {
            Text("Ask Claude for a fresh decision now? This costs one extra check.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Cancel") { withAnimation { confirmingAsk = false } }
                    .buttonStyle(.bordered)
                Button("Ask Claude") {
                    withAnimation { confirmingAsk = false }
                    asking = true
                    Task {
                        do { try await store.askClaude(bot) } catch { self.error = error.localizedDescription }
                        asking = false
                    }
                }
                .buttonStyle(.borderedProminent)
            }
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity)
    }

    private var deleteConfirmation: some View {
        VStack(spacing: 6) {
            Text(bot.position != nil ? "The open position stays in your account – delete anyway?" : "Really delete this bot?")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Cancel") { confirmingDelete = false }
                    .buttonStyle(.bordered)
                Button("Delete bot") {
                    Task {
                        do { try await store.deleteBot(bot, force: bot.position != nil) } catch { self.error = error.localizedDescription }
                        confirmingDelete = false
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity)
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
            VStack(alignment: .leading, spacing: 3) {
                Text(statusText)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if bot.enabled, let hint = bot.hint {
                    Label(hint, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
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
    @State private var decisions: [AiDecision] = []
    @State private var error: String?
    /// "Sell position now" failed – only then the escape hatch "discard without a sale" is offered.
    @State private var sellFailed = false

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
                        if bot.strategy == "ai" { claudeDecisions }
                        parameters(bot)
                        recentTrades(bot)
                        activity
                        deleteSection(bot)
                    }
                    .padding(14)
                }
                .scrollIndicators(.never)
            }
            .task(id: store.lastUpdate) {
                events = await store.events(for: botId)
                if bot.strategy == "ai" { decisions = await store.decisions(for: botId) }
            }
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
                            if bot.paper { Badge(text: "PAPER", color: .orange) } else { Badge(text: "LIVE", color: .green, icon: "bolt.fill") }
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
                        do { try await store.closePosition(bot); error = nil; sellFailed = false } catch {
                            self.error = error.localizedDescription
                            sellFailed = true
                        }
                    }
                    if sellFailed {
                        // the sale didn't go through – for a position that is wrong in the books (e.g. after a
                        // short-reported fill) the way out is to forget it without selling
                        ConfirmButton(title: "Discard position (no sale)", confirmTitle: "Remove the position from the books without selling? Coins on the exchange stay there.", icon: "xmark.bin", tint: .orange) {
                            do { try await store.discardPosition(bot); error = nil; sellFailed = false } catch { self.error = error.localizedDescription }
                        }
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

    /// Claude's answers over time: action, how sure it was (the score) and why.
    private var claudeDecisions: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel("Claude's decisions", trailing: decisions.isEmpty ? nil : AnyView(
                Text("\(String(decisions.count)) · Ø \(String(decisions.map(\.confidence).reduce(0, +) / max(decisions.count, 1))) % sure")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            ))
            Card {
                if decisions.isEmpty {
                    Text("No answers yet – Claude is asked at the next check.")
                        .font(.system(size: 10.5)).foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(decisions.prefix(30)) { decision in
                            DecisionRow(decision: decision, currency: quoteCurrency)
                        }
                    }
                }
            }
        }
    }

    private var quoteCurrency: String { store.bots.first { $0.id == botId }?.quoteCurrency ?? "EUR" }

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

/// One of Claude's answers: action badge, confidence bar, reason, price and time.
struct DecisionRow: View {
    let decision: AiDecision
    let currency: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Badge(text: actionText, color: actionColor, icon: actionIcon)
                ConfidenceBar(value: decision.confidence, color: actionColor)
                Text(verbatim: "\(decision.confidence) %")
                    .font(.system(size: 10.5, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(actionColor)
                Spacer()
                Text(Date(ms: decision.createdAt).formatted(date: .abbreviated, time: .shortened))
                    .font(.system(size: 9.5)).foregroundStyle(.tertiary)
            }
            Text(decision.reason)
                .font(.system(size: 10.5))
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Text(Fmt.price(decision.price, currency)).monospacedDigit()
                if let profit = decision.profitPct {
                    Text(verbatim: "·")
                    Text(Fmt.pct(profit)).foregroundStyle(profit.pnlColor).monospacedDigit()
                }
            }
            .font(.system(size: 9.5)).foregroundStyle(.secondary)
        }
    }

    private var actionText: LocalizedStringKey {
        switch decision.action {
        case "buy": return "BUY"
        case "sell": return "SELL"
        case "hold": return "HOLD"
        default: return "WAIT"
        }
    }

    private var actionColor: Color {
        switch decision.action {
        case "buy": return .green
        case "sell": return .orange
        case "hold": return .blue
        default: return .gray
        }
    }

    private var actionIcon: String {
        switch decision.action {
        case "buy": return "arrow.down.circle.fill"
        case "sell": return "arrow.up.circle.fill"
        case "hold": return "hand.raised.fill"
        default: return "clock.fill"
        }
    }
}

/// 0–100 as a thin bar – the "score" of a decision.
struct ConfidenceBar: View {
    let value: Int
    let color: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule().fill(color.opacity(0.8)).frame(width: geo.size.width * CGFloat(max(0, min(value, 100))) / 100)
            }
        }
        .frame(width: 60, height: 5)
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
