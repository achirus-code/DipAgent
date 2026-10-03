import AppKit
import DipAgentKit
import SwiftUI

/// Developer aid: `DipAgent --snapshot <dir> -serverURL <url> -apiToken <token> [-snapshotHeight 1200]`
/// renders every screen of the panel (light + dark) into PNG files and quits.
enum SnapshotRunner {
    /// Returns true if snapshot mode was started (the app then quits by itself).
    @MainActor
    static func runIfRequested(store: AppStore) -> Bool {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "--snapshot"), index + 1 < args.count else { return false }
        let dir = URL(fileURLWithPath: args[index + 1])
        let height = max(CGFloat(UserDefaults.standard.integer(forKey: "snapshotHeight")), StatusPanel.defaultHeight)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            let firstBot = store.bots.first?.id
            var screens: [(String, MainTab, Route?)] = [
                ("bots", .bots, nil), ("trades", .trades, nil), ("settings", .settings, nil), ("new-bot", .bots, .editor(nil)), ("exchange-setup", .settings, .exchangeSetup),
            ]
            if let firstBot { screens += [("detail", .bots, .bot(firstBot)), ("edit-bot", .bots, .editor(firstBot))] }

            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                for (name, tab, route) in screens + [("settings-full", .settings, nil), ("live-warning", .settings, nil), ("live-final", .settings, nil), ("live-disable", .settings, nil)] {
                    let full = name == "settings-full"
                    let root = Group {
                        if name.hasPrefix("live-") {
                            LiveTradingSection(initialStep: name == "live-warning" ? .warning : name == "live-final" ? .finalConfirmation : .disableWarning)
                                .padding(14).frame(width: 400, height: 620, alignment: .top)
                        } else if full {
                            SettingsView(open: { _ in }).padding(14).frame(width: 400, height: 1500, alignment: .top)
                        } else {
                            RootView(initialTab: tab, initialRoute: route).frame(height: height)
                        }
                    }
                    .environment(store)
                    .background(.regularMaterial)
                    let host = NSHostingView(rootView: root)
                    host.frame = NSRect(x: 0, y: 0, width: 400, height: full ? 1500 : height)
                    let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                    window.appearance = NSAppearance(named: appearance)
                    window.contentView = host
                    window.setFrameOrigin(NSPoint(x: -3000, y: -3000))
                    window.orderFrontRegardless()
                    try? await Task.sleep(for: .milliseconds(900))
                    host.layoutSubtreeIfNeeded()
                    if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                        host.cacheDisplay(in: host.bounds, to: rep)
                        let suffix = appearance == .darkAqua ? "dark" : "light"
                        try? rep.representation(using: .png, properties: [:])?
                            .write(to: dir.appendingPathComponent("\(name)-\(suffix).png"))
                    }
                    window.orderOut(nil)
                }
            }
            NSApp.terminate(nil)
        }
        return true
    }
}
