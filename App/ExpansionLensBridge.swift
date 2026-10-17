import AppKit
import UserNotifications

/// Keeps PasteLens and ExpansionLens from both expanding abbreviations.
///
/// Each app announces its expansion switch with a distributed notification. When both are
/// expanding, PasteLens says so once per launch with a notification whose button turns its own
/// expansion off, and the Snippets settings show the same warning. ExpansionLens can also ask
/// PasteLens to turn expansion off, which is the same as unchecking the box here.
@Observable
@MainActor
final class ExpansionLensBridge {
    static let shared = ExpansionLensBridge()

    nonisolated static let expansionLensID = "com.smanke.ExpansionLens"
    /// Posted by PasteLens when it launches or its expansion setting changes.
    static let pasteLensChanged = Notification.Name("com.smanke.PasteLens.expansionChanged")
    /// ExpansionLens asking PasteLens to turn its expansion off.
    static let disableRequest = Notification.Name("com.smanke.PasteLens.disableExpansion")
    /// Posted by ExpansionLens when it starts or stops expanding.
    static let expansionLensChanged = Notification.Name("com.smanke.ExpansionLens.expansionChanged")
    nonisolated static let category = "expansionlens"
    nonisolated static let turnOffAction = "turnOff"

    private(set) var conflict = false
    @ObservationIgnored private var warnedThisLaunch = false
    /// What ExpansionLens last announced; nil until it does (or once it quits).
    @ObservationIgnored private var announced: Bool?

    func start() {
        let center = DistributedNotificationCenter.default()
        center.addObserver(forName: Self.expansionLensChanged, object: nil, queue: .main) { note in
            let enabled = (note.userInfo?["enabled"] as? String).map { $0 == "1" }
            MainActor.assumeIsolated {
                let bridge = ExpansionLensBridge.shared
                // The first word from the other app gets an answer, in case it missed ours.
                let firstWord = bridge.announced == nil
                bridge.announced = enabled
                if firstWord { bridge.announce() } else { bridge.check() }
            }
        }
        center.addObserver(forName: Self.disableRequest, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                NSLog("PasteLens: ExpansionLens asked to turn abbreviation expansion off")
                Preferences.shared.expansion = false
                SnippetExpander.shared.refresh()
            }
        }
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { note in
                let id = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
                guard id == ExpansionLensBridge.expansionLensID else { return }
                MainActor.assumeIsolated { ExpansionLensBridge.shared.announced = nil }
                // Say where this app stands once the other is up, then look again.
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { MainActor.assumeIsolated { ExpansionLensBridge.shared.announce() } }
            }
        }
        announce()
    }

    /// Tells ExpansionLens whether PasteLens is expanding, then looks for a clash.
    func announce() {
        DistributedNotificationCenter.default().postNotificationName(Self.pasteLensChanged, object: nil,
                                                                     userInfo: ["enabled": Preferences.shared.expansion ? "1" : "0"],
                                                                     deliverImmediately: true)
        check()
    }

    static var expansionLensRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: expansionLensID).isEmpty
    }

    /// ExpansionLens's own switch: what it last announced, otherwise its preferences (on unless turned off).
    var expansionLensExpanding: Bool {
        if let announced { return announced }
        CFPreferencesAppSynchronize(Self.expansionLensID as CFString)
        return (CFPreferencesCopyAppValue("expansion.enabled" as CFString, Self.expansionLensID as CFString) as? Bool) ?? true
    }

    func check() {
        let now = Preferences.shared.expansion && Self.expansionLensRunning && expansionLensExpanding
        if now != conflict {
            conflict = now
            NSLog("PasteLens: ExpansionLens \(now ? "is also" : "is no longer") expanding abbreviations")
        }
        if now, !warnedThisLaunch {
            warnedThisLaunch = true
            notify()
        }
    }

    func turnOff() {
        Preferences.shared.expansion = false
        SnippetExpander.shared.refresh()
    }

    private func notify() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "ExpansionLens is also expanding abbreviations"
            content.body = "Both apps would expand the same abbreviations. Turn off abbreviation expansion in PasteLens and keep your snippets in ExpansionLens."
            content.categoryIdentifier = ExpansionLensBridge.category
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "expansionlens-conflict", content: content, trigger: nil))
        }
    }

    static var notificationCategory: UNNotificationCategory {
        UNNotificationCategory(identifier: category,
                               actions: [UNNotificationAction(identifier: turnOffAction, title: "Turn Off in PasteLens", options: [])],
                               intentIdentifiers: [])
    }

    /// A click on the notification (opens the Snippets settings) or its button.
    static func handle(action: String) {
        if action == turnOffAction { shared.turnOff() } else { SettingsWindow.shared.show(tab: "Snippets") }
    }
}
