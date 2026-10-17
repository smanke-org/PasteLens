import AppKit
import PasteLensKit
import SwiftUI
import UniformTypeIdentifiers

/// The library window: pastebins and smart pastebins in a sidebar, clippings in the middle,
/// a preview on the right. Snippets and filters are edited here too.
@MainActor
final class MainWindow: NSObject, NSWindowDelegate {
    static let shared = MainWindow()
    private var window: NSWindow?
    let state = MainState()
    /// The app that was in front when the window opened: pasting goes back to it.
    private var previousApp: NSRunningApplication?
    private var resignObserver: Any?
    private var keyMonitor: Any?

    /// `focusingSearch` puts the cursor in the search field, for when the hot key opened the window.
    func show(selecting clip: UUID? = nil, focusingSearch: Bool = false) {
        Activity.shared.touch()
        if let front = NSWorkspace.shared.frontmostApplication, front != .current { previousApp = front }
        if window == nil {
            let window = EscapeClosingWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 680),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
            window.title = "PasteLens"
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.contentView = NSHostingView(rootView: MainView(state: state))
            window.setFrameAutosaveName("PasteLensMain")
            if !window.setFrameUsingName("PasteLensMain") { window.center() }
            self.window = window
            // Clicking into another app closes the window, like a menu. Other PasteLens
            // windows (Settings, a sheet, an Open panel) don't count.
            // ⌃1–⌃9 move the selected clippings to that pastebin; Tab and Shift-Tab walk the sidebar.
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                MainActor.assumeIsolated {
                    MainWindow.shared.handlePastebinKey(event) || MainWindow.shared.handleSidebarTab(event) ? nil : event
                }
            }
            resignObserver = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification,
                                                                    object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { MainWindow.shared.closeIfOpen() }
            }
        }
        if let clip {
            state.section = .clips(.history)
            state.selection = [clip]
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        if focusingSearch {
            // A window that was just made hasn't laid out its toolbar yet, so wait a turn.
            DispatchQueue.main.async { MainWindow.shared.focusSearch() }
        }
    }

    /// The toolbar's search field, which lives outside the content view, in the window's frame view.
    private var searchField: NSSearchField? {
        func find(_ view: NSView) -> NSSearchField? {
            if let field = view as? NSSearchField { return field }
            for sub in view.subviews { if let hit = find(sub) { return hit } }
            return nil
        }
        return (window?.contentView?.superview).flatMap(find)
    }

    private func focusSearch() {
        guard let window, let field = searchField, field.window === window else { return }
        window.makeFirstResponder(field)
    }

    private func handlePastebinKey(_ event: NSEvent) -> Bool {
        guard event.window === window, event.modifierFlags.intersection([.command, .option, .control, .shift]) == .control,
              let digit = Int(event.charactersIgnoringModifiers ?? ""), (1...9).contains(digit),
              case .clips(let scope) = state.section, !state.selection.isEmpty else { return false }
        let bins = ClipStore.shared.library.pastebins.sorted { $0.order < $1.order }
        guard bins.indices.contains(digit - 1), scope != .pastebin(bins[digit - 1].id) else { NSSound.beep(); return true }
        ClipStore.shared.move(Array(state.selection), to: bins[digit - 1].id, from: scope)
        state.selection = []
        return true
    }

    /// Tab selects the next sidebar item, Shift-Tab the previous one, wrapping at the ends.
    /// This works from the search field too, so typing there and tabbing between sections go
    /// together. While other text is being edited (a rename, a snippet) Tab keeps its usual job.
    private func handleSidebarTab(_ event: NSEvent) -> Bool {
        guard let window, event.window === window, event.keyCode == 48,
              event.modifierFlags.intersection([.command, .option, .control]).isEmpty else { return false }
        // Activity has no search field, so focus falls to the window there; tabbing on from it
        // goes back to searching.
        var fromSearch = window.firstResponder === window
        if let text = window.firstResponder as? NSText {
            // A search field edits through the window's field editor, whose delegate is the field.
            guard let editor = text as? NSTextView, editor.isFieldEditor, editor.delegate is NSSearchField else { return false }
            fromSearch = true
        }
        let items = sidebarSections()
        guard !items.isEmpty else { return false }
        let step = event.modifierFlags.contains(.shift) ? -1 : 1
        let current = items.firstIndex(of: state.section) ?? (step > 0 ? -1 : 0)
        state.section = items[(current + step + items.count) % items.count]
        // Snippets and Filters bring their own search field, so put the cursor back in whichever one shows.
        if fromSearch { DispatchQueue.main.async { MainWindow.shared.focusSearch() } }
        return true
    }

    /// The sidebar's selectable rows, top to bottom (not the New Pastebin rows).
    func sidebarSections() -> [MainState.Section] {
        let library = ClipStore.shared.library
        return [.clips(.history), .clips(.pinned)]
            + library.pastebins.sorted { $0.order < $1.order }.map { .clips(.pastebin($0.id)) }
            + library.smartPastebins.sorted { $0.order < $1.order }.map { .clips(.smart($0.id)) }
            + [.snippets, .filters, .activity]
    }

    private func closeIfOpen() {
        guard let window, window.isVisible, window.attachedSheet == nil else { return }
        window.orderOut(nil)
    }

    /// Pastes a clipping into whatever had focus before the window opened, and closes the window.
    func paste(_ clip: Clipping, plain: Bool = false) {
        guard Paster.copy(clip, plain: plain) else { return }
        window?.orderOut(nil)
        let target = previousApp
        // Hand focus back first, so the paste lands in that app's field, not here.
        if let target, !target.isTerminated {
            target.activate()
        } else {
            NSApp.hide(nil)
        }
        Paster.pasteClipboard(after: 0.25)
    }
}

