import SwiftUI

/// The headline of the app: total result, today, the profit curve, the capital limit and the balance.
public struct SummaryCard: View {
    let summary: Summary
    let liveAllowed: Bool
    var balances: [Balance] = []
    var bots: [Bot] = []
    var trades: [Trade] = []
    var limits: Limits?
    var isDemo = false
    /// Opens the profit chart window; nil hides the button.
    var showHistory: (() -> Void)?
    /// Collapsed: only the total and today's result – the rest on demand.
    @AppStorage("summaryExpanded") private var expanded = false

    public init(summary: Summary, liveAllowed: Bool, balances: [Balance] = [], bots: [Bot] = [], trades: [Trade] = [],
                limits: Limits? = nil, isDemo: Bool = false, showHistory: (() -> Void)? = nil) {
        self.summary = summary
        self.liveAllowed = liveAllowed
        self.balances = balances
        self.bots = bots
        self.trades = trades
        self.limits = limits
        self.isDemo = isDemo
        self.showHistory = showHistory
    }

    public var body: some View {
        let result = summary.currencies.first
        let currency = result?.currency ?? cash.first?.currency ?? "EUR"
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(summary.mode == "live" ? "Total result (live)" : summary.mode == "paper" ? "Total result (paper)" : "Total result")
                    .font(.ui(11, weight: .medium)).foregroundStyle(.secondary)
                Spacer()
                if !expanded, let showHistory {
                    Button(action: showHistory) {
                        Image(systemName: "chart.xyaxis.line").font(.ui(11, weight: .semibold)).foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                    .help("Opens the profit chart with every buy and sale – per bot, each one can be switched on and off.")
                }
                if liveAllowed {
                    Badge(text: "LIVE", color: .profit, icon: "bolt.fill")
                        .help("Live trading is active – bots trade with real money")
                } else {
                    Badge(text: "PAPER MODE", color: .paper, icon: "testtube.2")
                        .help("All orders are only simulated. Live trading: Settings → Trading mode")
                }
                Image(systemName: "chevron.down")
                    .font(.ui(10, weight: .semibold)).foregroundStyle(.secondary)
                    .rotationEffect(.degrees(expanded ? 180 : 0))
            }
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(.snappy(duration: 0.25)) { expanded.toggle() } }
            // The headline: what DipAgent has earned or lost in total (realized + open, after fees).
            HStack(alignment: .lastTextBaseline) {
                PnLText(value: result?.total ?? 0, currency: currency, font: .ui(expanded ? 28 : 24, weight: .bold, design: .rounded), calmLosses: true)
                    .help("Realized plus open result of all bots, fees already deducted.")
                Spacer()
                if !expanded {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("Today").font(.ui(10)).foregroundStyle(.secondary)
                        PnLText(value: result?.today ?? 0, currency: currency, font: .ui(12.5, weight: .semibold, design: .rounded), calmLosses: true)
                    }
                }
            }
            if expanded {
                details(result, currency)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(
                    LinearGradient(
                        // always the neutral accent: a green tint behind green profit numbers made them hard to read
                        colors: [Color.accentColor.opacity(0.14), Color.accentColor.opacity(0.06)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
    }

    /// Everything beyond the headline – shown when the card is expanded.
    @ViewBuilder
    private func details(_ result: CurrencyTotal?, _ currency: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 0) {
                metric("Realized", result?.realized ?? 0, currency)
                metric("Open", result?.unrealized ?? 0, currency)
                metric("Today", result?.today ?? 0, currency)
            }
            ProfitSparkline(points: profitPoints(currency, realized: result?.realized), open: showHistory)

            // How much the bots may still invest under "Risk & limits" – so a new bot is not sized into the limit.
            if let limits {
                let invested = limits.invested ?? 0
                let free = max(limits.maxTotalInvested - invested, 0)
                Divider().opacity(0.4)
                infoRow("Capital limit", icon: "gauge.with.needle") {
                    VStack(alignment: .trailing, spacing: 1) {
                        if limits.maxTotalInvested > 0 {
                            Text("\(Fmt.money(free, currency)) free")
                                .font(.ui(11.5, weight: .semibold, design: .rounded)).monospacedDigit()
                                .foregroundStyle(free < 1 ? Color.orange : Color.primary)
                            Text("\(Fmt.money(invested, currency)) of \(Fmt.money(limits.maxTotalInvested, currency)) invested")
                                .font(.ui(9.5)).foregroundStyle(.secondary).monospacedDigit()
                        } else {
                            Text("No limit").font(.ui(11.5, weight: .medium)).foregroundStyle(.secondary)
                        }
                    }
                }
                .help("What the bots may still invest in total – set under Settings → Risk & limits. A buy beyond it is skipped.")
            }

            let others = otherCurrencies(except: currency)
            if !others.isEmpty {
                Divider().opacity(0.4)
                ForEach(others, id: \.self) { other in
                    HStack(spacing: 8) {
                        Text(other).font(.ui(10.5, weight: .semibold)).foregroundStyle(.secondary)
                        Spacer()
                        if let balance = cash.first(where: { $0.currency == other }) {
                            Text(Fmt.money(balance.total + positionsValue(other), other))
                                .font(.ui(11, weight: .medium, design: .rounded))
                                .monospacedDigit().foregroundStyle(.secondary)
                        }
                        if let result = summary.currencies.first(where: { $0.currency == other }) {
                            PnLText(value: result.total, currency: other, font: .ui(11, weight: .semibold), calmLosses: true)
                        }
                    }
                }
            }

            Divider().opacity(0.4)
            HStack(spacing: 12) {
                Label("\(String(summary.botsActive))/\(String(summary.botsTotal)) bots active", systemImage: "cpu")
                Label("\(openPositionsText) open", systemImage: "tray.full")
                Label("\(String(summary.tradesCount)) trades", systemImage: "arrow.left.arrow.right")
                Spacer(minLength: 0)
                // Fees are already part of the result – just a footnote
                Text("\(Fmt.money(fees(currency), currency)) fees")
                    .foregroundStyle(.tertiary)
                    .help("Exchange fees of all buys and sells – already included in the result.")
            }
            .font(.ui(10.5))
            .foregroundStyle(.secondary)
            .labelStyle(CompactLabelStyle())

            // Paper and live are kept apart: the other mode's result is only a footnote
            if let mode = summary.mode, let other = summary.otherMode?.first(where: { $0.currency == currency }),
               (summary.otherModeTrades ?? 0) > 0 || abs(other.total) >= 0.005 {
                Text(mode == "live" ? "Paper result: \(Fmt.money(other.total, currency, signed: true))"
                                     : "Live result: \(Fmt.money(other.total, currency, signed: true))")
                    .font(.ui(10)).foregroundStyle(.tertiary).monospacedDigit()
                    .help("Result of the other trading mode – not part of the numbers above.")
            }
            // The exchange balance is not DipAgent's result – just a footnote
            if let balance = cash.first(where: { $0.currency == currency }) {
                let positions = positionsValue(currency)
                Text("\(balanceTitle): \(Fmt.money(balance.total + positions, currency)) · \(Fmt.money(balance.available, currency)) available")
                    .font(.ui(10)).foregroundStyle(.tertiary).monospacedDigit()
                    .help("Cash on the exchange plus the current value of all open live positions.")
            }
        }
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private var balanceTitle: String { isDemo ? String(localized: "Balance (demo)") : String(localized: "Balance on Revolut X") }

    /// Spendable cash (fiat and the bots' quote currencies) – coins held in positions are not included.
    private var cash: [Balance] {
        let quotes = summary.currencies.map(\.currency)
        let fiat: Set<String> = ["EUR", "USD", "GBP", "CHF", "PLN"]
        return balances
            .filter { quotes.contains($0.currency) || fiat.contains($0.currency) }
            .sorted { (quotes.firstIndex(of: $0.currency) ?? .max, $0.currency) < (quotes.firstIndex(of: $1.currency) ?? .max, $1.currency) }
    }

    /// Fees paid in this currency – from the agent's summary, or summed from the loaded trades with older agents.
    private func fees(_ currency: String) -> Double {
        if let fees = summary.currencies.first(where: { $0.currency == currency })?.fees { return fees }
        return trades.filter { $0.quote == currency }.reduce(0) { $0 + $1.fee }
    }

    /// The realized result over time for the small curve. The panel only loads the latest trades, so the curve is
    /// lifted by the result of the older ones – it then ends at the realized total above.
    private func profitPoints(_ currency: String, realized: Double?) -> [ProfitPoint] {
        let relevant = trades.filter { $0.quote == currency && (summary.mode == nil || $0.paper == (summary.mode == "paper")) }
        let loaded = relevant.reduce(0) { $0 + ($1.pnl ?? 0) }
        return ProfitCurve.points(relevant, offset: (realized ?? loaded) - loaded)
    }

    /// Current market value of the positions that really sit on the exchange (paper positions are only simulated).
    private func positionsValue(_ currency: String) -> Double {
        bots.filter { $0.quoteCurrency == currency }
            .compactMap(\.position)
            .filter { $0.paper != true }
            .reduce(0) { $0 + $1.value }
    }

    /// Other currencies with a balance or a result, in the order of the summary.
    private func otherCurrencies(except main: String) -> [String] {
        var seen: [String] = []
        for code in summary.currencies.map(\.currency) + cash.map(\.currency) where code != main && !seen.contains(code) {
            seen.append(code)
        }
        return seen
    }

    /// "2/3" when a position limit is set, otherwise "2".
    private var openPositionsText: String {
        guard let max = summary.maxOpenPositions, max > 0 else { return String(summary.openPositions) }
        return "\(summary.openPositions)/\(max)"
    }

    private func metric(_ title: LocalizedStringKey, _ value: Double, _ currency: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.ui(10)).foregroundStyle(.secondary)
            PnLText(value: value, currency: currency, font: .ui(12.5, weight: .semibold, design: .rounded), calmLosses: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func infoRow<Content: View>(_ title: LocalizedStringKey, icon: String, @ViewBuilder value: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Label(title, systemImage: icon)
                .font(.ui(10.5))
                .foregroundStyle(.secondary)
                .labelStyle(CompactLabelStyle())
            Spacer()
            value()
        }
    }
}
