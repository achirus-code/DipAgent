import AppKit
import Observation
import SwiftUI

@main
struct DipAgentApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // The UI lives in a status-bar panel managed by the AppDelegate.
        Settings { EmptyView() }
    }
}

/// Menu bar icon + panel. The panel closes when the user clicks elsewhere – except while the Revolut X
/// setup is open (`store.keepPanelOpen`), so the key can be copied into the browser and back.
/// (SwiftUI's MenuBarExtra can't be kept open, hence the custom panel.)
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = AppStore()
    private var statusItem: NSStatusItem?
    private var spinner: Timer?
    private var spinAngle: CGFloat = 0
    private var panel: StatusPanel?
    private var outsideClickMonitor: Any?
    private var lastAutoClose = Date.distantPast

    func applicationDidFinishLaunching(_ notification: Notification) {
        if SnapshotRunner.runIfRequested(store: store) { return }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.target = self
        item.button?.action = #selector(togglePanel)
        statusItem = item
        observeIcon()

        let panel = StatusPanel(rootView: RootView().environment(store))
        self.panel = panel
        // The user can drag the bottom edge to make the panel taller – remember that height.
        NotificationCenter.default.addObserver(forName: NSWindow.didEndLiveResizeNotification, object: panel, queue: .main) { [weak panel] _ in
            Task { @MainActor in
                if let panel { StatusPanel.savedHeight = panel.frame.height }
            }
        }

        // clicks into other apps / the desktop …
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.closeUnlessPinned() }
        }
        // … and anything else that takes the focus away (other window, Cmd-Tab, …)
        for (name, object) in [(NSWindow.didResignKeyNotification, panel as Any?), (NSApplication.didResignActiveNotification, nil)] {
            NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.closeUnlessPinned() }
            }
        }
        if ProcessInfo.processInfo.arguments.contains("--show-panel") { // dev aid: open the panel right away
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.showPanel() }
        }
    }

    @objc private func togglePanel() {
        guard let panel else { return }
        if panel.isVisible {
            hidePanel()
        } else if Date().timeIntervalSince(lastAutoClose) > 0.3 { // the icon click itself just closed it
            showPanel()
        }
    }

    private func closeUnlessPinned() {
        guard let panel, panel.isVisible, !store.keepPanelOpen else { return }
        hidePanel()
        lastAutoClose = Date()
    }

    /// Opens the panel below the icon, or brings it to the front if it is already open.
    private func showPanel() {
        guard let panel, let button = statusItem?.button, let buttonWindow = button.window else { return }
        let opening = !panel.isVisible
        if opening {
            let iconFrame = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
            let screen = (buttonWindow.screen ?? NSScreen.main)?.visibleFrame ?? .zero
            // Never taller than the screen – e.g. after moving to a smaller display
            let height = min(panel.frame.height, screen.height - 12)
            if height != panel.frame.height {
                panel.setContentSize(NSSize(width: panel.frame.width, height: height))
            }
            // The icon must sit in the menu bar (above the visible area); otherwise fall back to the top-right corner
            let iconIsPlaced = iconFrame.width > 0 && iconFrame.minY >= screen.maxY - 4
            var x = iconIsPlaced ? iconFrame.midX - panel.frame.width / 2 : screen.maxX
            x = min(max(x, screen.minX + 8), screen.maxX - panel.frame.width - 8)
            panel.setFrameOrigin(NSPoint(x: x, y: screen.maxY - panel.frame.height - 6))
        }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        setIconHighlighted(true)
        store.panelVisible = true
        if opening { store.refreshIfStale() } // fresh numbers (or an immediate reconnect) when the panel opens
        // No control starts focused (otherwise AppKit puts the focus ring on the first key view – the refresh button).
        // SwiftUI may assign its initial focus a runloop later, so clear it again then.
        if opening {
            panel.makeFirstResponder(nil)
            DispatchQueue.main.async { panel.makeFirstResponder(nil) }
        }
    }

    private func hidePanel() {
        store.panelVisible = false
        panel?.orderOut(nil)
        setIconHighlighted(false)
    }

    /// Like a regular menu bar menu: the icon stays selected while the panel is open.
    private func setIconHighlighted(_ highlighted: Bool) {
        statusItem?.button?.highlight(highlighted)
        // the button resets its highlight when the click that opened the panel ends – apply it again afterwards
        DispatchQueue.main.async { [weak self] in
            self?.statusItem?.button?.highlight(self?.panel?.isVisible == true)
        }
    }

    /// Keeps the menu bar icon in sync with the connection state; while connecting the icon spins.
    private func observeIcon() {
        withObservationTracking {
            let symbol = store.menuBarSymbol
            let connecting = store.connection == .connecting
            setSpinning(connecting, symbol: symbol)
            if !connecting {
                statusItem?.button?.image = Self.icon(symbol)
            }
        } onChange: {
            Task { @MainActor [weak self] in self?.observeIcon() }
        }
    }

    private static func icon(_ symbol: String, rotatedBy angle: CGFloat = 0) -> NSImage? {
        guard let base = NSImage(systemSymbolName: symbol, accessibilityDescription: "DipAgent") else { return nil }
        base.isTemplate = true
        guard angle != 0 else { return base }
        let size = NSSize(width: 18, height: 18) // the menu bar renders the symbol at this size anyway
        let image = NSImage(size: size, flipped: false) { rect in
            let transform = NSAffineTransform()
            transform.translateX(by: rect.midX, yBy: rect.midY)
            transform.rotate(byDegrees: -angle)
            transform.translateX(by: -rect.midX, yBy: -rect.midY)
            transform.concat()
            base.draw(in: rect.insetBy(dx: 1, dy: 1))
            return true
        }
        image.isTemplate = true
        return image
    }

    /// Rotates the "connecting" symbol a full turn per second, 12 frames – cheap enough for a menu bar icon.
    private func setSpinning(_ on: Bool, symbol: String) {
        if on {
            guard spinner == nil else { return }
            spinAngle = 0
            statusItem?.button?.image = Self.icon(symbol)
            spinner = Timer.scheduledTimer(withTimeInterval: 1.0 / 12, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.spinAngle = (self.spinAngle + 30).truncatingRemainder(dividingBy: 360)
                    self.statusItem?.button?.image = Self.icon(symbol, rotatedBy: self.spinAngle)
                }
            }
        } else {
            spinner?.invalidate()
            spinner = nil
        }
    }
}