/// Esc closes the window. A search field or editor that's in use gets the key first, so Esc
/// there still clears the search or ends editing; the next Esc closes the window.
final class EscapeClosingWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) {
        if attachedSheet != nil { return }
        performClose(sender)
    }
}

@Observable
@MainActor
final class MainState {
    enum Section: Hashable {
        case clips(ClipStore.Scope)
        case snippets
        case filters
        case activity
    }
    var section: Section = .clips(.history) { didSet { selection = [] } }
    /// The Mac whose activity is shown; nil shows every Mac.
    var activityMac: String?
    var selection: Set<UUID> = []
    var query = ""
    var editingPastebin: Pastebin?
    var editingSmart: SmartPastebin?
}

struct MainView: View {
    @Bindable var state: MainState
    @State private var store = ClipStore.shared

    var body: some View {
        NavigationSplitView {
            Sidebar(state: state)
                .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 300)
        } content: {
            Group {
                switch state.section {
                case .clips(let scope): ClipList(state: state, scope: scope)
                case .snippets: SnippetList(state: state)
                case .filters: FilterList(state: state)
                case .activity: ActivityMacList(state: state)
                }
            }
            .navigationSplitViewColumnWidth(min: 280, ideal: 360)
        } detail: {
            detail
        }
        .sheet(item: $state.editingPastebin) { PastebinEditor(bin: $0) }
        .sheet(item: $state.editingSmart) { SmartPastebinEditor(bin: $0) }
    }

    @ViewBuilder var detail: some View {
        switch state.section {
        case .clips:
            if state.selection.count == 1, let id = state.selection.first, let clip = store.clip(id) {
                ClipPreview(clip: clip)
            } else if state.selection.count > 1 {
                MultiSelectionView(ids: Array(state.selection))
            } else {
                ContentUnavailableView("No Clipping Selected", systemImage: "doc.on.clipboard")
            }
        case .snippets:
            if let id = state.selection.first, let snippet = store.library.snippets.first(where: { $0.id == id }) {
                SnippetEditor(snippet: snippet).id(id)
            } else {
                ContentUnavailableView("No Snippet Selected", systemImage: "text.badge.plus",
                                       description: Text("Snippets are reusable text with placeholders like {date} and {input:Name}."))
            }
        case .filters:
            if let id = state.selection.first, let filter = store.library.filters.first(where: { $0.id == id }) {
                FilterEditor(filter: filter).id(id)
            } else {
                ContentUnavailableView("No Filter Selected", systemImage: "camera.filters",
                                       description: Text("Filters transform text before you paste it. Press ⌘↩ in Quick Paste to use one."))
            }
        case .activity:
            ActivityDetail(state: state)
        }
    }
}

