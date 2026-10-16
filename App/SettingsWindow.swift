import AppKit
import PasteLensKit
import SwiftUI

/// Settings in an AppKit window with the standard toolbar tabs (an icon above each
/// label), so the Dock menu and the menu bar item can open it (SwiftUI's Settings
/// scene can't be opened from AppKit).
@MainActor
final class SettingsWindow: NSObject, NSWindowDelegate {
    static let shared = SettingsWindow()

    private var window: NSWindow?

    func show() {
        if window == nil {
            let tabs = SettingsTabs()
            let window = NSWindow(contentViewController: tabs)
            window.styleMask = [.titled, .closable]
            window.toolbarStyle = .preference
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {}
}

/// One toolbar item per pane; the window resizes to fit each pane and takes its name
/// as the title, the way macOS's own Settings windows behave.
@MainActor
final class SettingsTabs: NSTabViewController {
    init() {
        super.init(nibName: nil, bundle: nil)
        tabStyle = .toolbar
        transitionOptions = [.crossfade, .allowUserInteraction]
        add("Capture", "text.viewfinder", CaptureSettings())
        add("Translate", "translate", TranslateSettings())
        add("Watch", "eye", WatchSettings())
        add("History", "clock.arrow.circlepath", HistorySettings())
        add("Activity", "chart.bar.xaxis", ActivitySettings())
        add("Shortcuts", "keyboard", ShortcutSettings())
        add("General", "gearshape", GeneralSettings())
    }

    required init?(coder: NSCoder) { fatalError() }

    private func add(_ title: String, _ symbol: String, _ view: some View) {
        let pane = VStack(spacing: 0) {
            view
            Text("\(AppInfo.name) \(AppInfo.displayVersion)")
                .font(.caption).foregroundStyle(.secondary)
                .padding(.bottom, 12)
        }
        .frame(width: 520)
        // Each pane gets its natural height, capped to the screen, with the Form scrolling
        // inside. Letting SwiftUI size the window to the Form's full height crashed once
        // a pane grew taller than the screen: AppKit clamped the window, SwiftUI asked to
        // grow again, and AppKit aborted the update-constraints loop.
        let hosting = NSHostingController(rootView: pane.frame(maxHeight: .infinity))
        hosting.sizingOptions = []
        hosting.title = title
        let item = NSTabViewItem(viewController: hosting)
        item.label = title
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        addTabViewItem(item)
        naturalHeight[item] = { NSHostingView(rootView: pane).fittingSize.height }
        fit(item)
    }

    /// Measures a pane on a throwaway hosting view, so the window never follows SwiftUI.
    private var naturalHeight: [NSTabViewItem: () -> CGFloat] = [:]

    /// Sizes a pane before it's shown (re-measured each time, as panes change), no taller
    /// than the screen.
    private func fit(_ item: NSTabViewItem) {
        guard let height = naturalHeight[item]?() else { return }
        let screen = (isViewLoaded ? view.window?.screen : nil) ?? NSScreen.main
        let available = (screen?.visibleFrame.height ?? 800) - 120
        item.viewController?.preferredContentSize = NSSize(width: 520, height: min(height, available))
    }

    override func tabView(_ tabView: NSTabView, willSelect tabViewItem: NSTabViewItem?) {
        if let tabViewItem { fit(tabViewItem) }
        super.tabView(tabView, willSelect: tabViewItem)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        selectionChanged()
    }

    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        selectionChanged()
    }

    private func selectionChanged() {
        let item = tabViewItems[selectedTabViewItemIndex]
        view.window?.title = item.label
    }
}

/// A slider with its label and current value. While it is being dragged, `onEditing`
/// can turn on a live preview.
struct ValueSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double? = nil
    let format: (Double) -> String
    var onEditing: (Bool) -> Void = { _ in }

    var body: some View {
        LabeledContent(title) {
            HStack {
                // Rounded here rather than with Slider's `step`, which draws a tick
                // mark for every step.
                Slider(value: Binding(get: { value }, set: { new in
                    value = step.map { (new / $0).rounded() * $0 } ?? new
                }), in: range, onEditingChanged: onEditing)
                Text(format(value)).monospacedDigit().frame(width: 58, alignment: .trailing).foregroundStyle(.secondary)
            }
        }
    }
}

private func seconds(_ v: Double) -> String { v < 10 ? String(format: "%.1f s", v) : "\(Int(v)) s" }
private func percent(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }

// MARK: - Capture

