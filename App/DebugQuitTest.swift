#if DEBUG
import AppKit

/// `PASTELENS_DEBUG_QUIT_TEST=<return|cancel|quit|suppress|off>` (notes to `PASTELENS_DEBUG_OUT`):
/// quits as ⌘Q does, then answers the question a second later: presses Return (then Cancel,
/// once it's clear Return did nothing), clicks Cancel or Quit (ticking "Don't ask again" first
/// for `suppress`), or with `off` turns the setting off first. What the question looked like
/// is noted before any answer. If the app is still running after the answer, that's noted with
/// the setting and the activation policy, and it quits without asking. It
/// starts nothing else: no capture, shortcuts, sync or bridges. `settings` instead opens
/// Settings as the menu does, notes its tabs and the one showing, and renders it to `<out>.png`.
@MainActor
enum DebugQuitTest {
    private static var lines: [String] = []

    private static func note(_ s: String) {
        lines.append(s)
        let path = ProcessInfo.processInfo.environment["PASTELENS_DEBUG_OUT"] ?? NSTemporaryDirectory() + "pastelens-debug.txt"
        try? lines.joined(separator: "\n").appending("\n").write(toFile: path, atomically: true, encoding: .utf8)
    }

    static func run(_ how: String) {
        note("started policy \(NSApp.activationPolicy().rawValue) confirmQuit \(Preferences.shared.confirmQuit)")
        if how == "settings" {
            SettingsWindow.shared.show()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                MainActor.assumeIsolated {
                    let window = NSApp.windows.first { $0.contentViewController is SettingsTabs }
                    let tabs = window?.contentViewController as? NSTabViewController
                    note("tabs \(tabs?.tabViewItems.map(\.label) ?? []) showing \(tabs.map { $0.tabViewItems[$0.selectedTabViewItemIndex].label } ?? "-")")
                    let path = (ProcessInfo.processInfo.environment["PASTELENS_DEBUG_OUT"] ?? NSTemporaryDirectory() + "pastelens-debug.txt") + ".png"
                    if let view = window?.contentView?.superview, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                        view.cacheDisplay(in: view.bounds, to: rep)
                        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                    }
                    QuitConfirmation.quitNow()
                }
            }
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            MainActor.assumeIsolated {
                if how == "off" { Preferences.shared.confirmQuit = false }
                let answer = Timer(timeInterval: 1, repeats: false) { _ in
                    MainActor.assumeIsolated { DebugQuitTest.answer(how) }
                }
                RunLoop.main.add(answer, forMode: .common)
                NSApp.terminate(nil)
                // Only reached when the quit was cancelled.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    note("still running; confirmQuit \(Preferences.shared.confirmQuit); policy \(NSApp.activationPolicy().rawValue)")
                    QuitConfirmation.quitNow()
                }
            }
        }
    }

    private static func answer(_ how: String) {
        guard let window = NSApp.modalWindow else { note("no question"); return }
        var texts: [String] = []
        var buttons: [NSButton] = []
        func walk(_ view: NSView) {
            if let button = view as? NSButton { buttons.append(button) }
            else if let field = view as? NSTextField, !field.stringValue.isEmpty { texts.append(field.stringValue) }
            view.subviews.forEach(walk)
        }
        if let content = window.contentView { walk(content) }
        let titles = buttons.map { "\($0.title)[\($0.keyEquivalent == "\r" ? "Return" : $0.keyEquivalent == "\u{1b}" ? "Esc" : $0.keyEquivalent)]" }
        note("asked \(texts) buttons \(titles) visible \(window.isVisible) key \(window.isKeyWindow) active \(NSApp.isActive) front \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "-") policy \(NSApp.activationPolicy().rawValue)")
        switch how {
        case "return":
            if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: window.windowNumber, context: nil, characters: "\r",
                                            charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36) {
                NSApp.postEvent(event, atStart: false)
            }
            let check = Timer(timeInterval: 1, repeats: false) { _ in
                MainActor.assumeIsolated {
                    note("after Return: question still up \(NSApp.modalWindow != nil)")
                    buttons.first { $0.title == "Cancel" }?.performClick(nil)
                }
            }
            RunLoop.main.add(check, forMode: .common)
        case "cancel": buttons.first { $0.title == "Cancel" }?.performClick(nil)
        case "quit", "suppress":
            if how == "suppress" { buttons.first { $0.title == "Don't ask again" }?.performClick(nil) }
            buttons.first { $0.title == "Quit" }?.performClick(nil)
        default: break
        }
    }
}
#endif