// MARK: - Sidebar

struct Sidebar: View {
    @Bindable var state: MainState
    @State private var store = ClipStore.shared
    @State private var sync = SyncEngine.shared

    var body: some View {
        List(selection: Binding(get: { state.section }, set: { if let s = $0 { state.section = s } })) {
            Section("Clippings") {
                label("History", "clock", count: store.revision >= 0 ? store.count(.history) : nil).tag(MainState.Section.clips(.history))
                label("Pinned", "pin", count: store.count(.pinned)).tag(MainState.Section.clips(.pinned))
            }
            Section("Pastebins") {
                ForEach(Array(store.library.pastebins.sorted { $0.order < $1.order }.enumerated()), id: \.element.id) { n, bin in
                    label(bin.name, bin.symbol, color: BinColor.color(bin.colorName), count: store.count(.pastebin(bin.id)),
                          shortcut: n < 9 ? "⌃\(n + 1)" : nil)
                        .tag(MainState.Section.clips(.pastebin(bin.id)))
                        .dropDestination(for: String.self) { items, _ in
                            let ids = items.compactMap(UUID.init(uuidString:)).filter { store.clip($0) != nil }
                            if !ids.isEmpty {
                                if case .clips(let scope) = state.section { store.move(ids, to: bin.id, from: scope) } else { store.move(ids, to: bin.id) }
                                return true
                            }
                            // Text dragged in from another app becomes a clipping saved here.
                            for text in items where UUID(uuidString: text) == nil { store.add(.text(text), inHistory: false, pastebins: [bin.id]) }
                            return true
                        }
                        .contextMenu {
                            Button("Edit…") { state.editingPastebin = bin }
                            Button("Delete", role: .destructive) { store.deletePastebin(bin.id) }
                        }
                }
                Button { state.editingPastebin = Pastebin(name: "") } label: { Label("New Pastebin", systemImage: "plus") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary)
            }
            Section("Smart Pastebins") {
                ForEach(store.library.smartPastebins.sorted { $0.order < $1.order }) { bin in
                    label(bin.name, bin.symbol, color: BinColor.color(bin.colorName), count: nil)
                        .tag(MainState.Section.clips(.smart(bin.id)))
                        .contextMenu {
                            Button("Edit…") { state.editingSmart = bin }
                            Button("Delete", role: .destructive) { store.deleteSmart(bin.id) }
                        }
                }
                Button { state.editingSmart = SmartPastebin(name: "", rules: [SmartRule(field: .text, op: .contains, value: "")]) } label: {
                    Label("New Smart Pastebin", systemImage: "plus")
                }.buttonStyle(.borderless).foregroundStyle(.secondary)
            }
            Section("Tools") {
                label("Snippets", "text.badge.plus", count: store.library.snippets.count).tag(MainState.Section.snippets)
                label("Filters", "camera.filters", count: store.library.filters.count).tag(MainState.Section.filters)
                label("Activity", "chart.bar.xaxis", count: nil).tag(MainState.Section.activity)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                if Preferences.shared.paused {
                    Label("Recording paused", systemImage: "pause.circle.fill").foregroundStyle(.orange)
                }
                if sync.enabled {
                    Label(sync.status.summary, systemImage: "icloud").lineLimit(2)
                }
            }
            .font(.caption).foregroundStyle(.secondary).padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(.bar)
        }
    }

    func label(_ title: String, _ symbol: String, color: Color = .accentColor, count: Int?, shortcut: String? = nil) -> some View {
        HStack {
            Label { Text(title) } icon: { Image(systemName: symbol).foregroundStyle(color) }
            Spacer()
            if let shortcut { Text(shortcut).font(.caption).foregroundStyle(.tertiary).help("Press \(shortcut) to move the selected clippings here") }
            if let count { Text("\(count)").font(.caption).foregroundStyle(.secondary) }
        }
    }
}