struct CaptureSettings: View {
    @State private var prefs = Preferences.shared
    @State private var screenGranted = ScreenAccess.granted
    private let languages = Recognizer.supportedLanguages()

    var body: some View {
        Form {
            if !screenGranted {
                Section {
                    Label("PasteLens needs Screen Recording access to read the screen. Turn on PasteLens in Screen & System Audio Recording.",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Button("Open Privacy Settings") {
                        if !ScreenAccess.request() { ScreenAccess.openSettings() }
                    }
                }
            }
            Section {
                Toggle("Keep line breaks", isOn: $prefs.keepLineBreaks)
                Text(prefs.keepLineBreaks
                     ? "Text is copied line for line, as it appears on screen."
                     : "Lines that wrap are joined into paragraphs; lists, tables and headings keep their own lines.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Additive clipboard", isOn: $prefs.additiveClipboard)
                Text("Each capture is added below what's already on the clipboard, so you can collect several pieces and paste them at once.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Open links automatically", isOn: $prefs.openLinks)
            } header: {
                Text("Copying")
            }
            Section("Recognition") {
                Picker("Language", selection: $prefs.recognitionLanguage) {
                    Text("Automatic").tag("")
                    Divider()
                    ForEach(languages, id: \.code) { Text($0.name).tag($0.code) }
                }
                Toggle("Detect the language automatically", isOn: $prefs.autoDetectLanguage)
                    .disabled(!prefs.recognitionLanguage.isEmpty)
                Picker("Recognition", selection: $prefs.accurateRecognition) {
                    Text("Accurate").tag(true)
                    Text("Fast").tag(false)
                }
                .pickerStyle(.segmented)
                Toggle("Correct spelling with the language's dictionary", isOn: $prefs.languageCorrection)
                LabeledContent("Custom words") {
                    TextField("", text: $prefs.customWords, prompt: Text("e.g. PasteLens, Kubernetes, ibuprofen"))
                }
                Text("Names and jargon, separated by commas. Recognition prefers these over the dictionary.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Feedback") {
                Toggle("Play a sound", isOn: $prefs.playSound)
                Toggle("Show a note when text is copied", isOn: $prefs.showNotice)
                Toggle("Read text aloud after capture", isOn: $prefs.speakAfterCapture)
                ValueSlider(title: "Speaking rate", value: $prefs.speechRate, range: 0.1...0.9, format: percent) { editing in
                    if !editing { Speech.shared.speak("PasteLens reads captured text at this speed.") }
                }
            }
        }
        .formStyle(.grouped)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            screenGranted = ScreenAccess.granted
        }
    }
}

// MARK: - Translate

struct TranslateSettings: View {
    @State private var prefs = Preferences.shared
    @State private var translator = Translator.shared

