import AppKit
import DipAgentKit
import SwiftUI

enum MainTab: String, CaseIterable, Identifiable {
    case bots, trades, settings
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
    case trade(Int, from: Int?) // from: the bot whose view it was opened in – "Back" returns there
}

struct RootView: View {
    @Environment(AppStore.self) private var store
    @State private var tab: MainTab
    @State private var route: Route?
    @State private var openedBefore = false
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
        .frame(width: 400)
        .frame(minHeight: StatusPanel.minHeight, maxHeight: .infinity) // height follows the panel (resizable at its bottom edge)
        .animation(.snappy(duration: 0.28), value: route)
        .onChange(of: route, initial: true) { _, newRoute in
            store.keepPanelOpen = newRoute == .exchangeSetup
        }
        .onChange(of: store.isVisible) { _, visible in
            // The first time the panel opens: bots when the agent is (being) connected, otherwise the settings.
            guard visible, !openedBefore else { return }
            openedBefore = true
            switch store.connection {
            case .connected, .connecting: tab = .bots
            case .notConfigured, .failed: tab = .settings
            }
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
                    case .trades: TradesView(open: navigate)
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
        case .trade(let id, let from):
            TradeDetailPage(tradeId: id, back: { navigate(from.map { .bot($0) }) })
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
    @AppStorage("confirmQuit") private var confirmQuit = true
    @State private var confirmingQuit = false
    @State private var dontAskAgain = false

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
                Button {
                    if confirmQuit {
                        withAnimation(.snappy(duration: 0.2)) { confirmingQuit.toggle() }
                    } else {
                        NSApp.terminate(nil)
                    }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(Color.primary.opacity(0.06)))
                }
                .buttonStyle(.plain)
                .help("Quit DipAgent")
            }
            if confirmingQuit {
                quitConfirmation
            }
            if showSummary, store.isConnected, let summary = store.summary {
                SummaryCard(
                    summary: summary,
                    liveAllowed: store.status?.liveTradingAllowed ?? false,
                    balances: store.balances,
                    bots: store.bots,
                    trades: store.trades,
                    limits: store.limits,
                    isDemo: store.status?.exchange == "mock",
                    showHistory: { ProfitWindow.show(store: store) }
                )
            }
        }
    }

    /// Inline confirmation (alerts are unreliable inside menu bar panels). Quitting only closes the app –
    /// the bots run on the agent and keep trading.
    private var quitConfirmation: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Quit DipAgent? The bots run on the agent and keep trading – you just won't see them or get notifications until you open the app again.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle("Don't ask again", isOn: $dontAskAgain)
                .toggleStyle(.checkbox)
                .font(.system(size: 11))
            HStack {
                Spacer()
                Button("Cancel") { withAnimation(.snappy(duration: 0.2)) { confirmingQuit = false; dontAskAgain = false } }
                    .buttonStyle(.bordered)
                Button("Quit") {
                    if dontAskAgain { confirmQuit = false }
                    NSApp.terminate(nil)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }
            .controlSize(.small)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.05)))
        .transition(.opacity.combined(with: .move(edge: .top)))
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
