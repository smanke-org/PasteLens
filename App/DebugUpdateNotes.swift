#if DEBUG && !APPSTORE
import AppKit

/// Debug builds only. `PASTELENS_DEBUG_UPDATE_NOTES=<folder>` (with `PASTELENS_DEFAULTS_SUITE`
/// and `PASTELENS_DATA_FOLDER`, so nothing real is touched): fetches the notes of PasteLens's
/// own releases, draws the update prompt, the What's New sheet Settings shows after an
/// automatic update, and Settings itself to PNGs, writes report.txt, and quits. It starts
/// nothing else: no capture, shortcuts, sync or bridges.
@MainActor
enum DebugUpdateNotes {
    static func run(folder: String) {
        let env = ProcessInfo.processInfo.environment
        guard env["PASTELENS_DEFAULTS_SUITE"] != nil, env["PASTELENS_DATA_FOLDER"] != nil else {
            NSLog("PasteLens: this test needs PASTELENS_DEFAULTS_SUITE and PASTELENS_DATA_FOLDER")
            exit(2)
        }
        let out = URL(fileURLWithPath: folder, isDirectory: true)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var report: [String] = []
        func note(_ line: String) {
            report.append(line)
            try? report.joined(separator: "\n").appending("\n").write(to: out.appending(path: "report.txt"), atomically: true, encoding: .utf8)
        }
        func contentSize() -> CGSize {
            SettingsWindow.shared.debugWindow.map { $0.contentRect(forFrameRect: $0.frame).size } ?? .zero
        }

        Task {
            note("running \(AppInfo.version)")
            // The update prompt, as someone on 1.1.10 would see it offered 1.1.13.
            let notes = await ReleaseNotes.fetch(newAfter: "1.1.10", through: "1.1.13")
            note("notes fetched: \(notes.map { $0.version + ($0.isNew ? " new" : "") })")
            let alert = UpdateController.makeConfirmAlert(newVersion: "1.1.13", current: "1.1.10", notes: notes)
            alert.layout()
            alert.window.orderFront(nil)
            try? await Task.sleep(for: .seconds(1))
            render(alert.window, to: out.appending(path: "update-prompt.png"))
            note("buttons: \(alert.buttons.map { "\($0.title) key='\($0.keyEquivalent)'" })")
            note("reminder box: '\(alert.suppressionButton?.title ?? "none")' on by default: \(alert.suppressionButton?.state == .on)")
            alert.window.orderOut(nil)

            // A brand-new install shows nothing.
            WhatsNew.shared.noteLaunch(newInstall: true, autoInstalledFrom: nil)
            note("new install pending: \(String(describing: WhatsNew.shared.pending))")
            // What's New in Settings after an automatic update from the release before this one.
            let previous = notes.first { UpdateController.isNewer(AppInfo.version, than: $0.version) }?.version ?? "1.1.12"
            WhatsNew.shared.noteLaunch(newInstall: false, autoInstalledFrom: previous)
            note("auto-update from \(previous) pending: \(String(describing: WhatsNew.shared.pending))")
            SettingsWindow.shared.show(tab: "General")
            try? await Task.sleep(for: .seconds(4))
            render(SettingsWindow.shared.debugWindow?.attachedSheet, to: out.appending(path: "whats-new.png"))
            note("sheet shown: \(SettingsWindow.shared.debugWindow?.attachedSheet != nil)")
            if let window = SettingsWindow.shared.debugWindow, let sheet = window.attachedSheet { window.endSheet(sheet) }
            // OK with "Don't show this again" ticked puts it away for good.
            WhatsNew.shared.dismiss(forGood: true)
            note("after dismiss pending: \(String(describing: WhatsNew.shared.pending))")
            try? await Task.sleep(for: .seconds(1))
            render(SettingsWindow.shared.debugWindow, to: out.appending(path: "general.png"))
            let window = SettingsWindow.shared.debugWindow
            note("settings resizable: \(window?.styleMask.contains(.resizable) == true) min \(window?.contentMinSize ?? .zero) general content \(contentSize())")

            // Asked for from the What's New… button: this version's notes, no "Don't show" box.
            SettingsWindow.shared.showWhatsNew()
            try? await Task.sleep(for: .seconds(3))
            render(SettingsWindow.shared.debugWindow?.attachedSheet, to: out.appending(path: "whats-new-asked.png"))
            note("asked sheet shown: \(SettingsWindow.shared.debugWindow?.attachedSheet != nil)")
            if let window = SettingsWindow.shared.debugWindow, let sheet = window.attachedSheet { window.endSheet(sheet) }

            // Each pane opens at its own height until the user drags a size, then every pane uses that.
            SettingsWindow.shared.show(tab: "Activity")
            try? await Task.sleep(for: .seconds(2))
            note("activity natural content \(contentSize())")
            SettingsTabs.chosenSize = NSSize(width: 720, height: 420)
            SettingsWindow.shared.show(tab: "History")
            try? await Task.sleep(for: .seconds(2))
            render(SettingsWindow.shared.debugWindow, to: out.appending(path: "history-dragged.png"))
            note("history after a chosen 720x420: \(contentSize())")
            note("done")
            exit(0)
        }
    }

    private static func render(_ window: NSWindow?, to url: URL) {
        guard let view = window?.contentView?.superview ?? window?.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
#endif
