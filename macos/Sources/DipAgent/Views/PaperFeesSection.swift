import DipAgentKit
import SwiftUI

/// Fees the simulation charges. Prefilled with Revolut X (buy 0 %, sell 0.09 %); changing them rebooks the
/// simulated trades on the agent, live trades are never touched.
struct PaperFeesSection: View {
    @Environment(AppStore.self) private var store
    let fees: PaperFees

    @State private var draft: PaperFees?
    @State private var saving = false
    @State private var error: String?

    private var current: PaperFees { draft ?? fees }
    private var changed: Bool { draft.map { $0 != fees } ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel("Paper mode fees")
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    row("Buy fee", value: Binding(
                        get: { current.buy * 100 },
                        set: { draft = PaperFees(buy: max(0, min($0, 10)) / 100, sell: current.sell) }
                    ))
                    row("Sell fee", value: Binding(
                        get: { current.sell * 100 },
                        set: { draft = PaperFees(buy: current.buy, sell: max(0, min($0, 10)) / 100) }
                    ))
                    Text("Revolut X currently charges 0 % on buys and 0.09 % on sells. Changing a fee rebooks all simulated trades; live trades stay as they are.")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
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
                                if saving { ProgressView().controlSize(.mini) } else { Text("Save fees") }
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

    private func row(_ title: LocalizedStringKey, value: Binding<Double>) -> some View {
        HStack {
            Text(title).font(.system(size: 12, weight: .medium))
            Spacer()
            HStack(spacing: 4) {
                TextField("", value: value, format: .number.precision(.fractionLength(0...3)))
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 70)
                Text(verbatim: "%").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }

    private func save() {
        guard let value = draft else { return }
        saving = true
        error = nil
        Task {
            do {
                try await store.savePaperFees(value)
                draft = nil
            } catch {
                self.error = error.localizedDescription
            }
            saving = false
        }
    }
}