// MARK: - Clipping list

struct ClipList: View {
    @Bindable var state: MainState
    let scope: ClipStore.Scope
    @State private var store = ClipStore.shared
    @State private var mergeSeparator = "\n"
    @State private var confirmClear = false
    @State private var shortcutFor: Clipping?

    /// Rows load 200 at a time; scrolling to the end loads more.
    @State private var limit = 200

    var clips: [Clipping] {
        _ = store.revision
        return store.clippings(in: scope, query: state.query, limit: limit)
    }

    var body: some View {
        let items = clips
        List(selection: $state.selection) {
            ForEach(items) { clip in
                ClipRowContent(clip: clip, lines: max(Preferences.shared.rowLines, 1))
                    .onAppear { if clip.id == items.last?.id, items.count >= limit { limit += 200 } }
                    .tag(clip.id)
                    .draggable(dragText(clip))
            }
        }
        // Right-click for the menu; double-click pastes into the app that was in front.
        .contextMenu(forSelectionType: UUID.self) { ids in
            ClipMenu(ids: ordered(ids), scope: scope, shortcutFor: $shortcutFor)
        } primaryAction: { ids in
            guard Preferences.shared.windowPaste.onDoubleClick,
                  ids.count == 1, let id = ids.first, let clip = store.clip(id) else { return }
            MainWindow.shared.paste(clip)
        }
        .searchable(text: $state.query, placement: .toolbar, prompt: "Search")
        .onChange(of: state.query) { limit = 200 }
        .onChange(of: scope) { limit = 200 }
        .onDeleteCommand { store.delete(Array(state.selection)) }
        .onCopyCommand {
            let ids = Array(state.selection)
            guard ids.count == 1, let clip = store.clip(ids[0]) else {
                return ids.compactMap { store.text(of: $0) }.map { NSItemProvider(object: $0 as NSString) }
            }
            _ = Paster.copy(clip)
            return []
        }
        .onPasteCommand(of: [.plainText, .png, .fileURL]) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: NSString.self) { text, _ in
                    guard let text = text as? String else { return }
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            if case .pastebin(let id) = scope { store.add(.text(text), inHistory: false, pastebins: [id]) } else { store.add(.text(text)) }
                        }
                    }
                }
            }
        }
        .overlay {
            if items.isEmpty {
                ContentUnavailableView(state.query.isEmpty ? emptyTitle : "No Matches", systemImage: "doc.on.clipboard",
                                       description: Text(state.query.isEmpty ? emptyDetail : "Try different words."))
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Button { copySelected() } label: { Label("Copy", systemImage: "doc.on.doc") }.disabled(state.selection.count != 1)
                    .help("Copy to the clipboard")
                Button { StackController.shared.add(ordered(state.selection)) } label: { Label("Add to Stack", systemImage: "square.stack.3d.up") }
                    .disabled(state.selection.isEmpty).help("Add to the paste stack")
                Button { togglePin() } label: { Label("Pin", systemImage: "pin") }.disabled(state.selection.isEmpty).help("Pin or unpin")
                Menu {
                    ForEach(Array(store.library.pastebins.sorted { $0.order < $1.order }.enumerated()), id: \.element.id) { n, bin in
                        Button(n < 9 ? "\(bin.name)    ⌃\(n + 1)" : bin.name) { moveSelection(to: bin.id) }
                            .disabled(scope == .pastebin(bin.id))
                    }
                } label: { Label("Move to Pastebin", systemImage: "tray.and.arrow.down") }
                    .disabled(state.selection.isEmpty)
                    .help("Move the selected clippings to a pastebin (⌃1–⌃9). ⌘-click to select several.")
                Menu {
                    Button("Merge with New Lines") { merge("\n") }
                    Button("Merge with Blank Lines") { merge("\n\n") }
                    Button("Merge with Spaces") { merge(" ") }
                    Button("Merge with Commas") { merge(", ") }
                } label: { Label("Merge", systemImage: "arrow.triangle.merge") }
                    .disabled(state.selection.count < 2).help("Join the selected clippings into one")
                Button(role: .destructive) { store.delete(Array(state.selection)) } label: { Label("Delete", systemImage: "trash") }
                    .disabled(state.selection.isEmpty)
                if scope == .history {
                    Button { confirmClear = true } label: { Label("Clear History", systemImage: "clear") }
                        .help("Delete everything in History except pinned and saved clippings")
                }
            }
        }
        .confirmationDialog("Clear History?", isPresented: $confirmClear) {
            Button("Clear History", role: .destructive) { store.clearHistory() }
        } message: {
            Text("Every clipping in History is deleted, on all your Macs if sync is on. Clippings in your pastebins and pinned clippings stay.")
        }
        .sheet(item: $shortcutFor) { ClipShortcutSheet(clip: $0) }
        .navigationTitle(title)
    }

    var title: String {
        switch scope {
        case .history: "History"
        case .pinned: "Pinned"
        case .all: "All"
        case .pastebin(let id): store.library.pastebins.first { $0.id == id }?.name ?? "Pastebin"
        case .smart(let id): store.library.smartPastebins.first { $0.id == id }?.name ?? "Smart Pastebin"
        }
    }

    var emptyTitle: String { scope == .history ? "Nothing Copied Yet" : "Empty" }
    var emptyDetail: String {
        switch scope {
        case .history: "Everything you copy appears here."
        case .pastebin: "Drag clippings here, or use Move to Pastebin."
        case .pinned: "Pinned clippings stay no matter how full History gets."
        default: "No clippings match this pastebin's rules yet."
        }
    }

    func menuTargets(_ clip: Clipping) -> [UUID] {
        state.selection.contains(clip.id) ? ordered(state.selection) : [clip.id]
    }

    func ordered(_ ids: Set<UUID>) -> [UUID] { clips.map(\.id).filter(ids.contains) }

    func dragText(_ clip: Clipping) -> String {
        store.text(of: clip.id) ?? clip.previewText
    }

    func copySelected() {
        guard let id = state.selection.first, let clip = store.clip(id) else { return }
        _ = Paster.copy(clip)
    }

    func moveSelection(to bin: UUID) {
        let ids = ordered(state.selection)
        guard !ids.isEmpty else { return }
        store.move(ids, to: bin, from: scope)
        state.selection = []
    }

    func togglePin() {
        let ids = Array(state.selection)
        let allPinned = ids.allSatisfy { store.clip($0)?.pinned == true }
        store.setPinned(ids, !allPinned)
    }

    func merge(_ separator: String) {
        if let clip = store.merge(ordered(state.selection), separator: separator) { state.selection = [clip.id] }
    }
}

