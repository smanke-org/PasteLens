import AppKit

/// Password managers PasteLens ignores out of the box when they're installed. Most of
/// them already mark what they copy as private, which PasteLens honors; listing them
/// also covers the ones that don't, and anything copied from their windows.
@MainActor
enum PasswordApps {
    static let known: [String] = [
        "com.1password.1password",          // 1Password 8
        "com.agilebits.onepassword7",       // 1Password 7
        "com.apple.Passwords",              // Passwords
        "com.apple.keychainaccess",         // Keychain Access
        "com.bitwarden.desktop",            // Bitwarden
        "com.dashlane.dashlanephonefinal",  // Dashlane
        "com.lastpass.LastPass",            // LastPass
        "org.keepassxc.keepassxc",          // KeePassXC
        "com.hicknhacksoftware.MacPass",    // MacPass
        "com.markmcguill.strongbox.mac",    // Strongbox
        "in.sinew.Enpass-Desktop",          // Enpass
        "me.proton.pass.electron",          // Proton Pass
        "com.nordsec.nordpass",             // NordPass
        "com.keepersecurity.passwordmanager", // Keeper
        "com.roboform.mac",                 // RoboForm
    ]

    /// Apps already offered once, so one you take off the list stays off. Kept per Mac,
    /// since what's installed differs between Macs.
    private static let offeredKey = "history.passwordAppsOffered"

    /// Adds each installed password manager to the ignore list the first time it's seen.
    static func addInstalled() {
        let defaults = UserDefaults.standard
        var offered = Set(defaults.stringArray(forKey: offeredKey) ?? [])
        let prefs = Preferences.shared
        var ignored = prefs.ignoredApps
        for id in known where !offered.contains(id) {
            guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) != nil else { continue }
            offered.insert(id)
            if !ignored.contains(id) { ignored.append(id) }
        }
        defaults.set(Array(offered).sorted(), forKey: offeredKey)
        if ignored != prefs.ignoredApps { prefs.ignoredApps = ignored }
    }
}
