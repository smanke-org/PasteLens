import Foundation

/// Where PasteLens keeps its settings. Normally the app's own defaults; a test copy can be
/// given a separate store (PASTELENS_DEFAULTS_SUITE), so two copies on one Mac behave like two Macs.
/// A Debug agent CLI test copy (`APP_STORE=<folder>`) always gets its own suite.
enum AppDefaults {
    static let store: UserDefaults = {
        #if DEBUG
        if AgentSocket.isTestRun, ProcessInfo.processInfo.environment["PASTELENS_DEFAULTS_SUITE"] == nil,
           let separate = UserDefaults(suiteName: agentTestSuite) {
            return separate
        }
        #endif
        if let suite = ProcessInfo.processInfo.environment["PASTELENS_DEFAULTS_SUITE"], let separate = UserDefaults(suiteName: suite) {
            return separate
        }
        return .standard
    }()

    #if DEBUG
    static let agentTestSuite = "com.smanke.PasteLens.agenttest"
    #endif
}
