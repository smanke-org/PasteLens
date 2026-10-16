import AppKit
import FoundationModels
import PasteLensKit
import SwiftUI
import UniformTypeIdentifiers

/// A whole-number field: you type the number, it's checked when you press Return or leave the field.
struct NumberField: View {
    let title: String
    @Binding var value: Int
    var zeroMeans: String?
    var range: ClosedRange<Int> = 0...1_000_000
    @State private var text = ""
    @State private var invalid = false
    @FocusState private var focused: Bool

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                TextField("", text: $text, onCommit: commit)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 90)
                    .focused($focused)
                    .onChange(of: focused) { if !focused { commit() } }
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(invalid ? Color.red : .clear))
                if value == 0, let zeroMeans { Text(zeroMeans).foregroundStyle(.secondary) }
            }
        }
        .onAppear { text = value.formatted() }
        .onChange(of: value) { if !focused { text = value.formatted() } }
    }

    private func commit() {
        if let n = RetentionPolicy.parseCount(text), range.contains(n) {
            invalid = false
            value = n
            text = n.formatted()
        } else {
            invalid = true
            NSSound.beep()
        }
    }
}

struct GeneralSettings: View {
    @State private var prefs = Preferences.shared
    @State private var presence = PresenceSettings.shared
    @State private var login = LaunchAtLogin.shared
    @State private var confirmReset = false
    @State private var trusted = Paster.trusted
    #if !APPSTORE
    @State private var updater = AutoUpdater.shared
    #endif

