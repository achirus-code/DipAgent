import AppKit
import DipAgentKit
import ServiceManagement
import UniformTypeIdentifiers

/// What only the menu bar app needs: file dialogs for the backup and launch at login.
extension AppStore {
    private static let backupTypes: [UTType] = [.gzip, UTType(filenameExtension: "tgz"), UTType(filenameExtension: "tar.gz")]
        .compactMap { $0 }

    /// Downloads a backup from the agent and lets the user save it. Returns nil when the dialog was cancelled.
    func exportBackup() async throws -> URL? {
        let (data, suggestedName) = try await backupData()
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.allowedContentTypes = Self.backupTypes
        panel.canCreateDirectories = true
        guard let url = runModal(panel) else { return nil }
        try data.write(to: url, options: .atomic)
        return url
    }

    /// Lets the user pick a backup file and restores it on the agent. Returns nil when the dialog was cancelled.
    func importBackup() async throws -> RestoreResult? {
        guard isConnected else { return nil }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = Self.backupTypes
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard let url = runModal(panel) else { return nil }
        return try await restoreBackup(try Data(contentsOf: url))
    }

    /// Runs a file dialog in front of the panel; the panel stays open meanwhile (it would close on losing focus).
    private func runModal(_ panel: NSSavePanel) -> URL? {
        keepPanelOpen = true
        defer { keepPanelOpen = false }
        NSApp.activate(ignoringOtherApps: true)
        return panel.runModal() == .OK ? panel.url : nil
    }

    // MARK: - Launch at login

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                NSLog("Launch at login failed: \(error)")
            }
        }
    }
}