/// The right-click menu for one or more clippings.
struct ClipMenu: View {
    let ids: [UUID]
    let scope: ClipStore.Scope
    @Binding var shortcutFor: Clipping?
    @State private var store = ClipStore.shared

    var clips: [Clipping] { ids.compactMap(store.clip) }

    var body: some View {
        if ids.count == 1, let clip = clips.first {
            if Preferences.shared.windowPaste.inMenu {
                Button("Paste") { MainWindow.shared.paste(clip) }
                Button("Paste as Plain Text") { MainWindow.shared.paste(clip, plain: true) }
                Divider()
            }
            Button("Copy") { _ = Paster.copy(clip) }
            Button("Copy as Plain Text") { _ = Paster.copy(clip, plain: true) }
            if let ocr = clip.ocrText, !ocr.isEmpty { Button("Copy Text in Image") { Paster.write(text: ocr) } }
            Menu("Copy with Filter") {
                ForEach(groupedFilters, id: \.0) { group, filters in
                    Section(group) {
                        ForEach(filters) { filter in
                            Button(filter.name) {
                                Task {
                                    do { Paster.write(text: try await FilterApplier.run(filter, on: clip)); store.touch(clip.id) }
                                    catch { presentError(error) }
                                }
                            }
                        }
                    }
                }
            }
            Divider()
        }
        Button(clips.allSatisfy(\.pinned) ? "Unpin" : "Pin") { store.setPinned(ids, !clips.allSatisfy(\.pinned)) }
        Menu("Move to Pastebin") {
            ForEach(store.library.pastebins.sorted { $0.order < $1.order }.filter { scope != .pastebin($0.id) }) { bin in
                Button(bin.name) { store.move(ids, to: bin.id, from: scope) }
            }
        }
        if case .pastebin(let id) = scope { Button("Move Back to History") { store.remove(ids, from: id) } }
        Button("Add to Stack") { StackController.shared.add(ids) }
        if ids.count > 1 { Button("Merge") { _ = store.merge(ids, separator: "\n") } }
        if ids.count == 1, let clip = clips.first {
            Button(store.clipHotKeys[clip.id] == nil ? "Assign Shortcut…" : "Change Shortcut…") { shortcutFor = clip }
            if clip.kind == .file, let path = clip.previewText.split(separator: "\n").first {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: String(path))]) }
            }
            if clip.kind == .url, let url = URL(string: clip.previewText.trimmingCharacters(in: .whitespacesAndNewlines)) {
                Button("Open Link") { NSWorkspace.shared.open(url) }
            }
            Button("Share…") { share(clip) }
            if clip.sensitive {
                Button("Mark as Not Secret") { store.update(clip.id) { $0.sensitive = false; $0.expiresAt = nil; $0.title = nil } }
            }
        }
        Divider()
        Button("Delete", role: .destructive) { store.delete(ids) }
    }

    var groupedFilters: [(String, [Filter])] {
        Dictionary(grouping: store.library.filters) { $0.group.isEmpty ? "Other" : $0.group }
            .sorted { $0.key < $1.key }.map { ($0.key, $0.value.sorted { $0.name < $1.name }) }
    }

    func share(_ clip: Clipping) {
        var items: [Any] = []
        if clip.kind == .image, let image = Thumbnails.image(for: clip, maxSide: 4000) { items = [image] }
        else if let text = store.text(of: clip.id) { items = [text] }
        guard let view = NSApp.keyWindow?.contentView else { return }
        let picker = NSSharingServicePicker(items: items)
        let mouse = view.convert(view.window!.mouseLocationOutsideOfEventStream, from: nil)
        picker.show(relativeTo: NSRect(origin: mouse, size: .init(width: 1, height: 1)), of: view, preferredEdge: .minY)
    }
}

