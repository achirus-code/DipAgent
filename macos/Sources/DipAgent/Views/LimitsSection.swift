import DipAgentKit
import SwiftUI

/// Global risk limits: how many positions may be open, how much capital, one bot per pair.
struct LimitsSection: View {
    @Environment(AppStore.self) private var store
    let limits: Limits

    @State private var draft: Limits?
    @State private var saving = false
    @State private var error: String?

    private var current: Limits { draft ?? limits }
    private var changed: Bool { draft.map { $0 != limits } ?? false }
    private var currency: String { store.summary?.currencies.first?.currency ?? "EUR" }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel("Risk & limits")
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    row(
                        "Max. open positions",
                        help: "How many bots may hold a position at the same time. Currently \(String(limits.openPositions ?? 0)) open."
                    ) {
                        HStack(spacing: 6) {
                            (current.maxOpenPositions == 0 ? Text("Unlimited") : Text(verbatim: String(current.maxOpenPositions)))
                                .font(.system(size: 12, weight: .semibold))
                                .monospacedDigit()
                                .frame(minWidth: 70, alignment: .trailing)
                            Stepper("", value: binding(\.maxOpenPositions), in: 0...50)
                                .labelsHidden()
                                .controlSize(.small)
                        }
                    }
                    row(
                        "Max. invested capital",
                        help: "Sum of all open positions. 0 = unlimited. Currently \(Fmt.money(limits.invested ?? 0, currency))."
                    ) {
                        HStack(spacing: 4) {
                            TextField("", value: binding(\.maxTotalInvested), format: .number.precision(.fractionLength(0...2)))
                                .textFieldStyle(.roundedBorder)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 80)
                            Text(currency).font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                    Toggle(isOn: binding(\.onePositionPerSymbol)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Only one bot per trading pair").font(.system(size: 12, weight: .medium))
                            Text("Prevents two bots from buying e.g. ETH-EUR at the same time.")
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .toggleStyle(.switch)
                    .controlSize(.small)

                    Label(
                        "Each bot holds at most one position (savings plan: up to “Max. buys”). Orders are never sent twice – not even after connection drops.",
                        systemImage: "checkmark.shield.fill"
                    )
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)

                    if let error {
                        Text(error).font(.system(size: 10.5)).foregroundStyle(.red)
                    }
                    if changed {
                        HStack {
                            Spacer()
                            Button("Discard") { draft = nil }
                                .controlSize(.small)
                            Button {
                                save()
                            } label: {
                                if saving { ProgressView().controlSize(.mini) } else { Text("Save limits") }
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .disabled(saving)
                        }
                    }
                }
            }
        }
    }

    private func row<Content: View>(_ title: LocalizedStringKey, help: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title).font(.system(size: 12, weight: .medium))
                Spacer()
                content()
            }
            Text(help).font(.system(size: 10)).foregroundStyle(.secondary)
        }
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
                draft = nil
            } catch {
                self.error = error.localizedDescription
            }
            saving = false
        }
    }
}
