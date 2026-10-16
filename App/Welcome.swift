import AppKit
import Combine
import PasteLensKit
import SwiftUI

/// First-launch tour: what PasteLens does, the two permissions, and sync.
@MainActor
final class WelcomeWindow {
    static let shared = WelcomeWindow()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 460), styleMask: [.titled, .closable],
                                  backing: .buffered, defer: false)
            window.title = "Welcome to PasteLens"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: WelcomeView { [weak self] in self?.window?.close() })
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct WelcomeView: View {
    let done: () -> Void
    @State private var page = 0
    @State private var trusted = Paster.trusted
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 18) {
            Group {
                switch page {
                case 0: intro
                case 1: permissions
                default: finish
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack {
                if page > 0 { Button("Back") { page -= 1 } }
                Spacer()
                ForEach(0..<3) { i in Circle().fill(i == page ? Color.accentColor : .secondary.opacity(0.3)).frame(width: 7, height: 7) }
                Spacer()
                Button(page == 2 ? "Start Using PasteLens" : "Continue") { page == 2 ? done() : (page += 1) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(width: 560, height: 460)
        .onReceive(timer) { _ in trusted = Paster.trusted }
    }

    var intro: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Everything you copy, one keystroke away").font(.title2.bold())
            feature("clock.arrow.circlepath", "History", "PasteLens keeps what you copy. Save keepers into pastebins; smart pastebins sort the rest.")
            feature("magnifyingglass", "Quick Paste — ⇧⌘V", "Search and paste from any app. Tab switches pastebins.")
            feature("camera.filters", "Filters — ⌘↩", "Clean up, convert, translate or rewrite text before it's pasted.")
            feature("square.stack.3d.up", "Stack", "Queue several clippings, then paste them one after another.")
            feature("text.badge.plus", "Snippets", "Reusable text with dates, fill-in fields and abbreviations.")
            feature("lock.icloud", "Encrypted sync", "Your Macs share history and settings through iCloud, encrypted end to end.")
        }
    }

    var permissions: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Allow pasting").font(.title2.bold())
            Text("To paste into other apps, PasteLens sends ⌘V for you. macOS calls this Accessibility (or Device Control) permission.")
            HStack {
                if trusted {
                    Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                } else {
                    Button("Allow Accessibility…") { Paster.requestAccess(); Paster.openAccessibilitySettings() }
                    Text("Switch PasteLens on in the list that opens.").foregroundStyle(.secondary)
                }
            }
            Text("Without it, PasteLens still records and copies; you'd press ⌘V yourself.").font(.callout).foregroundStyle(.secondary)
            if Importer.pastebotInstalled {
                Divider()
                Text("Coming from Pastebot?").font(.headline)
                HStack {
                    Button("Import Pastebot Clippings…") { Importer.importPastebotHistory() }
                    Text("Filters can be imported in Settings › Advanced.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    var finish: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Sync your Macs").font(.title2.bold())
            Text("Turn on sync to share history, pastebins, filters, snippets and settings with your other Macs through iCloud Drive. Everything is encrypted with AES-256 on this Mac using a passphrase only you know.")
            Button("Set Up Sync…") { SettingsWindow.shared.show(tab: "Sync") }
            Divider()
            Text("Find PasteLens in the menu bar (the clipboard icon). Press ⇧⌘V anywhere to start.")
                .foregroundStyle(.secondary)
        }
    }

    func feature(_ symbol: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.title3).foregroundStyle(.tint).frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(text).foregroundStyle(.secondary)
            }
        }
    }
}
