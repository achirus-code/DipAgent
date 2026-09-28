import SwiftUI

enum MainTab: String, CaseIterable, Identifiable {
    case trades, bots, settings
    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .trades: return "Trades"
        case .bots: return "Bots"
        case .settings: return "Settings"
        }
    }

    var icon: String {
        switch self {
        case .trades: return "arrow.left.arrow.right"
        case .bots: return "cpu"
        case .settings: return "gearshape"
        }
    }
}

enum Route: Equatable {
    case bot(Int)
    case editor(Int?) // nil = new bot
    case exchangeSetup
}

struct RootView: View {
    @Environment(AppStore.self) private var store
    @State private var tab: MainTab
    @State private var route: Route?
    @Namespace private var tabNamespace

    init(initialTab: MainTab = .bots, initialRoute: Route? = nil) {
        _tab = State(initialValue: initialTab)
        _route = State(initialValue: initialRoute)
    }

    var body: some View {
        ZStack {
            if let route {
                page(for: route)
                    .transition(.asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .trailing)).combined(with: .opacity))
            } else {
                main
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .frame(width: 400, height: 620)
        .animation(.snappy(duration: 0.28), value: route)
        .onChange(of: route, initial: true) { _, newRoute in
            store.keepPanelOpen = newRoute == .exchangeSetup
        }
        .onAppear {
            if case .notConfigured = store.connection { tab = .settings }
        }
    }

    private var main: some View {
        VStack(spacing: 0) {
            HeaderView(showSummary: tab != .settings)
                .padding(.horizontal, 14)
                .padding(.top, 14)
                .padding(.bottom, 10)
            tabBar
                .padding(.horizontal, 14)
                .padding(.bottom, 10)
            Divider().opacity(0.5)
            ScrollView {
                Group {
                    switch tab {
                    case .trades: TradesView()
                    case .bots: BotsView(open: navigate)
                    case .settings: SettingsView(open: navigate)
                    }
                }
                .padding(14)
            }
            .scrollIndicators(.never)
        }
    }

    @ViewBuilder
    private func page(for route: Route) -> some View {
        switch route {
        case .bot(let id):
            BotDetailView(botId: id, open: navigate)
        case .exchangeSetup:
            ExchangeSetupView(close: { navigate(nil) })
        case .editor(let id):
            BotEditorView(bot: id.flatMap { id in store.bots.first { $0.id == id } }, close: { savedId in
                if let savedId, id == nil { navigate(.bot(savedId)) } else { navigate(id.map { .bot($0) }) }
            })
        }
    }

    private func navigate(_ target: Route?) {
        route = target
    }

    private var tabBar: some View {
        HStack(spacing: 4) {
            ForEach(MainTab.allCases) { item in
                Button {
                    withAnimation(.snappy(duration: 0.25)) { tab = item }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: item.icon).font(.system(size: 11, weight: .semibold))
                        Text(item.title).font(.system(size: 12, weight: .medium))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .foregroundStyle(tab == item ? Color.primary : Color.secondary)
                    .background {
                        if tab == item {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(.background.opacity(0.9))
                                .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
                                .matchedGeometryEffect(id: "tab", in: tabNamespace)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.06)))
    }
}

// MARK: - Header

struct HeaderView: View {
    @Environment(AppStore.self) private var store
    var showSummary = true

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                IconTile(symbol: "chart.line.uptrend.xyaxis", size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text("DipAgent").font(.system(size: 14, weight: .bold, design: .rounded))
                    HStack(spacing: 5) {
                        Circle().fill(statusColor).frame(width: 6, height: 6)
                        Text(statusText).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer()
                Button {
                    Task { await store.isConnected ? store.refresh() : store.connect() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .semibold))
                        .rotationEffect(.degrees(store.isRefreshing ? 360 : 0))
                        .animation(store.isRefreshing ? .linear(duration: 0.8).repeatForever(autoreverses: false) : .default, value: store.isRefreshing)
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(Color.primary.opacity(0.06)))
                }
                .buttonStyle(.plain)
                .help("Refresh")
            }
            if showSummary, store.isConnected, let summary = store.summary {
                SummaryCard(
                    summary: summary,
                    liveAllowed: store.status?.liveTradingAllowed ?? false,
                    balances: store.balances,
                    isDemo: store.status?.exchange == "mock"
                )
            }
        }
    }

    private var statusColor: Color {
        switch store.connection {
        case .connected:
            if store.status?.engineError != nil { return .red }
            return store.status?.exchangeOk == false ? .orange : .green
        case .connecting: return .yellow
        case .failed: return .red
        case .notConfigured: return .gray
        }
    }

    private var statusText: String {
        switch store.connection {
        case .connected:
            if let engineError = store.status?.engineError { return engineError }
            if let status = store.status, !status.exchangeOk {
                let error = status.exchangeError ?? String(localized: "no data")
                return String(localized: "Agent connected · Exchange: \(error)")
            }
            return store.status?.exchange == "mock"
                ? String(localized: "Connected · Demo market")
                : String(localized: "Connected · Revolut X")
        case .connecting: return String(localized: "Connecting …")
        case .failed(let message): return message
        case .notConfigured: return String(localized: "Not connected")
        }
    }
}

