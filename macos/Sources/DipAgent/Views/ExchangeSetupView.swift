import AppKit
import DipAgentKit
import SwiftUI

/// Settings section: Revolut X connection status + entry point to the setup.
struct ExchangeSection: View {
    let info: ExchangeInfo
    let open: (Route?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel("Revolut X")
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    if info.mode == "mock" {
                        Label("Demo mode: the agent uses a simulated market (EXCHANGE=mock).", systemImage: "testtube.2")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    } else {
                        HStack(spacing: 8) {
                            ExchangeStatusBadge(info: info)
                            Spacer()
                            Button(info.source == "none" ? LocalizedStringKey("Connect") : LocalizedStringKey("Manage")) { open(.exchangeSetup) }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                                .tint(info.source == "none" ? .accentColor : .secondary)
                        }
                        if let masked = info.apiKeyMasked {
                            row("API key", masked, monospaced: true)
                            row("Set up via", info.source == "env" ? String(localized: "the agent's .env") : String(localized: "this app"))
                        }
                        if let error = info.error, info.source != "none" {
                            Label(error, systemImage: "exclamationmark.triangle.fill")
                                .font(.system(size: 10.5)).foregroundStyle(.orange)
                        }
                    }
                }
            }
        }
    }

    private func row(_ title: LocalizedStringKey, _ value: String, monospaced: Bool = false) -> some View {
        HStack {
            Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.system(size: 11, weight: .medium, design: monospaced ? .monospaced : .default))
        }
    }
}

struct ExchangeStatusBadge: View {
    let info: ExchangeInfo

