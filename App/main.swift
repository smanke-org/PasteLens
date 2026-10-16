import AppKit
import PasteLensKit
import SwiftUI

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(AppPresence.showInDock ? .regular : .accessory)
    app.run()
}

/// Launch, the menu bar item, the Dock menu, URLs and shortcuts.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private var pruneTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = mainMenu()
        let newInstall = !UserDefaults.standard.bool(forKey: "welcomed")

        _ = ClipStore.shared
        PasswordApps.addInstalled()
        ClipboardMonitor.shared.start()
        HotKeyCenter.shared.perform = { [weak self] target in self?.perform(target) }
        HotKeyCenter.shared.apply()
        SnippetExpander.shared.refresh()
        SyncEngine.shared.start()
        BridgeHandler.start()

        setUpStatusItem()
        NotificationCenter.default.addObserver(forName: AppPresence.menuBarDidChange, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { [weak self] in self?.statusItem?.isVisible = AppPresence.showInMenuBar }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { SyncEngine.shared.pull() }
        }
        // A password manager installed later is picked up the first time it runs.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { note in
            let id = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            MainActor.assumeIsolated { if let id, PasswordApps.known.contains(id) { PasswordApps.addInstalled() } }
        }

        // Expired secrets and history limits are checked every minute.
        ClipStore.shared.pruneHistory()
        pruneTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            MainActor.assumeIsolated { ClipStore.shared.pruneHistory() }
        }

        #if !APPSTORE
        AutoUpdater.shared.start()
        #endif
        if newInstall {
            UserDefaults.standard.set(true, forKey: "welcomed")
            WelcomeWindow.shared.show()
        } else if !AppPresence.showInMenuBar && !AppPresence.showInDock {
            SettingsWindow.shared.show()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        ClipStore.shared.saveNow()
        BridgeHandler.stop()
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = AppPresence.dockMenu(title: "Settings…", target: self, action: #selector(showSettings))
        menu.insertItem(.separator(), at: 0)
        menu.insertItem(item("Open PasteLens", #selector(showMain)), at: 0)
        menu.insertItem(item("Quick Paste", #selector(quickPaste)), at: 0)
        return menu
    }

    /// Opening the app again (from Applications, Spotlight, or the Dock tile) shows the library.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !AppPresence.showInMenuBar && !AppPresence.showInDock { SettingsWindow.shared.show() } else { MainWindow.shared.show() }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// pastelens:// URLs, and filter files opened with PasteLens.
    func application(_ application: NSApplication, open urls: [URL]) {
        let files = urls.filter(\.isFileURL)
        if !files.isEmpty {
            let report = Importer.importFilters(files)
            let alert = NSAlert()
            alert.messageText = "Import Filters"
            alert.informativeText = report
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
        for url in urls where url.scheme == "pastelens" { handle(url) }
    }

    private func handle(_ url: URL) {
        let query = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        switch url.host {
        case "quickpaste": QuickPastePanel.shared.show()
        case "open": MainWindow.shared.show()
        case "stack": StackWindow.shared.show()
        case "settings": SettingsWindow.shared.show()
        case "snippets": QuickPastePanel.shared.show(source: .snippets)
        case "copy", "paste":
            guard let text = query["text"] else { return }
            ClipStore.shared.add(.text(text), source: (nil, "URL"))
            url.host == "paste" ? Paster.paste(text: text) : Paster.write(text: text)
        default: MainWindow.shared.show()
        }
    }

    private func perform(_ target: HotKeyCenter.Target) {
        Activity.shared.touch()
        switch target {
        case .action(let action):
            switch action {
            case .quickPaste: QuickPastePanel.shared.toggle(viaHotKey: true)
            case .mainWindow: MainWindow.shared.show()
            case .pastePlain:
                if let text = NSPasteboard.general.string(forType: .string) { Paster.write(text: text); Paster.pasteClipboard(after: 0.05) }
            case .pasteFromStack: StackController.shared.pasteNext()
            case .showStack: StackWindow.shared.toggle()
            case .addToStack: StackController.shared.copySelectionToStack()
            case .togglePause: Preferences.shared.paused.toggle()
            case .snippets: QuickPastePanel.shared.toggle(source: .snippets, viaHotKey: true)
            }
        case .pastebin(let id):
            let isSmart = ClipStore.shared.library.smartPastebins.contains { $0.id == id }
            QuickPastePanel.shared.toggle(source: isSmart ? .smart(id) : .pastebin(id), viaHotKey: true)
        case .filter(let id):
            // Filters the clipboard and pastes the result.
            guard let filter = ClipStore.shared.library.filters.first(where: { $0.id == id }),
                  let text = NSPasteboard.general.string(forType: .string) else { SoundPlayer.play(.error); return }
            Task {
                do { Paster.paste(text: try await FilterRunner.run(filter, on: text, services: AppFilterServices())) }
                catch { SoundPlayer.play(.error); NSLog("PasteLens: filter failed: \(error.localizedDescription)") }
            }
        case .clipping(let id):
            if let clip = ClipStore.shared.clip(id) { Paster.paste(clip) }
        }
    }

    // MARK: Menus

    private func mainMenu() -> NSMenu {
        let menu = AppPresence.mainMenu(appName: AppInfo.name, settingsTitle: "Settings…", target: self, settings: #selector(showSettings))
        // Edit menu, so text fields get copy, paste and undo.
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Delete", action: #selector(NSText.delete(_:)), keyEquivalent: "")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Find", action: #selector(NSResponder.performTextFinderAction(_:)), keyEquivalent: "f").tag = 1
        editItem.submenu = edit
        menu.insertItem(editItem, at: 1)
        return menu
    }

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        item.isVisible = AppPresence.showInMenuBar
        let image = NSImage(systemSymbolName: "list.clipboard", accessibilityDescription: AppInfo.name)
        image?.isTemplate = true
        item.button?.image = image
        statusItem = item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let prefs = Preferences.shared
        statusItem?.button?.appearsDisabled = prefs.paused

        if !Paster.trusted {
            let warn = item("Allow Pasting into Apps…", #selector(allowAccessibility))
            warn.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: nil)
            menu.addItem(warn)
            menu.addItem(.separator())
        }

        menu.addItem(item("Quick Paste", #selector(quickPaste), hotKey: prefs.hotKey(.quickPaste), symbol: "magnifyingglass"))
        menu.addItem(item("Open PasteLens", #selector(showMain), hotKey: prefs.hotKey(.mainWindow), symbol: "macwindow"))

        let recent = Array(ClipStore.shared.history.prefix(10))
        if !recent.isEmpty {
            menu.addItem(.separator())
            let header = NSMenuItem(title: "Recent", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for (index, clip) in recent.enumerated() {
                let title = clip.sensitive ? (clip.title ?? "Sensitive") + " ••••" : String(clip.displayTitle.prefix(48))
                let entry = item(title, #selector(copyRecent(_:)), key: index < 9 ? "\(index + 1)" : "")
                entry.keyEquivalentModifierMask = []
                entry.representedObject = clip.id
                entry.image = NSImage(systemSymbolName: clip.kind.symbol, accessibilityDescription: nil)
                entry.toolTip = "Copy"
                menu.addItem(entry)
            }
        }

        menu.addItem(.separator())
        let stackCount = StackController.shared.items.count
        menu.addItem(item(stackCount > 0 ? "Stack (\(stackCount))" : "Stack", #selector(showStack), hotKey: prefs.hotKey(.showStack), symbol: "square.stack.3d.up"))
        let pause = item(prefs.paused ? "Resume Recording" : "Pause Recording", #selector(togglePause), hotKey: prefs.hotKey(.togglePause),
                         symbol: prefs.paused ? "play.circle" : "pause.circle")
        menu.addItem(pause)
        if let skipped = ClipboardMonitor.shared.lastSkipped {
            let note = NSMenuItem(title: "Skipped a large clipping (\(skipped))", action: nil, keyEquivalent: "")
            note.isEnabled = false
            menu.addItem(note)
        }
        if SyncEngine.shared.enabled {
            let status = NSMenuItem(title: "iCloud: \(SyncEngine.shared.status.summary)", action: #selector(showSyncSettings), keyEquivalent: "")
            status.target = self
            menu.addItem(status)
        }

        menu.addItem(.separator())
        menu.addItem(item("Settings…", #selector(showSettings), key: ","))
        #if !APPSTORE
        if let staged = AutoUpdater.shared.staged {
            menu.addItem(item("Update to \(staged.version) Now (Otherwise Installs When Idle)", #selector(installUpdateNow)))
        } else if let pending = UpdateAvailability.shared.pending {
            menu.addItem(item("Update to \(pending)…", #selector(checkForUpdates)))
        } else {
            menu.addItem(item("Check for Updates…", #selector(checkForUpdates)))
        }
        #endif
        menu.addItem(item("About \(AppInfo.name)", #selector(showAbout)))
        menu.addItem(.separator())
        let version = NSMenuItem(title: "\(AppInfo.name) \(AppInfo.displayVersion)", action: nil, keyEquivalent: "")
        version.isEnabled = false
        menu.addItem(version)
        menu.addItem(item("Quit \(AppInfo.name)", #selector(quit), key: "q"))
    }

    private func item(_ title: String, _ action: Selector, key: String = "", hotKey: HotKey? = nil, symbol: String? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        if let shortcut = hotKey?.menuKeyEquivalent {
            item.keyEquivalent = shortcut.key
            item.keyEquivalentModifierMask = shortcut.mask
        }
        if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        return item
    }

    // MARK: Actions

    @objc func quickPaste() { QuickPastePanel.shared.show() }
    @objc func showMain() { MainWindow.shared.show() }
    @objc func showStack() { StackWindow.shared.toggle() }
    @objc func togglePause() { Preferences.shared.paused.toggle() }
    @objc func copyRecent(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID, let clip = ClipStore.shared.clip(id) else { return }
        _ = Paster.copy(clip)
    }
    @objc func allowAccessibility() {
        if !Paster.requestAccess() { Paster.openAccessibilitySettings() }
    }
    @objc func showSettings() { SettingsWindow.shared.show() }
    @objc func showSyncSettings() { SettingsWindow.shared.show(tab: "Sync") }
    #if !APPSTORE
    @objc func checkForUpdates() { UpdateController.checkForUpdates() }
    @objc func installUpdateNow() { AutoUpdater.shared.installNow() }
    #endif
    @objc func quit() { NSApp.terminate(nil) }
    @objc func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(nil)
    }
}
