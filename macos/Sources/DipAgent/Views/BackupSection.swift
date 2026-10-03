import DipAgentKit
import SwiftUI

/// Export the agent's data (bots, trades, settings, Revolut X key) as a file and restore it – e.g. to move to
/// another agent such as the Home Assistant add-on. Restoring replaces everything and switches live trading off.
struct BackupSection: View {
    @Environment(AppStore.self) private var store
    @State private var confirmingImport = false
    @State private var busy = false
    @State private var info: String?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel("Backup")
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Bots, trades, settings and the Revolut X key of the agent as a file – e.g. to move to another agent. The API token is not included.")
                        .font(.system(size: 10.5)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        Button("Export …") { run { try await exportBackup() } }
                        Button("Import …") { withAnimation { confirmingImport = true; info = nil; error = nil } }
                            .disabled(confirmingImport)
                        Spacer()
                        if busy { ProgressView().controlSize(.small) }
                    }
                    .controlSize(.small)
                    .disabled(busy)

                    if confirmingImport {
                        importWarning
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
    }

    private var importWarning: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Importing replaces all bots, trades, settings and the Revolut X key on the agent.", systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .medium)).foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            Text("Live trading is switched off afterwards – bots continue in paper mode until you enable it again.")
                .font(.system(size: 10.5)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Cancel") { withAnimation { confirmingImport = false } }
                Spacer()
                Button("Choose file …") { run { try await importBackup() } }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
            }
            .controlSize(.small)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.orange.opacity(0.08)))
    }

    private func exportBackup() async throws {
        guard let url = try await store.exportBackup() else { return }
        info = String(localized: "Backup saved as \(url.lastPathComponent)")
    }

    private func importBackup() async throws {
        guard let result = try await store.importBackup() else { return }
        confirmingImport = false
        var text = String(localized: "Backup restored: \(String(result.bots)) bots, \(String(result.trades)) trades.")
        if result.credentialsRestored { text += " " + String(localized: "Revolut X access restored.") }
        if result.liveTradingDisabled { text += " " + String(localized: "Live trading was switched off.") }
        info = text
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
