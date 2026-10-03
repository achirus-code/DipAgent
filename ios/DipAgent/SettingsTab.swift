import DipAgentKit
import SwiftUI
import UniformTypeIdentifiers

/// Agent, trading mode, limits, fees, Revolut X, backup and the app itself – every topic one row, details on
/// their own page.
struct SettingsTab: View {
    @Environment(AppStore.self) private var store
    @AppStorage("onboarded") private var onboarded = false

    var body: some View {
        @Bindable var store = store
        NavigationStack {
            Form {
                agentSection
                if store.isConnected {
                    if store.status?.exchange != "mock" {
                        LiveTradingSection()
                    }
                    Section {
                        if let limits = store.limits {
                            NavigationLink { LimitsPage(limits: limits) } label: {
                                LabeledContent("Risk & limits", value: limitsSummary(limits))
                            }
                        }
                        if let fees = store.paperFees {
                            NavigationLink { PaperFeesPage(fees: fees) } label: {
                                LabeledContent("Paper mode fees", value: "\(Fmt.rate(fees.buy * 100)) / \(Fmt.rate(fees.sell * 100))")
                            }
                        }
                        if let info = store.exchangeInfo {
                            if info.mode == "mock" {
                                LabeledContent("Revolut X", value: String(localized: "Demo market (simulated)"))
                            } else {
                                NavigationLink { ExchangeSetupPage() } label: {
                                    LabeledContent("Revolut X") { ExchangeStatusText(info: info) }
                                }
                            }
                        }
                    }
                    BackupSection()
                }

                Section {
                    Picker("Refresh", selection: $store.refreshInterval) {
                        Text("every 30 s").tag(30.0)
                        Text("every minute").tag(60.0)
                        Text("every 2 min").tag(120.0)
                        Text("every 5 min").tag(300.0)
                    }
                    Toggle("Notifications", isOn: $store.notificationsEnabled)
                    Button {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    } label: {
                        LabeledContent("Language", value: Locale.current.localizedString(forLanguageCode: AppLanguage.current) ?? AppLanguage.current)
                    }
                    .foregroundStyle(.primary)
                } header: {
                    Text("App")
                } footer: {
                    Text("While the app is closed, iOS checks for new trades now and then – how often is up to iOS. The language is changed in the iPhone settings.")
                }

                Section {
                } footer: {
                    Text("DipAgent \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")")
                        .frame(maxWidth: .infinity)
                }
            }
            .navigationTitle("Settings")
            .refreshable { await store.refresh() }
            .keyboardDoneButton()
        }
    }

    private var agentSection: some View {
        Section {
            ConnectionLabel()
            LabeledContent("Address", value: displayAddress)
            if let status = store.status {
                LabeledContent("Agent version", value: status.version)
                LabeledContent("Exchange", value: status.exchange == "mock" ? String(localized: "Demo market (simulated)") : "Revolut X")
                LabeledContent("Check interval", value: String(localized: "every \(String(status.tickSeconds)) s"))
                if let tick = status.lastTick {
                    LabeledContent("Last check", value: Date(ms: tick).formatted(.relative(presentation: .named)))
                }
            }
            Button("Disconnect", role: .destructive) {
                store.disconnect()
                onboarded = false
            }
        } header: {
            Text("Agent")
        }
    }

    /// The address as actually used, e.g. "192.168.1.10:3470".
    private var displayAddress: String {
        guard let url = try? APIClient(server: store.serverURL, token: "").baseURL, let host = url.host else {
            return store.serverURL
        }
        return url.port.map { "\(host):\($0)" } ?? host
    }

    private func limitsSummary(_ limits: Limits) -> String {
        let currency = store.summary?.currencies.first?.currency ?? "EUR"
        let positions = limits.maxOpenPositions == 0 ? "∞" : String(limits.maxOpenPositions)
        let capital = limits.maxTotalInvested > 0 ? Fmt.money(limits.maxTotalInvested, currency) : "∞"
        return "\(positions) · \(capital)"
    }
}

struct ExchangeStatusText: View {
    let info: ExchangeInfo

    var body: some View {
        if info.connected {
            Text("Connected").foregroundStyle(.green)
        } else if info.source == "none" {
            Text(info.pendingPublicKey == nil ? "Not set up" : "Setup started")
        } else {
            Text("Connection problem").foregroundStyle(.orange)
        }
    }
}