/// Borderless floating panel with the translucent menu look; closing is handled by the AppDelegate.
/// The width is fixed, the height can be changed by dragging the bottom edge (AppKit resizes borderless
/// windows at their edges when they are `.resizable`).
final class StatusPanel: NSPanel {
    static let width: CGFloat = 400
    static let minHeight: CGFloat = 480
    static let defaultHeight: CGFloat = 620

    static var savedHeight: CGFloat {
        get {
            let v = UserDefaults.standard.double(forKey: "panelHeight")
            return v >= minHeight ? v : defaultHeight
        }
        set { UserDefaults.standard.set(Double(newValue), forKey: "panelHeight") }
    }

    init<Content: View>(rootView: Content) {
        let size = NSSize(width: Self.width, height: Self.savedHeight)
        super.init(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .resizable], backing: .buffered, defer: false)
        minSize = NSSize(width: Self.width, height: Self.minHeight)
        maxSize = NSSize(width: Self.width, height: 4000)
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true

        let background = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        background.maskImage = Self.roundedMask(radius: 14)

        let host = NSHostingView(rootView: rootView)
        host.sizingOptions = [] // the window decides the size, not the SwiftUI content
        host.frame = background.bounds
        host.autoresizingMask = [.width, .height]
        background.addSubview(host)
        contentView = background
    }

    override var canBecomeKey: Bool { true } // text fields need keyboard focus
    override var canBecomeMain: Bool { false }

    private static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}
