import DipAgentKit
import SwiftUI

/// Global switch between paper mode (default) and live trading on Revolut X.
/// Switching on needs two explicit confirmations; switching off warns that all live positions get sold.
struct LiveTradingSection: View {
    enum Step { case idle, warning, finalConfirmation, disableWarning }

    @Environment(AppStore.self) private var store
    @State private var step: Step
    @State private var understood = false
    @State private var busy = false
    @State private var error: String?
    @State private var info: String?

    init(initialStep: Step = .idle) {
        _step = State(initialValue: initialStep)
    }

    private var live: Bool { store.status?.liveTradingAllowed ?? false }
    private var exchangeReady: Bool { store.exchangeInfo?.connected == true }
    /// Bots with a simulated position that is still open – it keeps being simulated until it is sold.
    private var openPaperPositions: [Bot] { store.bots.filter { $0.position?.paper == true } }
    private var liveBotsWithPosition: [Bot] { store.bots.filter { $0.position?.paper == false } }
    private var openLivePositions: Int { liveBotsWithPosition.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel("Trading mode")
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        IconTile(
                            symbol: live ? "bolt.fill" : "testtube.2",
                            colors: live ? [.red, .orange] : [.orange, .yellow],
                            size: 30
                        )
                        VStack(alignment: .leading, spacing: 2) {
                            (live ? Text("Live trading active") : Text("Paper mode (demo)"))
                                .font(.system(size: 12.5, weight: .semibold))
                            (live ? Text("Real orders with real money on Revolut X") : Text("Real prices, orders are only simulated"))
                                .font(.system(size: 10.5)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if busy {
                            ProgressView().controlSize(.small)
                        } else {
                            Toggle("", isOn: toggleBinding)
                                .toggleStyle(.switch)
                                .labelsHidden()
                                .tint(.red)
                                .disabled(!live && !exchangeReady)
                        }
                    }

                    if !live && !exchangeReady && step == .idle {
                        note("Connect Revolut X first – then live trading can be switched on.", icon: "link")
                    }

                    switch step {
                    case .idle: EmptyView()
                    case .warning: warning
                    case .finalConfirmation: finalConfirmation
                    case .disableWarning: disableWarning
                    }

                    if live && step == .idle {
                        note("When switching back to paper mode, all open live positions are sold immediately.", icon: "info.circle")
                    } else if !live && openLivePositions > 0 {
                        note("\(String(openLivePositions)) live position(s) could not be sold and are still managed live – sell them manually in the bot view.", icon: "exclamationmark.circle")
                    }

                    if let info {
                        Label(info, systemImage: "checkmark.circle.fill")
                            .font(.system(size: 10.5)).foregroundStyle(.green)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if let error {
                        Label(error, systemImage: "xmark.octagon.fill")
                            .font(.system(size: 10.5)).foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .animation(.snappy(duration: 0.2), value: step)
    }

    // MARK: Confirmation steps

    /// 1st confirmation: explain consequences, require an explicit acknowledgement.
    private var warning: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("1/2 · Attention: real money", systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.orange)
            if store.bots.isEmpty {
                bullet("All bots you create afterwards buy and sell with your real balance on Revolut X.")
            } else {
                bullet("All existing bots are switched to live as well and then trade with your real balance on Revolut X: \(store.bots.map(\.name).joined(separator: ", ")).")
                bullet("If a bot should not trade with real money, you have to delete it first (Bots tab).", emphasized: true)
            }
            if !openPaperPositions.isEmpty {
                bullet("Open paper positions (\(openPaperPositions.map(\.name).joined(separator: ", "))) are still sold simulated, afterwards the bot buys live.")
            }
            bullet("Losses are possible. “Risk & limits” caps open positions and capital.")
            Toggle(isOn: $understood) {
                Text("I understand that real money is used.")
                    .font(.system(size: 11, weight: .medium))
            }
            .toggleStyle(.checkbox)
            HStack {
                Spacer()
                Button("Cancel", action: cancel).controlSize(.small)
                Button("Continue") { step = .finalConfirmation }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    .controlSize(.small)
                    .disabled(!understood)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.orange.opacity(0.1)))
    }

    /// 2nd confirmation: final, explicit button.
    private var finalConfirmation: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("2/2 · Final confirmation", systemImage: "bolt.trianglebadge.exclamationmark.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.red)
            Group {
                if store.bots.isEmpty {
                    Text("Enable live trading now? Bots place real orders from the next buy signal on.")
                } else if store.bots.count == 1 {
                    Text("Enable live trading now? Your bot is switched to live and places real orders from the next buy signal on.")
                } else {
                    Text("Enable live trading now? All \(String(store.bots.count)) bots are switched to live and place real orders from the next buy signal on.")
                }
            }
                .font(.system(size: 11))
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel", action: cancel).controlSize(.small)
                Button("Yes, enable live trading") { Task { await setLive(true) } }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .controlSize(.small)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.red.opacity(0.1)))
    }

    /// Switching back to paper: all open live positions are sold at market price.
    private var disableWarning: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Back to paper mode", systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.orange)
            if liveBotsWithPosition.isEmpty {
                bullet("No live position is open right now – nothing will be sold.")
            } else {
                bullet("All open live trades are closed immediately, i.e. sold at the current market price on Revolut X:", emphasized: true)
                ForEach(liveBotsWithPosition) { bot in
                    if let position = bot.position {
                        HStack(spacing: 6) {
                            Text(bot.name).font(.system(size: 10.5, weight: .medium))
                            Text(verbatim: "\(Fmt.qty(position.qty)) \(bot.baseCurrency)").font(.system(size: 10.5)).foregroundStyle(.secondary)
                            Spacer()
                            PnLText(value: position.unrealizedPnl, currency: bot.quoteCurrency, font: .system(size: 10.5, weight: .semibold))
                        }
                        .padding(.leading, 14)
                    }
                }
                bullet("This locks in the result – even if a position is currently at a loss.")
            }
            bullet("Afterwards all bots only trade simulated (paper).")
            HStack {
                Spacer()
                Button("Cancel", action: cancel).controlSize(.small)
                Button(liveBotsWithPosition.isEmpty ? LocalizedStringKey("Switch to paper mode") : LocalizedStringKey("Sell everything & paper mode")) {
                    Task { await setLive(false) }
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .controlSize(.small)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.orange.opacity(0.1)))
    }

    // MARK: Logic

    private var toggleBinding: Binding<Bool> {
        Binding(
            get: { step == .disableWarning ? false : (live || step != .idle) },
            set: { on in
                error = nil
                info = nil
                if on && live {
                    cancel() // user changed their mind while the "back to paper" warning was shown
                } else if on {
                    understood = false
                    step = .warning
                } else if live {
                    step = .disableWarning // warn first: all live positions will be sold
                } else {
                    cancel()
                }
            }
        )
    }

    private func cancel() {
        step = .idle
        understood = false
    }

    private func setLive(_ enabled: Bool) async {
        busy = true
        error = nil
        do {
            let closed = try await store.setLiveTrading(enabled)
            cancel()
            let failed = closed.filter { !$0.ok }
            if !failed.isEmpty {
                error = failed.map { "\($0.botName): \($0.message)" }.joined(separator: "\n")
            } else if !closed.isEmpty {
                info = String(localized: "\(String(closed.count)) live position(s) sold. All bots now trade in paper mode.")
            }
        } catch {
            self.error = error.localizedDescription
        }
        busy = false
    }

    private func bullet(_ text: LocalizedStringKey, emphasized: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("•").font(.system(size: 11)).foregroundStyle(.secondary)
            Text(text)
                .font(.system(size: 10.5, weight: emphasized ? .semibold : .regular))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func note(_ text: LocalizedStringKey, icon: String) -> some View {
        Label(text, systemImage: icon)
            .font(.system(size: 10.5))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