// MARK: - Trading mode

/// Paper mode (default) or live trading. Switching on needs two confirmations; switching off sells all open live
/// positions (with a warning first).
struct LiveTradingSection: View {
    @Environment(AppStore.self) private var store
    @State private var showingWarning = false
    @State private var confirmingDisable = false
    @State private var busy = false
    @State private var error: String?
    @State private var info: String?

    private var live: Bool { store.status?.liveTradingAllowed ?? false }
    private var exchangeReady: Bool { store.exchangeInfo?.connected == true }
    private var liveBotsWithPosition: [Bot] { store.bots.filter { $0.position?.paper == false } }

    var body: some View {
        Section {
            HStack(spacing: 12) {
                IconTile(symbol: live ? "bolt.fill" : "testtube.2", colors: live ? [.red, .orange] : [.orange, .yellow], size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    (live ? Text("Live trading active") : Text("Paper mode (demo)")).font(.headline)
                    (live ? Text("Real orders with real money on Revolut X") : Text("Real prices, orders are only simulated"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if busy {
                    ProgressView()
                } else {
                    Toggle("Live trading", isOn: Binding(
                        get: { live },
                        set: { on in
                            error = nil
                            info = nil
                            if on { showingWarning = true } else { confirmingDisable = true }
                        }
                    ))
                    .labelsHidden()
                    .tint(.red)
                    .disabled(!live && !exchangeReady)
                }
            }
            if let info { Label(info, systemImage: "checkmark.circle.fill").font(.footnote).foregroundStyle(.green) }
            if let error { ErrorLabel(message: error) }
        } header: {
            Text("Trading mode")
        } footer: {
            if !live && !exchangeReady {
                Text("Connect Revolut X first – then live trading can be switched on.")
            } else if live {
                Text("When switching back to paper mode, all open live positions are sold immediately.")
            } else if !liveBotsWithPosition.isEmpty {
                Text("\(String(liveBotsWithPosition.count)) live position(s) could not be sold and are still managed live – sell them manually in the bot view.")
            }
        }
        .sheet(isPresented: $showingWarning) {
            LiveWarningSheet { Task { await setLive(true) } }
        }
        .confirmationDialog("Back to paper mode", isPresented: $confirmingDisable, titleVisibility: .visible) {
            Button(liveBotsWithPosition.isEmpty ? "Switch to paper mode" : "Sell everything & paper mode", role: .destructive) {
                Task { await setLive(false) }
            }
        } message: {
            if liveBotsWithPosition.isEmpty {
                Text("No live position is open right now – nothing will be sold.")
            } else {
                let lines = liveBotsWithPosition.compactMap { bot in
                    bot.position.map { "\(bot.name): \(Fmt.qty($0.qty)) \(bot.baseCurrency) (\(Fmt.money($0.unrealizedPnl, bot.quoteCurrency, signed: true)))" }
                }
                Text("All open live trades are closed immediately, i.e. sold at the current market price on Revolut X:") + Text(verbatim: "\n" + lines.joined(separator: "\n") + "\n") + Text("This locks in the result – even if a position is currently at a loss.")
            }
        }
    }

    private func setLive(_ enabled: Bool) async {
        busy = true
        error = nil
        do {
            let closed = try await store.setLiveTrading(enabled)
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
}

/// Step 1 of 2 before live trading: what changes, and an explicit "I understand". Step 2 is the final question.
struct LiveWarningSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let enable: () -> Void
    @State private var understood = false
    @State private var finalQuestion = false

    private var openPaperPositions: [Bot] { store.bots.filter { $0.position?.paper == true } }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label("Attention: real money", systemImage: "exclamationmark.triangle.fill")
                        .font(.headline).foregroundStyle(.orange)
                    if store.bots.isEmpty {
                        bullet("All bots you create afterwards buy and sell with your real balance on Revolut X.")
                    } else {
                        bullet("All existing bots are switched to live as well and then trade with your real balance on Revolut X: \(store.bots.map(\.name).joined(separator: ", ")).")
                        bullet("If a bot should not trade with real money, you have to delete it first (Bots tab).").bold()
                    }
                    if !openPaperPositions.isEmpty {
                        bullet("Open paper positions (\(openPaperPositions.map(\.name).joined(separator: ", "))) are still sold simulated, afterwards the bot buys live.")
                    }
                    bullet("Losses are possible. “Risk & limits” caps open positions and capital.")
                }
                Section {
                    Toggle("I understand that real money is used.", isOn: $understood)
                }
                Section {
                    Button {
                        finalQuestion = true
                    } label: {
                        Text("Continue").bold().frame(maxWidth: .infinity)
                    }
                    .disabled(!understood)
                }
            }
            .navigationTitle("Live trading")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .confirmationDialog(finalText, isPresented: $finalQuestion, titleVisibility: .visible) {
                Button("Yes, enable live trading", role: .destructive) {
                    dismiss()
                    enable()
                }
            }
        }
    }