@MainActor
func presentError(_ error: Error) {
    let alert = NSAlert()
    alert.messageText = "Couldn't Apply the Filter"
    alert.informativeText = error.localizedDescription
    alert.runModal()
}

struct MultiSelectionView: View {
    let ids: [UUID]
    @State private var store = ClipStore.shared
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "square.on.square").font(.largeTitle).foregroundStyle(.secondary)
            Text("\(ids.count) Clippings Selected").font(.title3)
            HStack {
                Button("Add to Stack") { StackController.shared.add(ids) }
                Button("Merge") { _ = store.merge(ids, separator: "\n") }
                Button("Delete", role: .destructive) { store.delete(ids) }
            }
        }
    }
}

struct ClipShortcutSheet: View {
    let clip: Clipping
    @Environment(\.dismiss) private var dismiss
    @State private var key: HotKey?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Shortcut for “\(clip.displayTitle.prefix(40))”").font(.headline)
            Text("Pressing it anywhere pastes this clipping.").foregroundStyle(.secondary)
            ShortcutRecorder(hotKey: $key)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    ClipStore.shared.setHotKey(key?.stored, forClip: clip.id)
                    ClipStore.shared.update(clip.id) { $0.pinned = true }
                    dismiss()
                }.keyboardShortcut(.defaultAction)
            }
            Text("Clippings with a shortcut are pinned, so they're never removed from History.").font(.caption).foregroundStyle(.secondary)
        }
        .padding(20).frame(width: 380)
        .onAppear { key = ClipStore.shared.clipHotKeys[clip.id].map(HotKey.init) }
    }
}

// MARK: - Pastebin editors

