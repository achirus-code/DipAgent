import DipAgentKit
import SwiftUI

/// Pages pushed onto a tab's navigation stack.
enum Route: Hashable {
    case bot(Int)
    case trade(Int)
    case history
}

/// Not connected yet: one screen to enter the agent. Afterwards the three tabs.
struct RootView: View {
    @Environment(AppStore.self) private var store
    /// Set once the first connection worked; "Disconnect" in the settings resets it.
    @AppStorage("onboarded") private var onboarded = false

    var body: some View {
        if onboarded && store.isConfigured {
            MainView()
        } else {
            ConnectView(connected: { onboarded = true })
        }
    }
}

struct MainView: View {
    var body: some View {
        TabView {
            BotsTab()
                .tabItem { Label("Bots", systemImage: "cpu") }
            TradesTab()
                .tabItem { Label("Trades", systemImage: "arrow.left.arrow.right") }
            SettingsTab()
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
    }
}

/// The destinations every tab can push – a bot, a trade, the profit chart.
struct RouteDestinations: ViewModifier {
    func body(content: Content) -> some View {
        content.navigationDestination(for: Route.self) { route in
            switch route {
            case .bot(let id): BotDetailView(botId: id)
            case .trade(let id): TradeDetailScreen(tradeId: id)
            case .history: ProfitHistoryScreen()
            }
        }
    }
}

extension View {
    func routeDestinations() -> some View { modifier(RouteDestinations()) }
}

// MARK: - Connect

struct ConnectView: View {
    @Environment(AppStore.self) private var store
    let connected: () -> Void

    @State private var server = ""
    @State private var token = ""
    @State private var showToken = false
    @State private var trying = false
    @FocusState private var focus: Field?

    private enum Field { case server, token }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(spacing: 10) {
                        IconTile(symbol: "chart.line.uptrend.xyaxis", size: 64)
                        Text(verbatim: "DipAgent").font(.title.bold())
                        Text("Connect the app to your agent.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .listRowBackground(Color.clear)
                }

                Section {
                    TextField("Address, e.g. 192.168.1.10", text: $server)
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focus, equals: .server)
                        .submitLabel(.next)
                        .onSubmit { focus = .token }
                    HStack {
                        Group {
                            if showToken { TextField("API token", text: $token) } else { SecureField("API token", text: $token) }
                        }
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focus, equals: .token)
                        .submitLabel(.go)
                        .onSubmit(connect)
                        Button { showToken.toggle() } label: {
                            Image(systemName: showToken ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                    }
                } footer: {
                    Text("Port \(String(APIClient.defaultPort)) is added automatically. The token is in the agent's .env file or in its log. Away from home, reach the agent through a VPN such as Tailscale.")
                }

                Section {
                    Button(action: connect) {
                        HStack {
                            Spacer()
                            if trying { ProgressView().padding(.trailing, 4) }
                            Text("Connect").bold()
                            Spacer()
                        }
                    }
                    .disabled(server.trimmingCharacters(in: .whitespaces).isEmpty || token.trimmingCharacters(in: .whitespaces).isEmpty || trying)
                } footer: {
                    if case .failed(let message) = store.connection, !trying {
                        Label(message, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                    }
                }
            }
        }
        .onAppear {
            server = store.serverURL
            token = store.token
        }
        // the agent was unreachable at first and the app kept trying – go on once it answers
        .onChange(of: store.isConnected) { _, isConnected in
            if isConnected, !trying { connected() }
        }
    }

    private func connect() {
        focus = nil
        trying = true
        Task {
            await store.saveConnection(server: server, token: token)
            trying = false
            if store.isConnected { connected() }
        }
    }
}

// MARK: - Small helpers

/// A red error line under a form or a list.
struct ErrorLabel: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.footnote)
            .foregroundStyle(.red)
    }
}

/// Copies a text (public key, IP) – shows a check mark for a moment.
struct CopyButton: View {
    let text: String
    @State private var copied = false

    var body: some View {
        Button {
            UIPasteboard.general.string = text.trimmingCharacters(in: .whitespacesAndNewlines)
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                copied = false
            }
        } label: {
            Label(copied ? LocalizedStringKey("Copied") : LocalizedStringKey("Copy"), systemImage: copied ? "checkmark" : "doc.on.doc")
        }
    }
}

/// A number field that writes every valid keystroke through (a formatted TextField only commits on Return, and the
/// decimal pad has none). Accepts the user's decimal separator.
struct NumberField: View {
    @Binding var value: Double
    var fractionDigits = 4
    var placeholder: LocalizedStringKey = ""
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField(placeholder, text: $text)
            .keyboardType(fractionDigits == 0 ? .numberPad : .decimalPad)
            .multilineTextAlignment(.trailing)
            .monospacedDigit()
            .focused($focused)
            .onAppear { text = format(value) }
            .onChange(of: text) { _, newText in
                if let parsed = parse(newText), parsed != value { value = parsed }
            }
            .onChange(of: value) { _, newValue in
                // changed from outside (e.g. a "fix" button) or clamped – show it, unless the user is typing it
                if parse(text) != newValue, !focused { text = format(newValue) }
            }
            .onChange(of: focused) { _, isFocused in
                if !isFocused { text = format(value) }
            }
    }

    private func format(_ number: Double) -> String {
        number.formatted(.number.precision(.fractionLength(0...fractionDigits)).grouping(.never))
    }

    private func parse(_ string: String) -> Double? {
        let trimmed = string.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        if let number = formatter.number(from: trimmed) { return number.doubleValue }
        return Double(trimmed.replacingOccurrences(of: ",", with: "."))
    }
}

/// "Done" above the keyboard – the decimal pad cannot be closed otherwise.
struct KeyboardDoneButton: ViewModifier {
    func body(content: Content) -> some View {
        content.toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") {
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                }
            }
        }
    }
}

extension View {
    func keyboardDoneButton() -> some View { modifier(KeyboardDoneButton()) }
}

/// The connection state in one line – for the settings and the banner above the bots.
struct ConnectionLabel: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        switch store.connection {
        case .connected:
            if let engineError = store.status?.engineError {
                Label(engineError, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
            } else if let status = store.status, !status.exchangeOk {
                Label("Agent connected · Exchange: \(status.exchangeError ?? String(localized: "no data"))", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            } else {
                Label(store.status?.exchange == "mock" ? LocalizedStringKey("Connected · Demo market") : LocalizedStringKey("Connected · Revolut X"),
                      systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        case .connecting:
            HStack(spacing: 6) { ProgressView(); Text("Connecting …") }
        case .failed(let message):
            Label(message, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
        case .notConfigured:
            Text("Not connected").foregroundStyle(.secondary)
        }
    }
}