    private var finalText: Text {
        if store.bots.isEmpty {
            return Text("Enable live trading now? Bots place real orders from the next buy signal on.")
        } else if store.bots.count == 1 {
            return Text("Enable live trading now? Your bot is switched to live and places real orders from the next buy signal on.")
        }
        return Text("Enable live trading now? All \(String(store.bots.count)) bots are switched to live and place real orders from the next buy signal on.")
    }

    private func bullet(_ text: LocalizedStringKey) -> Text {
        Text(verbatim: "• ") + Text(text)
    }
}

// MARK: - Limits and fees

/// Global risk limits: how many positions may be open, how much capital, one bot per pair.
struct LimitsPage: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let limits: Limits
    @State private var draft: Limits?
    @State private var saving = false
    @State private var error: String?

    private var current: Limits { draft ?? limits }
    private var currency: String { store.summary?.currencies.first?.currency ?? "EUR" }

    var body: some View {
        Form {
            Section {
                Stepper(value: binding(\.maxOpenPositions), in: 0...50) {
                    LabeledContent("Max. open positions") {
                        current.maxOpenPositions == 0 ? Text("Unlimited") : Text(verbatim: String(current.maxOpenPositions))
                    }
                }
            } footer: {
                Text("How many bots may hold a position at the same time. Currently \(String(limits.openPositions ?? 0)) open.")
            }
            Section {
                HStack {
                    Text("Max. invested capital")
                    Spacer()
                    NumberField(value: binding(\.maxTotalInvested), fractionDigits: 2).frame(maxWidth: 120)
                    Text(verbatim: currency).foregroundStyle(.secondary)
                }
            } footer: {
                Text("Sum of all open positions. 0 = unlimited. Currently \(Fmt.money(limits.invested ?? 0, currency)).")
            }
            Section {
                Toggle("Only one bot per trading pair", isOn: binding(\.onePositionPerSymbol))
            } footer: {
                Text("Prevents two bots from buying e.g. ETH-EUR at the same time.")
            }
            Section {
            } footer: {
                Label("Each bot holds at most one position (savings plan: up to “Max. buys”). Orders are never sent twice – not even after connection drops.", systemImage: "checkmark.shield.fill")
            }
            if let error { Section { ErrorLabel(message: error) } }
        }
        .navigationTitle("Risk & limits")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if saving {
                ProgressView()
            } else {
                Button("Save", action: save).bold().disabled(draft == nil || draft == limits)
            }
        }
        .keyboardDoneButton()
    }

    private func binding<T>(_ keyPath: WritableKeyPath<Limits, T>) -> Binding<T> {
        Binding(
            get: { current[keyPath: keyPath] },
            set: { value in
                var copy = current
                copy[keyPath: keyPath] = value
                draft = copy
            }
        )
    }

    private func save() {
        guard var value = draft else { return }
        value.maxTotalInvested = max(0, value.maxTotalInvested)
        saving = true
        error = nil
        Task {
            do {
                try await store.saveLimits(value)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            saving = false
        }
    }
}

