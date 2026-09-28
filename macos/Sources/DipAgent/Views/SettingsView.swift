import AppKit
import SwiftUI

struct SettingsView: View {
    @Environment(AppStore.self) private var store
    let open: (Route?) -> Void

    @State private var server = ""
    @State private var token = ""
    @State private var showToken = false
    @State private var launchAtLogin = false
    @State private var language = AppLanguage.override ?? ""

    var body: some View {
        @Bindable var store = store
        VStack(alignment: .leading, spacing: 14) {
            // Not connected yet: the agent connection is the first (and main) thing to do
            if !store.isConnected {
                agentSection
            }

            if store.isConnected, store.status?.exchange != "mock" {
                LiveTradingSection()
            }

            if store.isConnected, let limits = store.limits {
                LimitsSection(limits: limits)
            }

            // App
            VStack(alignment: .leading, spacing: 6) {
                SectionLabel("App")
                Card {
                    VStack(alignment: .leading, spacing: 10) {
                        labeled("Refresh") {
                            Picker("", selection: $store.refreshInterval) {
                                Text(verbatim: "5 s").tag(5.0)
                                Text(verbatim: "15 s").tag(15.0)
                                Text(verbatim: "30 s").tag(30.0)
                                Text(verbatim: "60 s").tag(60.0)
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                        }
                        Toggle("Notify about new trades", isOn: $store.notificationsEnabled)
                            .toggleStyle(.switch).controlSize(.small)
                            .font(.system(size: 12))
                        Toggle("Launch at login", isOn: Binding(
                            get: { launchAtLogin },
                            set: { store.launchAtLogin = $0; launchAtLogin = store.launchAtLogin }
                        ))
                        .toggleStyle(.switch).controlSize(.small)
                        .font(.system(size: 12))
                        labeled("Language") {
                            Picker("", selection: $language) {
                                Text("System").tag("")
                                Text(verbatim: "English").tag("en")
                                Text(verbatim: "Deutsch").tag("de")
                            }
                            .labelsHidden()
                            .onChange(of: language) { _, newValue in
                                AppLanguage.override = newValue.isEmpty ? nil : newValue
                            }
                        }
                        if (AppLanguage.override ?? "") != AppLanguage.atLaunch {
                            HStack {
                                Text("Restart DipAgent to apply the language.")
                                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
                                Spacer()
                                Button("Restart") { AppLanguage.relaunch() }
                                    .controlSize(.small)
                            }
                        }
                    }
                }
            }

            // Once connected, the connection details move to the bottom
            if store.isConnected {
                agentSection
                if let info = store.exchangeInfo {
                    ExchangeSection(info: info, open: open)
                }
                BackupSection()
            }

            HStack {
                Text("DipAgent \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
                    .controlSize(.small)
                    .keyboardShortcut("q")
            }
            .padding(.horizontal, 4)
        }
        .onAppear {
            server = store.serverURL
            token = store.token
            launchAtLogin = store.launchAtLogin
        }
    }

    private var agentSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel("Agent")
            if store.isConnected {
                connectedCard
            } else {
                connectionForm
            }
        }
    }

    /// Connected: read-only details + disconnect. Editing happens after "Disconnect".
    private var connectedCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    connectionLabel
                    Spacer()
                    Button("Disconnect") {
                        store.disconnect()
                        server = store.serverURL
                        token = store.token
                    }
                    .controlSize(.small)
                }
                Divider().opacity(0.4)
                infoRow("Address", displayAddress)
                HStack(spacing: 6) {
                    Text("API token").font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    Text(showToken ? store.token : String(repeating: "•", count: 12))
                        .font(.system(size: showToken ? 10 : 11, weight: .medium, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button { showToken.toggle() } label: {
                        Image(systemName: showToken ? "eye.slash" : "eye").font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help(showToken ? Text("Hide token") : Text("Show token"))
                }
                if let status = store.status {
                    infoRow("Agent version", status.version)
                    infoRow("Exchange", status.exchange == "mock" ? String(localized: "Demo market (simulated)") : "Revolut X")
                    infoRow("Live trading", status.liveTradingAllowed ? String(localized: "On") : String(localized: "Off (paper only)"))
                    infoRow("Check interval", String(localized: "every \(String(status.tickSeconds)) s"))
                    if let tick = status.lastTick {
                        infoRow("Last check", Date(ms: tick).formatted(.relative(presentation: .named)))
                    }
                    if let err = status.exchangeError {
                        Label(err, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 10.5)).foregroundStyle(.orange)
                    }
                }
            }
        }
    }

    /// Not connected: address + token input.
    private var connectionForm: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                labeled("Address") {
                    TextField("e.g. 192.168.1.10", text: $server)
                        .textFieldStyle(.roundedBorder)
                        .help("IP address or host name of the agent. Port \(String(APIClient.defaultPort)) is used automatically.")
                }
                labeled("API token") {
                    HStack(spacing: 4) {
                        Group {
                            if showToken { TextField("Token", text: $token) } else { SecureField("Token", text: $token) }
                        }
                        .textFieldStyle(.roundedBorder)
                        Button { showToken.toggle() } label: {
                            Image(systemName: showToken ? "eye.slash" : "eye").font(.system(size: 11))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                }
                HStack {
                    connectionLabel
                    Spacer()
                    Button("Connect") {
                        Task { await store.saveConnection(server: server, token: token) }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(server.isEmpty || token.isEmpty || store.connection == .connecting)
                }
            }
        }
    }

    /// The address as actually used, e.g. "192.168.1.10:3470".
    private var displayAddress: String {
        guard let url = try? APIClient(server: store.serverURL, token: "").baseURL, let host = url.host else {
            return store.serverURL
        }
        return url.port.map { "\(host):\($0)" } ?? host
    }

    @ViewBuilder
    private var connectionLabel: some View {
        switch store.connection {
        case .connected:
            Label("Connected", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.system(size: 11))
        case .connecting:
            HStack(spacing: 5) { ProgressView().controlSize(.mini); Text("Connecting …") }.font(.system(size: 11))
        case .failed(let message):
            Label(message, systemImage: "xmark.octagon.fill").foregroundStyle(.red).font(.system(size: 11)).lineLimit(2)
        case .notConfigured:
            Text("Not connected").font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private func labeled<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 10) {
            Text(title).font(.system(size: 12, weight: .medium)).frame(width: 92, alignment: .leading)
            content()
        }
    }

    private func infoRow(_ title: LocalizedStringKey, _ value: String) -> some View {
        HStack {
            Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.system(size: 11, weight: .medium))
        }
    }
}