    var body: some View {
        Form {
            Section {
                LabeledContent {
                    if trusted { Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
                    else { Button("Allow…") { Paster.requestAccess(); Paster.openAccessibilitySettings() } }
                } label: {
                    Text("Paste into other apps")
                    Text("Needs Accessibility permission. Without it, PasteLens copies and you press ⌘V yourself.").font(.caption)
                }
            }
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
                if login.needsApproval { Button("Allow in Login Items…") { login.openLoginItemsSettings() } }
                if let error = login.lastError { Text(error).font(.callout).foregroundStyle(.red) }
                Toggle("Play sounds", isOn: $prefs.sounds)
                Toggle("Pause recording", isOn: $prefs.paused)
            }
            #if !APPSTORE
            Section {
                Picker("When an update is available", selection: $updater.policy) {
                    ForEach(UpdatePolicy.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                if let staged = updater.staged {
                    LabeledContent("Version \(staged.version) is ready") { Button("Install Now") { updater.installNow() } }
                }
                LabeledContent("Version \(AppInfo.displayVersion)") { Button("Check Now") { UpdateController.checkForUpdates() } }
                if let error = updater.lastError { Text(error).font(.callout).foregroundStyle(.red) }
                if updater.policy != .off && !updater.notificationsAllowed {
                    LabeledContent {
                        Button("Open Notification Settings") { AutoUpdater.openNotificationSettings() }
                    } label: {
                        Label("Notifications are off for PasteLens, so update news only shows in the menu.", systemImage: "bell.slash").foregroundStyle(.orange)
                    }
                }
            } header: { Text("Updates") } footer: {
                Text(updater.policy == .automatic
                     ? "New versions install themselves when Quick Paste is closed, the stack is empty, nothing is syncing, and your Mac has been idle for 2 minutes."
                     : updater.policy == .ask ? "PasteLens checks every 30 minutes and tells you when a new version is out." : "Use Check Now whenever you like.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            #endif
            Section {
                LabeledContent("All PasteLens settings") { Button("Reset to Defaults…") { confirmReset = true } }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            login.refresh()
            trusted = Paster.trusted
            #if !APPSTORE
            updater.refreshNotificationStatus()
            #endif
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            trusted = Paster.trusted
            #if !APPSTORE
            updater.refreshNotificationStatus()
            #endif
        }
        .confirmationDialog("Reset PasteLens settings?", isPresented: $confirmReset) {
            Button("Reset", role: .destructive) {
                prefs.resetToDefaults()
                HotKeyCenter.shared.apply()
            }
        } message: {
            Text("Shortcuts and options go back to how PasteLens started. Your clippings, pastebins, filters and snippets stay.")
        }
    }
}

struct HistorySettings: View {
    @State private var prefs = Preferences.shared
    @State private var store = ClipStore.shared
    @State private var confirmClear = false

    var body: some View {
        Form {
            Section {
                Toggle("Unlimited history", isOn: $prefs.unlimited)
                NumberField(title: "Clippings to keep", value: $prefs.maxClippings, zeroMeans: "keep all")
                    .disabled(prefs.unlimited)
                NumberField(title: "Days to keep", value: $prefs.maxDays, zeroMeans: "forever", range: 0...36_500)
                    .disabled(prefs.unlimited)
                LabeledContent("Ignore clippings larger than") {
                    HStack {
                        TextField("", value: $prefs.maxClipMB, format: .number).multilineTextAlignment(.trailing).frame(width: 70)
                        Text("MB")
                    }
                }
            } header: { Text("History") } footer: {
                Text(prefs.unlimited
                     ? "History now holds \(store.history.count.formatted()) clipping\(store.history.count == 1 ? "" : "s"), and nothing is removed however many there are or however old they get. Turn this off to use the limits again."
                     : "History now holds \(store.history.count.formatted()) clipping\(store.history.count == 1 ? "" : "s"). The oldest go first once there are more than you keep. Pinned clippings and those saved in a pastebin are never removed. Type 0 to keep everything.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .onChange(of: prefs.maxClippings) { store.pruneHistory() }
            .onChange(of: prefs.maxDays) { store.pruneHistory() }
            .onChange(of: prefs.unlimited) { store.pruneHistory() }
            Section("Record") {
                Toggle("Images", isOn: $prefs.captureImages)
                Toggle("Files and folders", isOn: $prefs.captureFiles)
            }
            Section {
                ForEach(prefs.ignoredApps, id: \.self) { bundleID in
                    HStack {
                        if let icon = AppIcons.icon(for: bundleID) { Image(nsImage: icon).resizable().frame(width: 18, height: 18) }
                        Text(appName(bundleID))
                        Spacer()
                        Button { prefs.ignoredApps.removeAll { $0 == bundleID } } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                    }
                }
                Button("Add App…", action: addApp)
            } header: { Text("Ignore copies from these apps") } footer: {
                Text("Password managers that mark what they copy as private (1Password, Bitwarden and others) are already ignored.").font(.caption).foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("Everything in History") { Button("Clear History…") { confirmClear = true } }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Clear History?", isPresented: $confirmClear) {
            Button("Clear History", role: .destructive) { store.clearHistory() }
        } message: { Text("Pinned clippings and those saved in a pastebin stay.") }
    }

    func appName(_ bundleID: String) -> String {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? bundleID
    }

    func addApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if let id = Bundle(url: url)?.bundleIdentifier, !prefs.ignoredApps.contains(id) { prefs.ignoredApps.append(id) }
        }
    }
}

struct QuickPasteSettings: View {
    @State private var prefs = Preferences.shared

    var body: some View {
        Form {
            Section {
                Picker("Open at", selection: $prefs.quickPasteAtMouse) {
                    Text("The pointer").tag(true)
                    Text("The center of the screen").tag(false)
                }
                Picker("Lines per clipping", selection: $prefs.rowLines) {
                    Text("1").tag(1); Text("2").tag(2); Text("3").tag(3)
                }
            }
            Section {
                Toggle("Release to paste", isOn: $prefs.releaseToPaste)
                Text("Hold the shortcut's modifier keys, press its letter again to move down the list, and let go to paste — like switching apps with ⌘⇥.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Always paste as plain text", isOn: $prefs.alwaysPlain)
                Toggle("Move pasted clippings to the top of History", isOn: $prefs.moveToTop)
            }
            Section("Keys in Quick Paste") {
                Grid(alignment: .leading, verticalSpacing: 4) {
                    ForEach([("↩", "Paste"), ("⇧↩", "Paste as plain text"), ("⌥↩", "Type it out (for fields that block pasting)"),
                             ("⌘↩", "Choose a filter, then ↩ to paste the result"), ("⌘1 – ⌘9", "Paste that clipping"),
                             ("⇥ / ⇧⇥", "Next / previous pastebin"), ("⌘C", "Copy without pasting"), ("⌘S", "Add to stack"),
                             ("⌘P", "Pin"), ("⌘⌫", "Delete"), ("⌘O", "Open in the PasteLens window"), ("⎋", "Close")], id: \.0) { key, text in
                        GridRow { Text(key).font(.body.monospaced()).gridColumnAlignment(.trailing); Text(text) }
                    }
                }.font(.callout)
            }
        }
        .formStyle(.grouped)
    }
}

struct ShortcutSettings: View {
    @State private var prefs = Preferences.shared
    @State private var warning: String?

    var body: some View {
        Form {
            Section {
                ForEach(HotKeyAction.allCases) { action in
                    LabeledContent {
                        ShortcutRecorder(hotKey: Binding(get: { prefs.hotKey(action) }, set: { key in
                            if let key, let owner = HotKeyCenter.shared.owner(of: key), owner != action.title {
                                warning = "\(key.display) was already used by \(owner)."
                            } else { warning = nil }
                            prefs.setHotKey(key, for: action)
                        }))
                    } label: {
                        Text(action.title)
                        Text(action.detail).font(.caption)
                    }
                }
            } footer: {
                VStack(alignment: .leading) {
                    if let warning { Text(warning).foregroundStyle(.orange) }
                    Text("Click a shortcut, then press the new keys. Delete clears it. Pastebins, filters and single clippings can have their own shortcuts too — set them where you edit each one.")
                }.font(.caption)
            }
            Section {
                Button("Restore Default Shortcuts") {
                    for action in HotKeyAction.allCases { prefs.setHotKey(action.defaultKey, for: action) }
                    HotKeyCenter.shared.apply()
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct PrivacySettings: View {
    @State private var prefs = Preferences.shared

    var aiStatus: String {
        switch SystemLanguageModel.default.availability {
        case .available: "Apple Intelligence filters are ready."
        case .unavailable(.appleIntelligenceNotEnabled): "Turn on Apple Intelligence in System Settings to use AI filters."
        case .unavailable(.modelNotReady): "Apple Intelligence is still downloading its model."
        case .unavailable(.deviceNotEligible): "This Mac doesn't support Apple Intelligence, so AI filters won't run."
        default: "Apple Intelligence isn't available."
        }
    }

    var body: some View {
        Form {
            Section {
                Toggle("Detect secrets", isOn: $prefs.detectSensitive)
                if prefs.detectSensitive {
                    Stepper("Delete them after \(prefs.sensitiveMinutes) minute\(prefs.sensitiveMinutes == 1 ? "" : "s")",
                            value: $prefs.sensitiveMinutes, in: 1...240)
                }
            } header: { Text("Secrets") } footer: {
                Text("API keys and tokens, private keys, card numbers, one-time codes and password-like text are hidden in lists, never synced, and deleted soon after. Detection happens on this Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Recognize text in images", isOn: $prefs.ocr)
                Toggle("Show link previews", isOn: $prefs.linkPreviews)
            } footer: {
                Text("Text recognition runs on this Mac, so screenshots become searchable. Link previews fetch the page's title and image from the web.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Apple Intelligence") {
                Text(aiStatus).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct SnippetSettings: View {
    @State private var prefs = Preferences.shared
    @State private var granted = SnippetExpander.inputMonitoringGranted

    var body: some View {
        Form {
            Section {
                Toggle("Expand abbreviations as you type", isOn: $prefs.expansion)
                    .onChange(of: prefs.expansion) { SnippetExpander.shared.refresh(); granted = SnippetExpander.inputMonitoringGranted }
                if prefs.expansion && !granted {
                    LabeledContent {
                        Button("Open Settings") {
                            SnippetExpander.requestInputMonitoring()
                            if let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ListenEvent") { NSWorkspace.shared.open(url) }
                        }
                    } label: {
                        Label("Allow Input Monitoring for PasteLens, then quit and reopen it.", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    }
                }
            } footer: {
                Text("Type a snippet's abbreviation (such as ;sig) in any app and PasteLens replaces it with the snippet. Keystrokes are only compared with your abbreviations, never stored, and password fields are skipped.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Button("Edit Snippets…") {
                    MainWindow.shared.state.section = .snippets
                    MainWindow.shared.show()
                }
            }
        }
        .formStyle(.grouped)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            granted = SnippetExpander.inputMonitoringGranted
        }
    }
}

struct SyncSettings: View {
    @State private var sync = SyncEngine.shared
    @State private var prefs = Preferences.shared
    @State private var passphrase = ""
    @State private var confirm = ""
    @State private var working = false
    @State private var error: String?
    @State private var changing = false
    @State private var confirmDelete = false

    var joining: Bool { sync.keyringExists }
    var ready: Bool {
        if joining { return !passphrase.isEmpty }
        return passphrase.count >= 8 && passphrase == confirm
    }

    var body: some View {
        Form {
            if sync.enabled, sync.status != .needsPassphrase {
                Section {
                    LabeledContent("Status") {
                        HStack {
                            Text(sync.status.summary).foregroundStyle(statusColor)
                            if let last = sync.lastSync { Text("· \(last.formatted(date: .omitted, time: .shortened))").foregroundStyle(.secondary) }
                        }
                    }
                    if sync.pendingContent > 0 { LabeledContent("Transferring", value: "\(sync.pendingContent) clipping\(sync.pendingContent == 1 ? "" : "s")") }
                    LabeledContent("Folder", value: sync.folderDescription)
                    Button("Sync Now") { sync.pull() }
                }
                Section("Other Macs") {
                    if sync.devices.isEmpty {
                        Text("None yet. Turn on sync on your other Macs with the same passphrase.").foregroundStyle(.secondary)
                    }
                    ForEach(sync.devices) { device in
                        LabeledContent(device.name, value: "seen \(device.lastSeen.formatted(.relative(presentation: .named)))")
                    }
                }
                Section {
                    Toggle("Sync clippings", isOn: $prefs.syncContents)
                        .onChange(of: prefs.syncContents) { if prefs.syncContents { sync.uploadAllContent() }; sync.libraryChanged() }
                    LabeledContent("Don't sync clippings larger than") {
                        HStack {
                            TextField("", value: $prefs.syncMaxClipMB, format: .number).multilineTextAlignment(.trailing).frame(width: 70)
                            Text("MB")
                        }
                    }
                } footer: {
                    Text("Settings, pastebins, smart pastebins, filters and snippets always sync. Secrets never do.").font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    if changing {
                        SecureField("New passphrase", text: $passphrase)
                        SecureField("Confirm", text: $confirm)
                        HStack {
                            Button("Cancel") { changing = false; passphrase = ""; confirm = "" }
                            Button("Change Passphrase") { changePassphrase() }.disabled(passphrase.count < 8 || passphrase != confirm)
                        }
                    } else {
                        Button("Change Passphrase…") { changing = true }
                    }
                    Button("Turn Off Sync on This Mac") { sync.turnOff() }
                    Button("Delete Synced Data from iCloud…", role: .destructive) { confirmDelete = true }
                }
            } else {
                setup
            }
            if let error { Section { Text(error).foregroundStyle(.red) } }
            Section {
                Text("""
                Everything PasteLens puts in iCloud is encrypted on this Mac with AES-256-GCM before upload. \
                The key is protected by your sync passphrase (PBKDF2-SHA256, 600,000 rounds), which never leaves your Macs, \
                so Apple can't read your clippings. If you forget the passphrase, delete the synced data and start again; \
                what's on each Mac stays.
                """).font(.caption).foregroundStyle(.secondary)
            } header: { Text("Encryption") }
        }
        .formStyle(.grouped)
        .onAppear { if !sync.enabled || sync.status == .needsPassphrase { sync.probe() } }
        .confirmationDialog("Delete synced data?", isPresented: $confirmDelete) {
            Button("Delete from iCloud", role: .destructive) { sync.deleteCloudData() }
        } message: {
            Text("PasteLens's encrypted files are removed from iCloud Drive. Clippings on each Mac stay. Other Macs stop syncing until you set up again.")
        }
    }

    var statusColor: Color {
        switch sync.status {
        case .failed, .unavailable: .red
        default: .primary
        }
    }

    @ViewBuilder var setup: some View {
        Section {
            if case .unavailable(let why) = sync.status {
                Label(why, systemImage: "exclamationmark.icloud").foregroundStyle(.orange)
            }
            Text(joining
                 ? "Another Mac already syncs PasteLens. Enter the passphrase you chose there."
                 : "Choose a passphrase. You'll enter the same one on each Mac you want to sync. It isn't stored in iCloud.")
            SecureField("Passphrase", text: $passphrase)
            if !joining {
                SecureField("Confirm passphrase", text: $confirm)
                if !passphrase.isEmpty && passphrase.count < 8 { Text("At least 8 characters.").font(.caption).foregroundStyle(.secondary) }
                else if !confirm.isEmpty && confirm != passphrase { Text("The passphrases don't match.").font(.caption).foregroundStyle(.red) }
            }
            HStack {
                Spacer()
                if working { ProgressView().controlSize(.small) }
                Button(joining ? "Join and Sync" : "Turn On Sync") { setUp() }.disabled(!ready || working).keyboardShortcut(.defaultAction)
            }
        } header: {
            Text("Sync with your other Macs through iCloud Drive")
        }
    }

    func setUp() {
        working = true
        error = nil
        Task {
            do {
                try await sync.setUp(passphrase: passphrase)
                passphrase = ""
                confirm = ""
            } catch {
                self.error = error.localizedDescription
            }
            working = false
        }
    }

    func changePassphrase() {
        Task {
            do {
                try await sync.changePassphrase(to: passphrase)
                changing = false
                passphrase = ""
                confirm = ""
                error = nil
            } catch { self.error = error.localizedDescription }
        }
    }
}

struct AdvancedSettings: View {
    @State private var report: String?
    @State private var copied = false

    var helpers: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers") }
    var mcpConfig: String {
        """
        {
          "mcpServers": {
            "pastelens": { "command": "\(helpers.appendingPathComponent("pastelens-mcp").path)" }
          }
        }
        """
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Pastebot") {
                    HStack {
                        Button("Import Clippings…") { Importer.importPastebotHistory() }.disabled(!Importer.pastebotInstalled)
                        Button("Import Filters…") { importFilters() }
                    }
                }
                if !Importer.pastebotInstalled { Text("Pastebot's data wasn't found on this Mac.").font(.caption).foregroundStyle(.secondary) }
            } header: { Text("Import") }
            Section {
                LabeledContent("Command-line tool") {
                    Button("Copy Install Command") {
                        Paster.write(text: "sudo ln -sf \"\(helpers.appendingPathComponent("pastelens").path)\" /usr/local/bin/pastelens")
                        copied = true
                    }
                }
                Text("Paste it in Terminal. Then `pastelens get-clippings --query invoice`, `pastelens apply-filter --filter-id \"Title Case\" --text \"hello\"`, and more; `pastelens help` lists them all.")
                    .font(.caption).foregroundStyle(.secondary)
                LabeledContent("MCP server for AI assistants") {
                    Button("Copy Configuration") { Paster.write(text: mcpConfig); copied = true }
                }
                Text("Add it to Claude Desktop's or another MCP client's configuration, so the assistant can search your clippings, run filters and paste.")
                    .font(.caption).foregroundStyle(.secondary)
                if copied { Text("Copied.").font(.caption).foregroundStyle(.green) }
            } header: { Text("Automation") } footer: {
                Text("Shortcuts actions are in the Shortcuts app under PasteLens. The URL scheme pastelens://quickpaste, pastelens://open, pastelens://stack and pastelens://paste?text=… works from anywhere.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Folders") {
                LabeledContent("Scripts for filters") { Button("Open") { ApplicationScripts.reveal() } }
                LabeledContent("PasteLens data") { Button("Show in Finder") { NSWorkspace.shared.open(ClipStore.shared.folder) } }
            }
        }
        .formStyle(.grouped)
        .alert("Import", isPresented: Binding(get: { report != nil }, set: { if !$0 { report = nil } })) { Button("OK") {} } message: { Text(report ?? "") }
    }

    func importFilters() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [UTType(filenameExtension: "pastebotfilter") ?? .data, UTType(filenameExtension: "pastelensfilter") ?? .data]
        guard panel.runModal() == .OK else { return }
        report = Importer.importFilters(panel.urls)
    }
}