    var body: some View {
        if info.connected {
            Label("Connected", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                .font(.system(size: 12, weight: .medium))
        } else if info.source == "none" {
            Label(info.pendingPublicKey == nil ? LocalizedStringKey("Not set up") : LocalizedStringKey("Setup started"), systemImage: "link.badge.plus")
                .foregroundStyle(.secondary)
                .font(.system(size: 12, weight: .medium))
        } else {
            Label("Connection problem", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                .font(.system(size: 12, weight: .medium))
        }
    }
}

/// Three-step setup: key pair on the agent → public key into Revolut X → API key back into the app.
struct ExchangeSetupView: View {
    @Environment(AppStore.self) private var store
    let close: () -> Void

    @State private var apiKey = ""
    @State private var busy = false
    @State private var error: String?
    @State private var success = false
    @State private var publicIP: String?

    private var info: ExchangeInfo? { store.exchangeInfo }
    /// The key the user has to register at Revolut X: a freshly generated one wins over the active one.
    private var keyToRegister: String? { info?.pendingPublicKey ?? info?.publicKey }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "Connect Revolut X", back: close)
            Divider().opacity(0.5)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let info {
                        statusCard(info)
                        if info.source == "env" {
                            envInfo(info)
                        } else if info.mode != "mock" {
                            stepKeypair(info)
                            if keyToRegister != nil {
                                stepRevolut(info)
                                stepApiKey(info)
                            }
                            if info.source == "app" { removeSection }
                        }
                    } else {
                        ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
                    }
                }
                .padding(14)
            }
            .scrollIndicators(.never)
        }
        .task { publicIP = await store.serverPublicIP() }
    }

    // MARK: Sections

    private func statusCard(_ info: ExchangeInfo) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                ExchangeStatusBadge(info: info)
                Text("The key pair is generated on your agent – the private key never leaves it. You only register the public key with Revolut X and enter the API key Revolut shows you here.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let masked = info.apiKeyMasked {
                    HStack {
                        Text("Active API key").font(.system(size: 11)).foregroundStyle(.secondary)
                        Spacer()
                        Text(masked).font(.system(size: 11, weight: .medium, design: .monospaced))
                    }
                }
            }
        }
    }

    private func envInfo(_ info: ExchangeInfo) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Label("The access is configured in the agent's .env file and can only be changed there.", systemImage: "lock.fill")
                    .font(.system(size: 11))
                    .fixedSize(horizontal: false, vertical: true)
                if let key = info.publicKey { KeyBox(title: "Public key", text: key) }
            }
        }
    }

    private func stepKeypair(_ info: ExchangeInfo) -> some View {
        StepCard(number: 1, title: "Generate key pair", done: keyToRegister != nil) {
            if let key = keyToRegister {
                KeyBox(title: info.pendingPublicKey != nil ? "New public key" : "Public key (active)", text: key)
                ConfirmButton(
                    title: "Generate new key pair",
                    confirmTitle: info.source == "app"
                        ? "The current access stays active until a new API key has been saved."
                        : "The key generated so far will be replaced.",
                    icon: "arrow.triangle.2.circlepath",
                    tint: .secondary
                ) { await generate() }
            } else {
                Text("Generates an Ed25519 key on the agent, as required by Revolut X.")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
                primaryButton("Generate key pair", icon: "key.fill") { await generate() }
            }
        }
    }

    private func stepRevolut(_ info: ExchangeInfo) -> some View {
        StepCard(number: 2, title: "Register with Revolut X", done: info.pendingPublicKey == nil && info.source == "app") {
            VStack(alignment: .leading, spacing: 7) {
                if let url = URL(string: info.apiKeysUrl) {
                    Link(destination: url) {
                        Label("Open Revolut X → API keys", systemImage: "arrow.up.forward.app")
                            .font(.system(size: 11.5, weight: .medium))
                    }
                }
                bullet("Create a new API key and paste the public key from step 1 – completely, including the BEGIN and END lines.")
                bullet("If permissions are requested: allow reading and trading so the bots can place orders.")
                if let ip = publicIP {
                    bullet("If allowed IP addresses are requested, enter the agent's public IP:")
                    KeyBox(title: nil, text: ip, compact: true)
                } else {
                    bullet("If allowed IP addresses are requested, enter your agent's public IP.")
                }
                bullet("Revolut X then shows a 64-character API key – you need it in step 3.")
            }
        }
    }

    private func stepApiKey(_ info: ExchangeInfo) -> some View {
        StepCard(number: 3, title: "Enter API key", done: success) {
            VStack(alignment: .leading, spacing: 8) {
                TextField("64-character API key from Revolut X", text: $apiKey)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
                    .onSubmit { Task { await save() } }
                if let error {
                    Label(error, systemImage: "xmark.octagon.fill")
                        .font(.system(size: 10.5)).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if success {
                    Label("Connected! The bots now use Revolut X.", systemImage: "checkmark.seal.fill")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(.green)
                }
                primaryButton("Verify & connect", icon: "checkmark.shield.fill", disabled: apiKey.trimmingCharacters(in: .whitespaces).count < 16) {
                    await save()
                }
                Text("The agent checks the key right away by querying your balance and only saves it if Revolut X accepts it.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var removeSection: some View {
        ConfirmButton(
            title: "Remove Revolut X access",
            confirmTitle: "Bots can no longer trade afterwards. Really remove?",
            icon: "trash",
            tint: .red
        ) {
            do { try await store.removeExchangeCredentials(); success = false } catch { self.error = error.localizedDescription }
        }
        .padding(.top, 4)
    }

    // MARK: Helpers

    private func bullet(_ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("•").font(.system(size: 11)).foregroundStyle(.secondary)
            Text(text).font(.system(size: 10.5)).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func primaryButton(_ title: LocalizedStringKey, icon: String, disabled: Bool = false, action: @escaping () async -> Void) -> some View {
        Button {
            Task { await action() }
        } label: {
            HStack(spacing: 6) {
                if busy { ProgressView().controlSize(.small) } else { Image(systemName: icon) }
                Text(title).font(.system(size: 12, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .foregroundStyle(.white)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(LinearGradient(colors: strategyColors("dip"), startPoint: .leading, endPoint: .trailing))
            )
        }
        .buttonStyle(.plain)
        .disabled(busy || disabled)
        .opacity(disabled ? 0.5 : 1)
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

struct StepCard<Content: View>: View {
    let number: Int
    let title: LocalizedStringKey
    let done: Bool
    @ViewBuilder var content: Content

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    ZStack {
                        Circle().fill(done ? Color.green : Color.accentColor).frame(width: 20, height: 20)
                        if done {
                            Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                        } else {
                            Text(verbatim: String(number)).font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                        }
                    }
                    Text(title).font(.system(size: 12.5, weight: .semibold))
                }
                content
            }
        }
    }
}

/// Monospaced, selectable text with a copy button (public key, IP address).
struct KeyBox: View {
    let title: LocalizedStringKey?
    let text: String
    var compact = false
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let title {
                Text(title).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: 6) {
                Text(text.trimmingCharacters(in: .whitespacesAndNewlines))
                    .font(.system(size: compact ? 11 : 9.5, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text.trimmingCharacters(in: .whitespacesAndNewlines), forType: .string)
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        copied = false
                    }
                } label: {
                    Label(copied ? LocalizedStringKey("Copied") : LocalizedStringKey("Copy"), systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 10.5, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.06)))
        }
    }
}
