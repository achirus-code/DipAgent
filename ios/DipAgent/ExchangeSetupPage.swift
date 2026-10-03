import DipAgentKit
import SwiftUI

/// Three steps: key pair on the agent → public key into Revolut X → API key back into the app.
struct ExchangeSetupPage: View {
    @Environment(AppStore.self) private var store
    @State private var apiKey = ""
    @State private var busy = false
    @State private var error: String?
    @State private var success = false
    @State private var publicIP: String?
    @State private var confirmingNewKey = false
    @State private var confirmingRemove = false

    private var info: ExchangeInfo? { store.exchangeInfo }
    /// The key the user has to register at Revolut X: a freshly generated one wins over the active one.
    private var keyToRegister: String? { info?.pendingPublicKey ?? info?.publicKey }

    var body: some View {
        Form {
            if let info {
                Section {
                    LabeledContent("Status") { ExchangeStatusText(info: info) }
                    if let masked = info.apiKeyMasked {
                        LabeledContent("Active API key") { Text(masked).font(.body.monospaced()) }
                    }
                    if let error = info.error, info.source != "none" {
                        Label(error, systemImage: "exclamationmark.triangle.fill").font(.footnote).foregroundStyle(.orange)
                    }
                } footer: {
                    Text("The key pair is generated on your agent – the private key never leaves it. You only register the public key with Revolut X and enter the API key Revolut shows you here.")
                }
                if info.source == "env" {
                    Section {
                        Label("The access is configured in the agent's .env file and can only be changed there.", systemImage: "lock.fill")
                        if let key = info.publicKey { keyRow(key) }
                    }
                } else {
                    stepKeypair(info)
                    if keyToRegister != nil {
                        stepRevolut(info)
                        stepApiKey
                    }
                    if info.source == "app" {
                        Section {
                            Button("Remove Revolut X access", role: .destructive) { confirmingRemove = true }
                        }
                    }
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Connect Revolut X")
        .navigationBarTitleDisplayMode(.inline)
        .task { publicIP = await store.serverPublicIP() }
        .confirmationDialog(
            info?.source == "app" ? "The current access stays active until a new API key has been saved." : "The key generated so far will be replaced.",
            isPresented: $confirmingNewKey, titleVisibility: .visible
        ) {
            Button("Generate new key pair") { Task { await generate() } }
        }
        .confirmationDialog("Bots can no longer trade afterwards. Really remove?", isPresented: $confirmingRemove, titleVisibility: .visible) {
            Button("Remove Revolut X access", role: .destructive) {
                Task {
                    do { try await store.removeExchangeCredentials(); success = false } catch { self.error = error.localizedDescription }
                }
            }
        }
    }

    private func stepKeypair(_ info: ExchangeInfo) -> some View {
        Section {
            if let key = keyToRegister {
                keyRow(key)
                Button("Generate new key pair") { confirmingNewKey = true }
                    .disabled(busy)
            } else {
                Text("Generates an Ed25519 key on the agent, as required by Revolut X.").font(.footnote)
                Button {
                    Task { await generate() }
                } label: {
                    Label("Generate key pair", systemImage: "key.fill")
                }
                .disabled(busy)
            }
        } header: {
            step(1, "Generate key pair", done: keyToRegister != nil)
        }
    }

    private func stepRevolut(_ info: ExchangeInfo) -> some View {
        Section {
            if let url = URL(string: info.apiKeysUrl) {
                Link(destination: url) {
                    Label("Open Revolut X → API keys", systemImage: "arrow.up.forward.app")
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                bullet("Create a new API key and paste the public key from step 1 – completely, including the BEGIN and END lines.")
                bullet("If permissions are requested: allow reading and trading so the bots can place orders.")
                bullet(publicIP == nil ? "If allowed IP addresses are requested, enter your agent's public IP." : "If allowed IP addresses are requested, enter the agent's public IP:")
            }
            .font(.footnote)
            if let ip = publicIP {
                HStack {
                    Text(ip).font(.body.monospaced()).textSelection(.enabled)
                    Spacer()
                    CopyButton(text: ip).buttonStyle(.borderless)
                }
            }
            bullet("Revolut X then shows a 64-character API key – you need it in step 3.").font(.footnote)
        } header: {
            step(2, "Register with Revolut X", done: info.pendingPublicKey == nil && info.source == "app")
        }
    }

    private var stepApiKey: some View {
        Section {
            TextField("64-character API key from Revolut X", text: $apiKey, axis: .vertical)
                .font(.body.monospaced())
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button {
                Task { await save() }
            } label: {
                HStack {
                    if busy { ProgressView().padding(.trailing, 4) }
                    Label("Verify & connect", systemImage: "checkmark.shield.fill")
                }
            }
            .disabled(busy || apiKey.trimmingCharacters(in: .whitespacesAndNewlines).count < 16)
            if let error { ErrorLabel(message: error) }
            if success {
                Label("Connected! The bots now use Revolut X.", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
            }
        } header: {
            step(3, "Enter API key", done: success)
        } footer: {
            Text("The agent checks the key right away by querying your balance and only saves it if Revolut X accepts it.")
        }
    }

    /// The public key: shown in full, to copy or share (e.g. to a computer where Revolut X is open).
    private func keyRow(_ key: String) -> some View {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        return VStack(alignment: .leading, spacing: 8) {
            Text(trimmed)
                .font(.caption.monospaced())
                .textSelection(.enabled)
            HStack(spacing: 20) {
                CopyButton(text: trimmed)
                ShareLink(item: trimmed) { Label("Share", systemImage: "square.and.arrow.up") }
            }
            .buttonStyle(.borderless)
        }
    }

    private func step(_ number: Int, _ title: LocalizedStringKey, done: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: done ? "checkmark.circle.fill" : "\(number).circle.fill")
                .foregroundStyle(done ? Color.green : Color.accentColor)
            Text(title)
        }
    }

    private func bullet(_ text: LocalizedStringKey) -> Text {
        Text(verbatim: "• ") + Text(text)
    }

    private func generate() async {
        busy = true
        error = nil
        success = false
        do { try await store.generateKeypair() } catch { self.error = error.localizedDescription }
        busy = false
    }

    private func save() async {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard key.count >= 16, !busy else { return }
        busy = true
        error = nil
        do {
            try await store.saveApiKey(key)
            apiKey = ""
            success = true
        } catch {
            self.error = error.localizedDescription
        }
        busy = false
    }
}
