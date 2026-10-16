import Foundation

/// Where PasteLens keeps its settings. Normally the app's own defaults; a test copy can be
/// given a separate store (PASTELENS_DEFAULTS_SUITE), so two copies on one Mac behave like two Macs.
enum AppDefaults {
    static let store: UserDefaults = {
        if let suite = ProcessInfo.processInfo.environment["PASTELENS_DEFAULTS_SUITE"], let separate = UserDefaults(suiteName: suite) {
            return separate
        }
        return .standard
    }()
}
