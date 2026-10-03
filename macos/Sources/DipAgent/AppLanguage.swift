import AppKit
import DipAgentKit

/// App language: follows macOS unless the user picks one in Settings → App → Language.
/// macOS reads the per-app `AppleLanguages` preference at launch, so a change needs a restart.
extension AppLanguage {
    /// The override that was active when the app was launched ("" = system).
    static let atLaunch: String = override ?? ""

    /// "en"/"de" if the user chose a language in the app, nil = follow macOS.
    static var override: String? {
        get {
            guard let id = Bundle.main.bundleIdentifier,
                  let languages = UserDefaults.standard.persistentDomain(forName: id)?["AppleLanguages"] as? [String]
            else { return nil }
            return languages.first
        }
        set {
            if let newValue {
                UserDefaults.standard.set([newValue], forKey: "AppleLanguages")
            } else {
                UserDefaults.standard.removeObject(forKey: "AppleLanguages")
            }
        }
    }

    static func relaunch() {
        let path = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 1; /usr/bin/open \"\(path)\""]
        try? task.run()
        NSApp.terminate(nil)
    }
}