    var body: some View {
        Form {
            Section {
                Picker("Translate into", selection: $prefs.targetLanguage) {
                    Text("My Mac's language (\(Translator.name(Locale.current.language)))").tag("")
                    Divider()
                    ForEach(translator.languages, id: \.minimalIdentifier) { language in
                        Text(Translator.name(language)).tag(language.minimalIdentifier)
                    }
                }
                Picker("After translating, copy", selection: $prefs.translationCopy) {
                    ForEach(TranslationCopy.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            } footer: {
                Text("Translation runs on this Mac with Apple's translation languages. The first time you use a pair of languages, macOS offers to download them.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                ValueSlider(title: "Check for new text every", value: $prefs.liveInterval, range: 0.5...5, step: 0.5, format: seconds)
                Picker("Show the translation", selection: $prefs.liveCoversOriginal) {
                    Text("In a panel next to the area").tag(false)
                    Text("Over the original text").tag(true)
                }
                .pickerStyle(.radioGroup)
            } header: {
                Text("Live translation")
            } footer: {
                Text("Live translation keeps reading an area, such as subtitles or a chat, and translates whenever its text changes. Press its shortcut again or choose Stop Live Translation to end it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task { await translator.loadLanguages() }
    }
}

// MARK: - Watch

struct WatchSettings: View {
    @State private var prefs = Preferences.shared
    @State private var watches = WatchManager.shared
    @State private var updater = AutoUpdater.shared

    var body: some View {
        Form {
            Section {
                if watches.watches.isEmpty {
                    Text("Nothing is being watched. Choose Watch Area for Changes… from the menu or press \(prefs.watchHotKey?.display ?? "its shortcut"), then drag over the area.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(watches.watches) { watch in
                        LabeledContent {
                            Button("Stop") { watches.stop(watch) }
                        } label: {
                            VStack(alignment: .leading) {
                                Text(watch.name)
                                Text("\(watch.summary.capitalizedFirst) · every \(WatchManager.format(watch.interval)) · \(watch.changes) alert\(watch.changes == 1 ? "" : "s")")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } header: {
                Text("Watched areas")
            }
            Section {
                Toggle("Play a sound when an alert fires", isOn: $prefs.watchSound)
                Toggle("Save each alert to History", isOn: $prefs.watchSaveToHistory)
                Toggle("Outline watched areas on screen", isOn: $prefs.watchShowOutline)
                    .onChange(of: prefs.watchShowOutline) { WatchManager.shared.refreshOutlines() }
                if !updater.notificationsAllowed {
                    LabeledContent {
                        Button("Open Notification Settings") { AutoUpdater.openNotificationSettings() }
                    } label: {
                        Label("Notifications are off for PasteLens, so alerts only play a sound and show in History.",
                              systemImage: "bell.slash").foregroundStyle(.orange)
                    }
                }
            } header: {
                Text("Alerts")
            } footer: {
                Text("Watching reads the area every few seconds on this Mac. Small flickers are ignored: a change has to show up twice in a row before it counts. Watches stop when PasteLens quits.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { updater.refreshNotificationStatus() }
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

// MARK: - History

struct HistorySettings: View {
    @State private var prefs = Preferences.shared
    @State private var store = HistoryStore.shared
    @State private var confirmClear = false

    var body: some View {
        Form {
            Section {
                Toggle("Keep a history of captures", isOn: $prefs.historyEnabled)
                Toggle("Save a picture of each capture", isOn: $prefs.historySaveImages)
                    .disabled(!prefs.historyEnabled)
                Picker("Keep up to", selection: $prefs.historyMaxCount) {
                    ForEach([100, 500, 1000, 5000, 20000], id: \.self) { Text("\($0) captures").tag($0) }
                }
                .onChange(of: prefs.historyMaxCount) { store.prune() }
                Picker("Remove captures older than", selection: $prefs.historyMaxDays) {
                    Text("Never").tag(0)
                    Text("1 day").tag(1); Text("1 week").tag(7); Text("30 days").tag(30); Text("1 year").tag(365)
                }
                .onChange(of: prefs.historyMaxDays) { store.prune() }
            } footer: {
                Text("History stays on this Mac and is never synced. Pinned captures are kept no matter what.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("\(store.entries.count) capture\(store.entries.count == 1 ? "" : "s") saved") {
                    HStack {
                        Button("Show History") { HistoryWindow.shared.show() }
                        Button("Clear…") { confirmClear = true }.disabled(store.entries.isEmpty)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Clear your capture history?", isPresented: $confirmClear) {
            Button("Clear All but Pinned", role: .destructive) { store.clear(keepPinned: true) }
            Button("Clear Everything", role: .destructive) { store.clear(keepPinned: false) }
        } message: {
            Text("Captured text and pictures are deleted from this Mac. This can't be undone.")
        }
    }
}

// MARK: - Shortcuts

struct ShortcutSettings: View {
    @State private var prefs = Preferences.shared

    var body: some View {
        Form {
            Section {
                LabeledContent("Capture text") { ShortcutRecorder(hotKey: $prefs.captureTextHotKey) }
                LabeledContent("Capture the same area again") { ShortcutRecorder(hotKey: $prefs.captureAgainHotKey) }
                LabeledContent("Read QR or bar code") { ShortcutRecorder(hotKey: $prefs.captureCodeHotKey) }
                LabeledContent("Capture and translate") { ShortcutRecorder(hotKey: $prefs.translateHotKey) }
                LabeledContent("Live translate (start/stop)") { ShortcutRecorder(hotKey: $prefs.liveTranslateHotKey) }
                LabeledContent("Watch an area") { ShortcutRecorder(hotKey: $prefs.watchHotKey) }
                LabeledContent("Show history") { ShortcutRecorder(hotKey: $prefs.historyHotKey) }
            } footer: {
                Text("Click a shortcut, then press the new keys. Delete clears it, Esc cancels. Shortcuts need ⌘, ⌥ or ⌃.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - General

struct GeneralSettings: View {
    @State private var prefs = Preferences.shared
    @State private var presence = PresenceSettings.shared
    @State private var login = LaunchAtLogin.shared
    @State private var confirmReset = false
    @State private var sync = SettingsSync.shared
    @State private var updater = AutoUpdater.shared

    private var updateFooter: String {
        switch updater.policy {
        case .automatic:
            "PasteLens checks every 30 minutes. A new version installs itself when no area is being watched or live-translated, PasteLens hasn't been used for 30 minutes, no app is presenting or keeping the screen awake, and your Mac hasn't been used for 2 minutes. You'll get a notification when it's done."
        case .ask:
            "PasteLens checks every 30 minutes and sends a notification when a new version is out. Nothing installs until you choose to."
        case .off:
            "PasteLens won't look for updates on its own. Use Check Now whenever you like."
        }
    }

    var body: some View {
        Form {
            Section("Where PasteLens appears") {
                Toggle("Show in Dock", isOn: $presence.showInDock)
                Toggle("Show in menu bar", isOn: $presence.showInMenuBar)
                if !presence.showInDock && !presence.showInMenuBar {
                    Text(AppPresence.hiddenEverywhereNote(appName: "PasteLens", settingsName: "Settings"))
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            Section {
                Toggle("Open PasteLens at login", isOn: Binding(get: { login.isEnabled }, set: { login.set($0) }))
                if login.needsApproval {
                    Button("Allow in Login Items…") { login.openLoginItemsSettings() }
                }
                if let error = login.lastError {
                    Text(error).font(.callout).foregroundStyle(.red)
                }
            }
            Section {
                Toggle("Sync settings with your other Macs", isOn: $sync.isEnabled)
                if sync.isEnabled {
                    LabeledContent {
                        Button("Sync Now") { sync.syncNow() }
                    } label: {
                        if let error = sync.lastError {
                            Text(error).foregroundStyle(.red)
                        } else if let date = sync.lastSynced {
                            Text("Synced \(date.formatted(date: .omitted, time: .shortened))\(sync.lastSource.map { $0 == SettingsSync.deviceName ? "" : " from \($0)" } ?? "")")
                        } else {
                            Text("Waiting for iCloud Drive…")
                        }
                    }
                }
            } header: {
                Text("iCloud")
            } footer: {
                Text("Shortcuts, recognition, translation and other settings follow you to every Mac signed in to the same iCloud account with sync turned on, and Activity adds up their captures. Your capture history and open at login stay on each Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Picker("When an update is available", selection: $updater.policy) {
                    ForEach(UpdatePolicy.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                if let staged = updater.staged {
                    LabeledContent("Version \(staged.version) is ready") {
                        Button("Install Now") { updater.installNow() }
                    }
                }
                LabeledContent("Version \(AppInfo.displayVersion)") {
                    Button("Check Now") { UpdateController.checkForUpdates() }
                }
                if let error = updater.lastError {
                    Text(error).font(.callout).foregroundStyle(.red)
                }
                if updater.policy != .off && !updater.notificationsAllowed {
                    LabeledContent {
                        Button("Open Notification Settings") { AutoUpdater.openNotificationSettings() }
                    } label: {
                        Label("Notifications are off for PasteLens, so update news only shows in the menu.",
                              systemImage: "bell.slash").foregroundStyle(.orange)
                    }
                }
            } header: {
                Text("Updates")
            } footer: {
                Text(updateFooter).font(.caption).foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("All PasteLens settings") {
                    Button("Reset to Defaults…") { confirmReset = true }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { login.refresh(); updater.refreshNotificationStatus() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            updater.refreshNotificationStatus()
        }
        .confirmationDialog("Reset PasteLens settings?", isPresented: $confirmReset) {
            Button("Reset", role: .destructive) {
                prefs.resetToDefaults()
                HotKeyCenter.shared.apply()
            }
        } message: {
            Text("Shortcuts and options go back to how PasteLens started. Your history, where PasteLens appears and login stay as they are.")
        }
    }
}

/// `AppPresence` values as observable state for Settings.
@Observable
@MainActor
final class PresenceSettings {
    static let shared = PresenceSettings()

    var showInDock = AppPresence.showInDock {
        didSet {
            AppPresence.showInDock = showInDock
            AppPresence.applyDock(keepInFront: NSApp.keyWindow)
        }
    }

    var showInMenuBar = AppPresence.showInMenuBar {
        didSet { AppPresence.showInMenuBar = showInMenuBar }
    }

    /// Follows choices that arrived from another Mac.
    func reload() {
        if showInDock != AppPresence.showInDock { showInDock = AppPresence.showInDock }
        if showInMenuBar != AppPresence.showInMenuBar { showInMenuBar = AppPresence.showInMenuBar }
        // The status item follows the notification, which the setter only posts on a change.
        NotificationCenter.default.post(name: AppPresence.menuBarDidChange, object: nil)
    }
}
