import Foundation

/// The language the app runs in. macOS adds a language picker on top of it (the iPhone uses the system's
/// per-app language setting).
public enum AppLanguage {
    /// Language the running app actually uses ("en" or "de") – also sent to the agent as Accept-Language.
    public static let current: String = Bundle.main.preferredLocalizations.first ?? "en"
}