/// Fees the simulation charges – changing them rebooks the simulated trades on the agent.
struct PaperFeesPage: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let fees: PaperFees
    @State private var draft: PaperFees?
    @State private var saving = false
    @State private var error: String?

    private var current: PaperFees { draft ?? fees }

    var body: some View {
        Form {
            Section {
                row("Buy fee", value: Binding(
                    get: { current.buy * 100 },
                    set: { draft = PaperFees(buy: max(0, min($0, 10)) / 100, sell: current.sell) }
                ))
                row("Sell fee", value: Binding(
                    get: { current.sell * 100 },
                    set: { draft = PaperFees(buy: current.buy, sell: max(0, min($0, 10)) / 100) }
                ))
            } footer: {
                Text("Revolut X currently charges 0 % on buys and 0.09 % on sells. Changing a fee rebooks all simulated trades; live trades stay as they are.")
            }
            if let error { Section { ErrorLabel(message: error) } }
        }
        .navigationTitle("Paper mode fees")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if saving {
                ProgressView()
            } else {
                Button("Save", action: save).bold().disabled(draft == nil || draft == fees)
            }
        }
        .keyboardDoneButton()
    }

    private func row(_ title: LocalizedStringKey, value: Binding<Double>) -> some View {
        HStack {
            Text(title)
            Spacer()
            NumberField(value: value, fractionDigits: 3).frame(maxWidth: 100)
            Text(verbatim: "%").foregroundStyle(.secondary)
        }
    }

    private func save() {
        guard let value = draft else { return }
        saving = true
        error = nil
        Task {
            do {
                try await store.savePaperFees(value)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            saving = false
        }
    }
}

// MARK: - Backup

/// Export the agent's data (bots, trades, settings, Revolut X key) as a file and restore it.
struct BackupSection: View {
    @Environment(AppStore.self) private var store
    @State private var exportFile: BackupFile?
    @State private var exporting = false
    @State private var confirmingImport = false
    @State private var importing = false
    @State private var busy = false
    @State private var info: String?
    @State private var error: String?

    private static let types: [UTType] = [.gzip, UTType(filenameExtension: "tgz"), UTType(filenameExtension: "tar.gz")].compactMap { $0 }

    var body: some View {
        Section {
            Button {
                run {
                    let (data, name) = try await store.backupData()
                    exportFile = BackupFile(data: data, name: name)
                    exporting = true
                }
            } label: {
                Label("Export backup …", systemImage: "square.and.arrow.up")
            }
            Button {
                confirmingImport = true
            } label: {
                Label("Import backup …", systemImage: "square.and.arrow.down")
            }
            if busy { ProgressView() }
            if let info { Label(info, systemImage: "checkmark.circle.fill").font(.footnote).foregroundStyle(.green) }
            if let error { ErrorLabel(message: error) }
        } header: {
            Text("Backup")
        } footer: {
            Text("Bots, trades, settings and the Revolut X key of the agent as a file – e.g. to move to another agent. The API token is not included.")
        }
        .disabled(busy)
        .fileExporter(isPresented: $exporting, document: exportFile, contentType: .gzip, defaultFilename: exportFile?.name) { result in
            switch result {
            case .success(let url): info = String(localized: "Backup saved as \(url.lastPathComponent)")
            case .failure(let failure): error = failure.localizedDescription
            }
            exportFile = nil
        }
        .confirmationDialog("Importing replaces all bots, trades, settings and the Revolut X key on the agent.", isPresented: $confirmingImport, titleVisibility: .visible) {
            Button("Choose file …", role: .destructive) { importing = true }
        } message: {
            Text("Live trading is switched off afterwards – bots continue in paper mode until you enable it again.")
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: Self.types) { result in
            switch result {
            case .success(let url):
                run {
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    let result = try await store.restoreBackup(try Data(contentsOf: url))
                    var text = String(localized: "Backup restored: \(String(result.bots)) bots, \(String(result.trades)) trades.")
                    if result.credentialsRestored { text += " " + String(localized: "Revolut X access restored.") }
                    if result.liveTradingDisabled { text += " " + String(localized: "Live trading was switched off.") }
                    info = text
                }
            case .failure(let failure):
                error = failure.localizedDescription
            }
        }
    }

    private func run(_ action: @escaping () async throws -> Void) {
        busy = true
        info = nil
        error = nil
        Task {
            defer { busy = false }
            do { try await action() } catch { self.error = error.localizedDescription }
        }
    }
}

/// The downloaded backup, handed to the system's "save to Files" dialog.
struct BackupFile: FileDocument {
    static var readableContentTypes: [UTType] { [.gzip] }
    let data: Data
    let name: String

    init(data: Data, name: String) {
        self.data = data
        self.name = name
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
        name = "dipagent-backup.tgz"
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
