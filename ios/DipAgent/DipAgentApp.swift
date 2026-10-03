import BackgroundTasks
import DipAgentKit
import SwiftUI
import UserNotifications

/// The one store of the app – the scene and the background refresh share it.
@MainActor
enum Shared {
    static let store = AppStore(persistLastSeenTrade: true)
}

@main
struct DipAgentApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(Shared.store)
        }
        .onChange(of: scenePhase) { _, phase in
            let store = Shared.store
            switch phase {
            case .active:
                store.isVisible = true
                Task { await store.resume() }
            case .background:
                // no polling in the background – iOS wakes the app now and then instead
                store.isVisible = false
                store.stopPolling()
                BackgroundRefresh.schedule()
            default:
                break
            }
        }
        .backgroundTask(.appRefresh(BackgroundRefresh.identifier)) {
            BackgroundRefresh.schedule() // the next one – iOS decides when it actually runs
            _ = await Shared.store.backgroundRefresh()
        }
    }
}

/// Every now and then (at most every 15 minutes, iOS decides) the app looks for new trades in the background and
/// tells about them – there is no push from the agent.
enum BackgroundRefresh {
    static let identifier = "de.achirus.DipAgent.refresh"

    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    /// New trades are announced while the app is open too.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
