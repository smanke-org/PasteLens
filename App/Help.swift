import AppKit
import SwiftUI

// MARK: - Content

/// One page of Help. Text can name a shortcut the user sets with `{hotkey:<action>}`
/// (an `HotKeyAction` raw value), which shows their key, or says it isn't set.
struct HelpTopic: Identifiable, Hashable {
    let id: String
    let title: String
    let symbol: String
    let blocks: [HelpBlock]

    static func == (a: HelpTopic, b: HelpTopic) -> Bool { a.id == b.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

@MainActor
enum HelpBlock {
    case text(String)
    case heading(String)
    /// Keys on the left, what they do on the right.
    case keys([(String, String)])
    case tip(String)

    var searchText: String {
        switch self {
        case .text(let s), .heading(let s), .tip(let s): Help.resolve(s)
        case .keys(let rows): rows.map { Help.resolve($0.0) + " " + Help.resolve($0.1) }.joined(separator: " ")
        }
    }
}

@MainActor
enum Help {
    /// Swaps `{hotkey:action}` for the user's own shortcut.
    static func resolve(_ text: String) -> String {
        guard text.contains("{hotkey:") else { return text }
        var out = text
        for action in HotKeyAction.allCases {
            let token = "{hotkey:\(action.rawValue)}"
            guard out.contains(token) else { continue }
            out = out.replacingOccurrences(of: token, with: Preferences.shared.hotKey(action)?.display ?? "(no shortcut set)")
        }
        return out
    }

    /// The topic each Settings tab's Help button opens.
    static func topic(forSettingsTab tab: String) -> String {
        switch tab {
        case "Quick Paste": "quick-paste"
        case "History": "history"
        case "Shortcuts": "shortcuts"
        case "Privacy": "privacy"
        case "Snippets": "snippets"
        case "Sync": "sync"
        case "Activity": "activity"
        case "Advanced": "automation"
        default: "getting-started"
        }
    }

    static var topics: [HelpTopic] { [
        HelpTopic(id: "getting-started", title: "Getting Started", symbol: "sparkles", blocks: [
            .text("PasteLens keeps everything you copy, so you can find it again and paste it anywhere. It runs from the menu bar (the clipboard icon) and records every copy until you pause it."),
            .heading("The three ways in"),
            .keys([
                ("{hotkey:quickPaste}", "Quick Paste: a small panel at the pointer. Type to search, press Return to paste."),
                ("{hotkey:mainWindow}", "The History window: browse, edit and organize everything."),
                ("Menu bar icon", "Recent clippings, the Stack, filters, Pause and Settings."),
            ]),
            .heading("Allow pasting"),
            .text("To paste into other apps, PasteLens presses ⌘V for you, which needs Accessibility permission (macOS 27 calls it Device Control). Without it, PasteLens still records and copies; you press ⌘V yourself. If the menu bar menu shows \"Allow Pasting into Apps…\", choose it to open the right Settings pane."),
            .heading("What gets recorded"),
            .text("Text, links, colors, images and files you copy. Copies from your iPhone, iPad or other Macs arrive through Universal Clipboard and are recorded too, labeled \"Universal Clipboard\". Images, files and Universal Clipboard can each be switched off in Settings › History. Copies from password managers are ignored automatically, and anything that looks like a secret is hidden and deleted soon after. See Privacy and Secrets."),
            .tip("Every shortcut on these pages that shows your own keys can be changed in Settings › Shortcuts."),
            .tip("While ToolHUD is running, PasteLens's menu moves into ToolHUD's menu bar menu as a submenu, and the icon here steps aside until ToolHUD quits. To keep the icon, turn off \"Put in ToolHUD's menu while ToolHUD is running\" in Settings."),
            .tip("Quitting asks first, since PasteLens stops recording your copies while it's closed. Turn off \"Ask before quitting\" in Settings › General, or tick \"Don't ask again\" when it asks."),
        ]),

        HelpTopic(id: "quick-paste", title: "Quick Paste", symbol: "magnifyingglass", blocks: [
            .text("Press {hotkey:quickPaste} anywhere. The panel opens at the pointer (or the center of the screen; see Settings › Quick Paste). Start typing to search; matching is fuzzy, so \"inv23\" finds \"Invoice 2023\". Text in images is searchable when text recognition is on."),
            .heading("Choose and paste"),
            .keys([
                ("↑ ↓", "Move through the list"),
                ("Page Up / Page Down", "Jump 8 rows"),
                ("{hotkey:quickPaste} again", "Move down the list, like ⌘⇥ between apps"),
                ("Return", "Paste the selected clipping"),
                ("⇧ Return", "Paste as plain text"),
                ("⌥ Return", "Type it out, key by key, for fields that block pasting"),
                ("⌘ Return", "Choose a filter to run on it before pasting"),
                ("⌘1 – ⌘9", "Paste the 1st to 9th clipping in the list"),
                ("⌘C", "Copy it without pasting"),
                ("Double-click", "Paste the clicked clipping"),
            ]),
            .heading("Move around"),
            .keys([
                ("Tab / ⇧Tab", "Down or up the left column: History and your pastebins"),
                ("⌥Tab / ⇧⌥Tab", "Right or left along the top row: Pinned, smart pastebins and Snippets"),
                ("Esc", "Steps back: leaves filters, then clears picks, then the search, then closes"),
            ]),
            .heading("Organize without leaving the panel"),
            .keys([
                ("⌘-click / ⇧-click", "Pick several clippings"),
                ("⌘A", "Pick everything listed"),
                ("⌃1 – ⌃9", "Move the picked (or selected) clippings to pastebin 1 to 9 in the left column"),
                ("Drag", "Drag a clipping (or your picks) onto a pastebin in the left column to move it there"),
                ("⌘P", "Pin or unpin"),
                ("⌘S", "Add to the Stack"),
                ("⌘O", "Show it in the History window"),
                ("Delete or ⌘⌫", "Delete it"),
                ("Right-click", "Every action for that clipping"),
            ]),
            .tip("Turn on \"Release to paste\" in Settings › Quick Paste: hold the shortcut's modifier keys, tap its letter to move down, and let go to paste."),
            .tip("The gear at the right of the search field opens Settings."),
        ]),

        HelpTopic(id: "history", title: "History Window", symbol: "macwindow", blocks: [
            .text("Press {hotkey:mainWindow} (or choose Open PasteLens in the menu bar menu) to see everything you've copied. The sidebar lists History, your pastebins, smart pastebins, Filters, Snippets and Activity. The window closes itself when you click into another app, like a menu."),
            .keys([
                ("Type", "Search starts in the field at the top when the shortcut opens the window"),
                ("↑ ↓", "Move through the list, even while the cursor is in the search field"),
                ("⇧↑ ⇧↓", "Extend the selection"),
                ("← →", "Step through the sidebar (when the search is empty)"),
                ("Tab / ⇧Tab", "Next or previous sidebar section"),
                ("Return", "Paste the selection into the app you were using"),
                ("⌃1 – ⌃9", "Move the selected clippings to pastebin 1 to 9"),
                ("Drag", "Drag the selected clippings onto a pastebin in the sidebar to move them there"),
                ("⌘S", "Save while editing a clipping"),
                ("Esc", "Close the window"),
            ]),
            .heading("Keeping history"),
            .text("Settings › History sets how many clippings to keep and for how many days, or Unlimited. Pinned clippings and clippings saved in a pastebin are never removed. \"Move pasted clippings to the top of History\" (Settings › Quick Paste) keeps what you use most within reach."),
        ]),

        HelpTopic(id: "pastebins", title: "Pastebins", symbol: "tray.full", blocks: [
            .text("Pastebins are folders for clippings you want to keep, such as addresses, replies or code. Moving a clipping into a pastebin keeps it out of History's trimming."),
            .heading("Smart pastebins"),
            .text("A smart pastebin fills itself from rules, like a smart folder. Match all or any of: Text, Kind, Source App, Note, Size (KB), Text Length, Age (days) and Pasteboard Type. Examples: links copied this week; anything copied from Xcode; text longer than 2,000 characters."),
            .tip("Give a pastebin its own shortcut (in its edit sheet) to open Quick Paste on just that pastebin."),
            .tip("In Quick Paste and the History window, ⌃1 is your first pastebin, ⌃2 the second, and so on, in sidebar order."),
            .tip("You can also drag clippings onto a pastebin in the sidebar (or Quick Paste's left column) to move them there. Text dragged in from another app is saved in that pastebin."),
        ]),

        HelpTopic(id: "filters", title: "Filters", symbol: "camera.filters", blocks: [
            .text("A filter changes text before it's pasted: one or more steps run in order. In Quick Paste, select a clipping and press ⌘ Return, then pick a filter. Filters can also have their own shortcut (filter the clipboard and paste) and can be listed in the menu bar menu's Filters submenu."),
            .heading("Steps you can combine"),
            .keys([
                ("Change Case", "UPPER, lower, Title, Sentence, camelCase, snake_case and more"),
                ("Find and Replace", "Plain or regular expression, with $1, $2 for groups"),
                ("Extract", "Only the links, email addresses, phone numbers or regex matches"),
                ("Line Operations / Sort", "Trim, dedupe, number, join, reverse, sort"),
                ("Template", "Wrap the text: {text}, plus {date}, {time}, {clipboard}"),
                ("Encode / Decode", "Base64, hex, HTML entities, URL encoding"),
                ("JSON, Markdown, HTML", "Pretty-print or minify JSON; Markdown to HTML; strip HTML"),
                ("Translate", "On-device, with Apple's Translation"),
                ("Apple Intelligence", "Summarize, fix grammar, rewrite, change tone"),
                ("JavaScript / Shell", "Your own code: `text` in, result out"),
            ]),
            .tip("Coming from Pastebot? Import its filters in Settings › Advanced."),
        ]),

        HelpTopic(id: "snippets", title: "Snippets", symbol: "text.badge.plus", blocks: [
            .text("Snippets are reusable text, such as a signature, an address or a reply. Paste one from Quick Paste (press {hotkey:snippets}, or ⌥Tab along the top row to Snippets), or type its abbreviation in any app."),
            .heading("Abbreviations"),
            .text("Turn on \"Expand abbreviations as you type\" in Settings › Snippets, then type an abbreviation such as ;sig anywhere. It needs Input Monitoring permission. Keystrokes are only compared with your abbreviations; nothing is recorded."),
            .heading("Placeholders"),
            .keys([
                ("{clipboard}", "What's on the clipboard now"),
                ("{date} {time} {datetime}", "Today's date and time"),
                ("{date:yyyy-MM-dd}", "Any date format"),
                ("{date+3} {date-1}", "Days from today"),
                ("{weekday} {uuid}", "The day's name, or a new unique ID"),
                ("{input:Name}", "Ask for a value before pasting; {input:Name=default} pre-fills it"),
                ("{cursor}", "Where the insertion point ends up"),
                ("{{ }}", "Literal braces"),
            ]),
            .tip("ExpansionLens users: keep each abbreviation in one app only, so it isn't expanded twice."),
        ]),

        HelpTopic(id: "stack", title: "Stack", symbol: "square.stack.3d.up", blocks: [
            .text("The Stack is a queue for pasting several things in order, such as filling a form from a list. Add clippings, then paste them one after another."),
            .keys([
                ("{hotkey:addToStack}", "Copy the selection in any app and add it to the Stack"),
                ("{hotkey:pasteFromStack}", "Paste the next item and take it off the Stack"),
                ("{hotkey:showStack}", "Show or hide the Stack window"),
                ("⌘S in Quick Paste", "Add the selected or picked clippings"),
            ]),
            .text("In the Stack window you can choose whether every new copy joins the Stack while it's collecting, and whether to paste from the top (first in, first out) or the bottom."),
        ]),

        HelpTopic(id: "shortcuts", title: "Keyboard Shortcuts", symbol: "keyboard", blocks: [
            .heading("Anywhere on your Mac"),
            .keys(HotKeyAction.allCases.map { ("{hotkey:\($0.rawValue)}", "\($0.title): \($0.detail)") }),
            .text("Change these in Settings › Shortcuts. Pastebins, filters and single clippings can have their own shortcuts too, in their edit sheets."),
            .heading("Menu bar menu"),
            .keys([
                ("1 – 9", "With the menu open, copy recent clipping 1 to 9"),
                ("⌘,", "Settings"),
            ]),
            .heading("Quick Paste"),
            .keys([
                ("Return / ⇧ / ⌥ / ⌘", "Paste / as plain text / type out / choose a filter"),
                ("⌘1 – ⌘9", "Paste clipping 1 to 9"),
                ("Tab, ⌥Tab", "Left column, top row (add ⇧ to go back)"),
                ("⌃1 – ⌃9", "Move to pastebin 1 to 9"),
                ("⌘C ⌘P ⌘S ⌘O", "Copy, pin, add to Stack, show in History window"),
                ("⌘A, ⌘-click, ⇧-click", "Pick several"),
                ("Delete or ⌘⌫", "Delete"),
                ("Esc", "Step back, then close"),
            ]),
            .heading("History window"),
            .keys([
                ("↑ ↓ ← →", "List and sidebar, even from the search field"),
                ("Tab / ⇧Tab", "Sidebar sections"),
                ("Return", "Paste the selection"),
                ("⌃1 – ⌃9", "Move to pastebin 1 to 9"),
                ("Esc", "Close"),
            ]),
            .heading("Help"),
            .keys([("⌘?", "Open this window from PasteLens's own menus")]),
        ]),

        HelpTopic(id: "privacy", title: "Privacy and Secrets", symbol: "hand.raised", blocks: [
            .text("Your clippings stay on your Mac. With sync on, they travel through your iCloud account encrypted with AES-256 using a passphrase only you know; neither Apple nor the developer can read them."),
            .heading("What PasteLens leaves alone"),
            .text("Copies from password managers (1Password, Passwords, Keychain Access, Bitwarden and others) are ignored automatically, as are copies an app marks as concealed or temporary. Add any other app under Settings › History › Ignore copies from these apps."),
            .heading("Secrets"),
            .text("With \"Detect secrets\" on (Settings › Privacy), API keys and tokens, private keys, card numbers, one-time codes and password-like text are hidden in lists, never synced, and deleted soon after."),
            .heading("Pausing"),
            .text("Press {hotkey:togglePause} or choose Pause Recording in the menu bar menu. The menu bar icon dims while paused."),
            .tip("Settings › History can delete your history; pinned clippings and those in pastebins stay."),
        ]),

        HelpTopic(id: "sync", title: "Sync", symbol: "icloud", blocks: [
            .text("Sync shares your history, pastebins, smart pastebins, filters, snippets and settings with your other Macs through iCloud. Turn it on in Settings › Sync on each Mac with the same passphrase."),
            .text("Everything is encrypted on this Mac before it leaves. The passphrase can't be recovered, so keep it somewhere safe. Secrets never sync, and you can keep clippings on each Mac with \"Sync clippings\" off."),
            .heading("If sync stops"),
            .text("When the menu bar menu shows \"Enter Sync Passphrase…\", this Mac has lost its key, and nothing syncs until you enter the passphrase again. The menu's iCloud line shows the current status; choose it to open Settings › Sync."),
        ]),

        HelpTopic(id: "activity", title: "Activity", symbol: "chart.bar.xaxis", blocks: [
            .text("Activity counts your copies and pastes per day. Settings › Activity shows this Mac or all your Macs; the History window's Activity section shows the same graphs by Mac. Only pastes made by PasteLens are counted."),
        ]),

        HelpTopic(id: "automation", title: "Automation", symbol: "gearshape.2", blocks: [
            .heading("Shortcuts app"),
            .text("Find PasteLens's actions in the Shortcuts app: Get Clippings, Get Clipping by Position, Copy Clipping, Paste Clipping and Apply Filter."),
            .heading("Links"),
            .keys([
                ("pastelens://quickpaste", "Open Quick Paste"),
                ("pastelens://open", "Open the History window"),
                ("pastelens://stack", "Show the Stack"),
                ("pastelens://paste?text=…", "Paste the given text"),
            ]),
            .text("ToolHUD's PasteLens buttons use these links."),
            .heading("Terminal and AI assistants"),
            .text("Settings › Advanced installs the pastelens command, for example pastelens get-clippings --query invoice, and gives the configuration for the MCP server, so an AI assistant such as Claude Desktop can search your clippings, run filters and paste."),
        ]),

        HelpTopic(id: "troubleshooting", title: "Troubleshooting", symbol: "wrench.and.screwdriver", blocks: [
            .heading("Pressing Return copies but doesn't paste"),
            .text("PasteLens needs Accessibility (Device Control) permission. Choose \"Allow Pasting into Apps…\" in the menu bar menu, or switch PasteLens on in System Settings › Privacy & Security. Remove and re-add it if it's on but still not working."),
            .heading("A shortcut does nothing"),
            .text("Another app may use the same keys. Pick a different one in Settings › Shortcuts. Some combinations are reserved by macOS."),
            .heading("Abbreviations don't expand"),
            .text("Check Input Monitoring permission for PasteLens in System Settings › Privacy & Security, and that \"Expand abbreviations as you type\" is on."),
            .heading("\"Skipped a large clipping\" in the menu"),
            .text("Copies larger than the limit in Settings › History (\"Ignore clippings larger than\") aren't recorded, to keep PasteLens fast. Raise the limit, or copy a smaller part."),
            .heading("Something copied isn't in History"),
            .text("The app may be ignored (Settings › History), recording may be paused, or the copy looked like a secret (Settings › Privacy). A copy from another device appears once Universal Clipboard has finished bringing it over; if the transfer fails, it isn't recorded."),
        ]),
    ] }
}

// MARK: - Window

@Observable
@MainActor
final class HelpState {
    var selection: String? = "getting-started"
    var query = ""
}

@MainActor
final class HelpWindow: NSObject, NSWindowDelegate {
    static let shared = HelpWindow()

    let state = HelpState()
    private(set) var window: NSWindow?

    /// Opens Help, on `topic` when given.
    func show(topic: String? = nil) {
        if let topic { state.query = ""; state.selection = topic }
        if window == nil {
            let hosting = NSHostingController(rootView: HelpView(state: state))
            hosting.sizingOptions = []
            let window = NSWindow(contentViewController: hosting)
            window.title = "\(AppInfo.name) Help"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.setContentSize(NSSize(width: 820, height: 600))
            window.contentMinSize = NSSize(width: 640, height: 400)
            window.isReleasedWhenClosed = false
            window.setFrameAutosaveName("PasteLensHelp")
            window.delegate = self
            // Never taller than the screen it opens on.
            if let screen = NSScreen.main?.visibleFrame, window.frame.height > screen.height {
                window.setContentSize(NSSize(width: 820, height: screen.height - 80))
            }
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct HelpView: View {
    @Bindable var state: HelpState

    private var matches: [HelpTopic] {
        let query = state.query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return Help.topics }
        return Help.topics.filter { topic in
            topic.title.lowercased().contains(query) || topic.blocks.contains { $0.searchText.lowercased().contains(query) }
        }
    }

    var body: some View {
        NavigationSplitView {
            List(matches, selection: $state.selection) { topic in
                Label(topic.title, systemImage: topic.symbol).tag(topic.id)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210)
            .overlay {
                if matches.isEmpty { Text("No matches").foregroundStyle(.secondary) }
            }
        } detail: {
            if let topic = Help.topics.first(where: { $0.id == state.selection }) {
                HelpPage(topic: topic, query: state.query)
            } else {
                Text("Choose a topic").foregroundStyle(.secondary)
            }
        }
        .searchable(text: $state.query, placement: .sidebar, prompt: "Search Help")
        .onChange(of: state.query) {
            // Keep a matching topic on screen while searching.
            if let first = matches.first, !matches.contains(where: { $0.id == state.selection }) { state.selection = first.id }
        }
    }
}

struct HelpPage: View {
    let topic: HelpTopic
    let query: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Label(topic.title, systemImage: topic.symbol)
                    .font(.largeTitle.weight(.semibold))
                    .padding(.bottom, 4)
                ForEach(Array(topic.blocks.enumerated()), id: \.offset) { _, block in
                    view(for: block)
                }
            }
            .padding(28)
            .frame(maxWidth: 680, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private func view(for block: HelpBlock) -> some View {
        switch block {
        case .text(let s):
            Text(Help.resolve(s)).fixedSize(horizontal: false, vertical: true)
        case .heading(let s):
            Text(Help.resolve(s)).font(.title3.weight(.semibold)).padding(.top, 8)
        case .tip(let s):
            Label { Text(Help.resolve(s)).fixedSize(horizontal: false, vertical: true) } icon: {
                Image(systemName: "lightbulb").foregroundStyle(.yellow)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        case .keys(let rows):
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 8) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    let keys = Help.resolve(row.0), what = Help.resolve(row.1)
                    let hit = !query.isEmpty && (keys + " " + what).lowercased().contains(query.lowercased())
                    GridRow {
                        Text(keys)
                            .font(.body.monospaced().weight(.medium))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
                            // The same key column width in every table on every page.
                            .frame(width: 210, alignment: .leading)
                        Text(what).fixedSize(horizontal: false, vertical: true)
                    }
                    .background(hit ? Color.yellow.opacity(0.25) : .clear)
                }
            }
        }
    }
}

/// The round "?" button macOS puts in the corner of Settings panes.
struct HelpButton: NSViewRepresentable {
    let topic: String

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: "", target: context.coordinator, action: #selector(Coordinator.open))
        button.bezelStyle = .helpButton
        button.toolTip = "\(AppInfo.name) Help"
        button.setAccessibilityLabel("Help")
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) { context.coordinator.topic = topic }

    func makeCoordinator() -> Coordinator { Coordinator(topic: topic) }

    @MainActor
    final class Coordinator: NSObject {
        var topic: String
        init(topic: String) { self.topic = topic }
        @objc func open() { HelpWindow.shared.show(topic: topic) }
    }
}
