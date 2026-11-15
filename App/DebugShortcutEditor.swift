#if DEBUG
import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Debug builds only. `PASTELENS_DEBUG_SHORTCUT_EDITOR=<folder>` (with `PASTELENS_DEFAULTS_SUITE`
/// and `PASTELENS_DATA_FOLDER`, so nothing real is touched): puts Settings › Shortcuts in a
/// window of its own (not activated, off to the side), opens a shortcut's editor and checks
/// typing "+", a bare letter, an F-key alone, pressing another shortcut's keys (they move) and
/// Clear. Draws the editor to editor.png, writes report.txt, and quits. It starts nothing else:
/// no capture, sync or bridges.
@MainActor
enum DebugShortcutEditor {
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
        func recorders(in view: NSView) -> [ShortcutRecorder.RecorderButton] {
            ((view as? ShortcutRecorder.RecorderButton).map { [$0] } ?? []) + view.subviews.flatMap(recorders)
        }
        func press(_ key: HotKey, in window: NSWindow, model: ShortcutEditorModel) {
            var flags: NSEvent.ModifierFlags = []
            if key.modifiers & UInt32(controlKey) != 0 { flags.insert(.control) }
            if key.modifiers & UInt32(optionKey) != 0 { flags.insert(.option) }
            if key.modifiers & UInt32(shiftKey) != 0 { flags.insert(.shift) }
            if key.modifiers & UInt32(cmdKey) != 0 { flags.insert(.command) }
            if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                            windowNumber: window.windowNumber, context: nil, characters: "",
                                            charactersIgnoringModifiers: "", isARepeat: false, keyCode: UInt16(key.keyCode)) {
                note("press \(key.display) used: \(model.handle(event))")
            }
        }

        _ = ClipStore.shared
        let prefs = Preferences.shared
        HotKeyCenter.shared.apply()
        note("running \(AppInfo.version)")
        note("start: Quick Paste \(prefs.hotKey(.quickPaste)?.display ?? "none"), Open PasteLens \(prefs.hotKey(.mainWindow)?.display ?? "none")")

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 640), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: ShortcutSettings())
        // Off the left of every screen, shown without taking focus from anyone.
        let left = NSScreen.screens.map(\.frame.minX).min() ?? 0
        window.setFrameOrigin(NSPoint(x: left - 3000, y: 200))
        window.orderFrontRegardless()

        Task {
            try? await Task.sleep(for: .seconds(1))
            let buttons = recorders(in: window.contentView!)
            note("recorders: \(buttons.map(\.debugTitle))")
            // Rows follow HotKeyAction.allCases: 0 Quick Paste, 1 Open PasteLens.
            guard buttons.count >= 2, let quickKeys = prefs.hotKey(.quickPaste) else { note("FAIL: no recorders"); exit(1) }
            let button = buttons[1]
            button.performClick(nil)
            try? await Task.sleep(for: .milliseconds(400))
            guard let model = button.debugModel else { note("FAIL: editor did not open"); exit(1) }
            note("opened: title '\(button.debugTitle)', keys '\(model.keyText)', combo \(model.combo?.display ?? "-")")

            model.control = false; model.option = false; model.shift = false; model.command = false
            model.typed("+")
            note("typed +: key box '\(model.keyText)' shift \(model.shift) code \(model.keyCode.map(String.init) ?? "-") combo \(model.combo?.display ?? "-") problem \(model.problem ?? "-")")
            model.command = true
            note("  with ⌘: combo \(model.combo?.display ?? "-") problem \(model.problem ?? "-")")

            model.control = false; model.option = false; model.shift = false; model.command = false
            model.typed("k")
            note("bare k: key box '\(model.keyText)' combo \(model.combo?.display ?? "-") problem \(model.problem ?? "-")")
            model.typed("é")
            note("é (not on this keyboard): problem \(model.problem ?? "-")")

            model.choose(kVK_F6)
            note("F6 alone: combo \(model.combo?.display ?? "-") problem \(model.problem ?? "-")")

            model.command = true
            model.choose(kVK_ANSI_V)
            note("⌘V: system warning '\(model.systemUse ?? "-")'")

            press(quickKeys, in: window, model: model)
            note("after pressing Quick Paste's keys: combo \(model.combo?.display ?? "-") moves from \(model.movesFrom)")
            try? await Task.sleep(for: .milliseconds(400))
            if let view = button.debugPopoverView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: out.appending(path: "editor.png"))
                note("editor drawn \(Int(view.bounds.width))x\(Int(view.bounds.height))")
            }
            model.finish?(.set(model.combo))
            try? await Task.sleep(for: .milliseconds(400))
            note("after Set: Open PasteLens \(prefs.hotKey(.mainWindow)?.display ?? "none"), Quick Paste \(prefs.hotKey(.quickPaste)?.display ?? "none"), title '\(button.debugTitle)', editor closed \(button.debugModel == nil)")

            // Cancel leaves it alone; Esc cancels.
            button.performClick(nil)
            try? await Task.sleep(for: .milliseconds(300))
            if let m = button.debugModel {
                m.choose(kVK_F7)
                if let esc = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                              context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: UInt16(kVK_Escape)) {
                    _ = m.handle(esc)
                }
            }
            try? await Task.sleep(for: .milliseconds(300))
            note("after F7 then Esc: Open PasteLens \(prefs.hotKey(.mainWindow)?.display ?? "none"), editor closed \(button.debugModel == nil)")

            // Clear.
            button.performClick(nil)
            try? await Task.sleep(for: .milliseconds(300))
            note("Clear enabled: \(button.debugModel?.original != nil)")
            button.debugModel?.finish?(.set(nil))
            try? await Task.sleep(for: .milliseconds(300))
            note("after Clear: Open PasteLens \(prefs.hotKey(.mainWindow)?.display ?? "none"), title '\(button.debugTitle)'")

            // A pastebin sheet moves the keys when it saves.
            let store = ClipStore.shared
            if var bin = store.library.pastebins.first {
                let keys = HotKey(keyCode: UInt32(kVK_ANSI_J), carbonModifiers: UInt32(cmdKey | optionKey))!
                prefs.setHotKey(keys, for: .showStack)
                HotKeyCenter.shared.clearOthers(using: keys, except: .pastebin(bin.id))
                bin.hotKey = keys.stored
                store.upsertPastebin(bin)
                note("pastebin '\(bin.name)' took \(keys.display): Show Stack \(prefs.hotKey(.showStack)?.display ?? "none")")
            } else {
                note("no pastebin to try")
            }
            HotKeyCenter.shared.unregisterAll()
            note("done")
            exit(0)
        }
    }
}
#endif