struct PastebinEditor: View {
    @State var bin: Pastebin
    @Environment(\.dismiss) private var dismiss
    @State private var key: HotKey?
    static let symbols = ["tray.full", "star", "heart", "bookmark", "folder", "briefcase", "hammer", "chevron.left.forwardslash.chevron.right",
                          "envelope", "person", "cart", "graduationcap", "lightbulb", "flag", "tag", "link"]

    var body: some View {
        Form {
            TextField("Name", text: $bin.name)
            Picker("Icon", selection: $bin.symbol) {
                ForEach(Self.symbols, id: \.self) { Image(systemName: $0).tag($0) }
            }
            Picker("Color", selection: $bin.colorName) {
                ForEach(BinColor.names, id: \.self) { name in
                    Label(name.capitalized, systemImage: "circle.fill").foregroundStyle(BinColor.color(name)).tag(name)
                }
            }
            Toggle("Show in Quick Paste", isOn: $bin.showInQuickPaste)
            LabeledContent("Shortcut") { ShortcutRecorder(hotKey: $key) }
            Text("The shortcut opens Quick Paste on this pastebin.").font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    bin.hotKey = key?.stored
                    ClipStore.shared.upsertPastebin(bin)
                    dismiss()
                }.keyboardShortcut(.defaultAction).disabled(bin.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }.padding()
        }
        .frame(width: 400)
        .onAppear { key = bin.hotKey.map(HotKey.init) }
    }
}

struct SmartPastebinEditor: View {
    @State var bin: SmartPastebin
    @Environment(\.dismiss) private var dismiss
    @State private var store = ClipStore.shared

    var matching: Int {
        let now = Date()
        var n = 0
        store.db.forEach(.all) { clip in
            if bin.matches(clip, now: now) { n += 1 }
            return n < 10_000
        }
        return n
    }

    var body: some View {
        Form {
            TextField("Name", text: $bin.name)
            Picker("Icon", selection: $bin.symbol) {
                ForEach(["sparkles.rectangle.stack", "link", "photo", "paintpalette", "calendar", "doc.text", "terminal", "envelope", "number"], id: \.self) {
                    Image(systemName: $0).tag($0)
                }
            }
            Picker("Color", selection: $bin.colorName) {
                ForEach(BinColor.names, id: \.self) { Text($0.capitalized).tag($0) }
            }
            Picker("Contain clippings that match", selection: $bin.match) {
                Text("all of these rules").tag(SmartPastebin.Match.all)
                Text("any of these rules").tag(SmartPastebin.Match.any)
            }
            Section {
                ForEach($bin.rules) { $rule in
                    HStack {
                        Picker("", selection: $rule.field) { ForEach(SmartRule.Field.allCases, id: \.self) { Text($0.label).tag($0) } }
                            .labelsHidden().frame(width: 130)
                            .onChange(of: rule.field) { if !rule.field.ops.contains(rule.op) { rule.op = rule.field.ops[0] } }
                        Picker("", selection: $rule.op) { ForEach(rule.field.ops, id: \.self) { Text($0.label).tag($0) } }
                            .labelsHidden().frame(width: 150)
                        if rule.field == .kind {
                            Picker("", selection: $rule.value) { ForEach(ClipKind.allCases, id: \.self) { Text($0.label).tag($0.rawValue) } }.labelsHidden()
                        } else {
                            TextField("", text: $rule.value)
                        }
                        Button { bin.rules.removeAll { $0.id == rule.id } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless).disabled(bin.rules.count == 1)
                    }
                }
                Button { bin.rules.append(SmartRule(field: .text, op: .contains, value: "")) } label: { Label("Add Rule", systemImage: "plus") }
            } footer: {
                Text("\(matching) clipping\(matching == 1 ? "" : "s") match now.").font(.caption)
            }
            Toggle("Show in Quick Paste", isOn: $bin.showInQuickPaste)
        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { store.upsertSmart(bin); dismiss() }.keyboardShortcut(.defaultAction)
                    .disabled(bin.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }.padding()
        }
        .frame(width: 560, height: 480)
    }
}