struct SummaryCard: View {
    let summary: Summary
    let liveAllowed: Bool
    var balances: [Balance] = []
    var isDemo = false

    var body: some View {
        let main = summary.currencies.first
        let currency = main?.currency ?? "EUR"
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Total result").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                Spacer()
                if liveAllowed {
                    Badge(text: "LIVE", color: .red, icon: "bolt.fill")
                        .help("Live trading is active – bots trade with real money")
                } else {
                    Badge(text: "PAPER MODE", color: .orange, icon: "testtube.2")
                        .help("All orders are only simulated. Live trading: Settings → Trading mode")
                }
            }
            PnLText(value: main?.total ?? 0, currency: currency, font: .system(size: 28, weight: .bold, design: .rounded))
            HStack(spacing: 0) {
                metric("Realized", main?.realized ?? 0, currency)
                metric("Open", main?.unrealized ?? 0, currency)
                metric("Today", main?.today ?? 0, currency)
            }
            ForEach(summary.currencies.dropFirst()) { other in
                HStack {
                    Text(other.currency).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.secondary)
                    Spacer()
                    PnLText(value: other.total, currency: other.currency, font: .system(size: 11, weight: .semibold))
                }
            }
            Divider().opacity(0.4)
            if !cash.isEmpty {
                HStack(alignment: .firstTextBaseline) {
                    Label(balanceTitle, systemImage: "banknote")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .labelStyle(CompactLabelStyle())
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        ForEach(cash) { balance in
                            Text(Fmt.money(balance.available, balance.currency))
                                .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(balance.available > 0 ? Color.green : Color.secondary)
                                .help("Available now · \(Fmt.money(balance.total, balance.currency)) in total")
                        }
                    }
                }
            }
            HStack(spacing: 12) {
                Label("\(String(summary.botsActive))/\(String(summary.botsTotal)) bots active", systemImage: "cpu")
                Label("\(openPositionsText) open", systemImage: "tray.full")
                Label("\(String(summary.tradesCount)) trades", systemImage: "arrow.left.arrow.right")
            }
            .font(.system(size: 10.5))
            .foregroundStyle(.secondary)
            .labelStyle(CompactLabelStyle())
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [(main?.total ?? 0).pnlColor.opacity(0.16), Color.accentColor.opacity(0.06)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
    }

    private var balanceTitle: LocalizedStringKey { isDemo ? "Balance (demo)" : "Balance on Revolut X" }

    /// Spendable cash (fiat and the bots' quote currencies) – coins held in positions are not included.
    private var cash: [Balance] {
        let quotes = summary.currencies.map(\.currency)
        let fiat: Set<String> = ["EUR", "USD", "GBP", "CHF", "PLN"]
        return balances
            .filter { quotes.contains($0.currency) || fiat.contains($0.currency) }
            .sorted { (quotes.firstIndex(of: $0.currency) ?? .max, $0.currency) < (quotes.firstIndex(of: $1.currency) ?? .max, $1.currency) }
    }

    /// "2/3" when a position limit is set, otherwise "2".
    private var openPositionsText: String {
        guard let max = summary.maxOpenPositions, max > 0 else { return String(summary.openPositions) }
        return "\(summary.openPositions)/\(max)"
    }

    private func metric(_ title: LocalizedStringKey, _ value: Double, _ currency: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 10)).foregroundStyle(.secondary)
            PnLText(value: value, currency: currency, font: .system(size: 12.5, weight: .semibold, design: .rounded))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct CompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.font(.system(size: 9))
            configuration.title
        }
    }
}
