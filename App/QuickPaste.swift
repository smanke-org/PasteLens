import AppKit
import Carbon.HIToolbox
import Observation
import PasteLensKit
import SwiftUI

/// The search-and-paste panel. It never activates PasteLens, so the app you were typing in
/// stays in front and receives the paste.
@MainActor
final class QuickPastePanel {
    static let shared = QuickPastePanel()

    private var panel: KeyPanel?
    private var keyMonitor: Any?
    private var flagsMonitor: Any?
    let model = QuickPasteModel()

    var isVisible: Bool { panel?.isVisible == true }

    /// - Parameters:
    ///   - source: which list to open on.
    ///   - viaHotKey: opened by its shortcut, so "release to paste" may apply.
    func toggle(source: QuickPasteModel.Source = .history, viaHotKey: Bool = false) {
        if isVisible {
            // Pressing the shortcut again moves down the list, like ⌘Tab.
            if viaHotKey { model.move(1) } else { close() }
            return
        }
        show(source: source, viaHotKey: viaHotKey)
    }

    func show(source: QuickPasteModel.Source = .history, viaHotKey: Bool = false) {
        Activity.shared.touch()
        SyncEngine.shared.pull()
        model.reset(source: source)
        model.releaseToPaste = viaHotKey && Preferences.shared.releaseToPaste && Self.modifiersHeld
        if panel == nil {
            let panel = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: 760, height: 460),
                                 styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView, .resizable],
                                 backing: .buffered, defer: false)
            panel.titleVisibility = .hidden
            panel.titlebarAppearsTransparent = true
            panel.standardWindowButton(.closeButton)?.isHidden = true
            panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
            panel.standardWindowButton(.zoomButton)?.isHidden = true
            panel.isMovableByWindowBackground = true
            panel.level = .popUpMenu
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
            panel.contentMinSize = NSSize(width: 460, height: 300)
            panel.setFrameAutosaveName("PasteLensQuickPaste")
            let hosting = NSHostingView(rootView: QuickPasteView(model: model))
            panel.contentView = hosting
            panel.onResignKey = { [weak self] in self?.close() }
            self.panel = panel
        }
        position()
        panel?.makeKeyAndOrderFront(nil)
        installMonitors()
    }

    private static var modifiersHeld: Bool {
        !NSEvent.modifierFlags.intersection([.command, .option, .control]).isEmpty
    }

    private func position() {
        guard let panel else { return }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        var frame = panel.frame
        frame.size.width = min(frame.width, visible.width - 40)
        frame.size.height = min(frame.height, visible.height - 40)
        if Preferences.shared.quickPasteAtMouse {
            frame.origin = NSPoint(x: mouse.x - 40, y: mouse.y - frame.height + 20)
        } else {
            frame.origin = NSPoint(x: visible.midX - frame.width / 2, y: visible.midY - frame.height / 2 + visible.height * 0.1)
        }
        frame.origin.x = min(max(frame.origin.x, visible.minX + 10), visible.maxX - frame.width - 10)
        frame.origin.y = min(max(frame.origin.y, visible.minY + 10), visible.maxY - frame.height - 10)
        panel.setFrame(frame, display: false)
    }

    func close() {
        removeMonitors()
        panel?.orderOut(nil)
        model.filterMode = nil
    }

    private func installMonitors() {
        removeMonitors()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isVisible, event.window === self.panel else { return event }
            return self.model.handle(event) ? nil : event
        }
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            guard let self, self.isVisible, self.model.releaseToPaste else { return event }
            if event.modifierFlags.intersection([.command, .option, .control]).isEmpty {
                self.model.releaseToPaste = false
                self.model.activate(.paste)
            }
            return event
        }
    }

    private func removeMonitors() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let flagsMonitor { NSEvent.removeMonitor(flagsMonitor) }
        keyMonitor = nil
        flagsMonitor = nil
    }
}

final class KeyPanel: NSPanel {
    var onResignKey: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func resignKey() {
        super.resignKey()
        // Clicking elsewhere dismisses it, the way a menu would.
        DispatchQueue.main.async { [weak self] in
            if self?.isKeyWindow == false, self?.attachedSheet == nil { self?.onResignKey?() }
        }
    }
}

@Observable
@MainActor
final class QuickPasteModel {
    enum Source: Hashable {
        case history, pinned, pastebin(UUID), smart(UUID), snippets

        var scope: ClipStore.Scope? {
            switch self {
            case .history: .history
            case .pinned: .pinned
            case .pastebin(let id): .pastebin(id)
            case .smart(let id): .smart(id)
            case .snippets: nil
            }
        }
    }

    enum Action { case paste, pastePlain, typeOut, copy }

    var query = "" { didSet { selection = 0; refreshPreview() } }
    var source: Source = .history { didSet { selection = 0 } }
    var selection = 0 { didSet { refreshPreview() } }
    var releaseToPaste = false
    /// When set, the list shows filters to apply to this clipping.
    var filterMode: Clipping? { didSet { query = ""; selection = 0 } }
    var filterPreview: String?
    var filterError: String?
    @ObservationIgnored private var previewTask: Task<Void, Never>?

    var sources: [(Source, String, String)] {
        let lib = ClipStore.shared.library
        var out: [(Source, String, String)] = [(.history, "History", "clock")]
        if lib.clippings.contains(where: \.pinned) { out.append((.pinned, "Pinned", "pin")) }
        for bin in lib.pastebins.sorted(by: { $0.order < $1.order }) where bin.showInQuickPaste {
            out.append((.pastebin(bin.id), bin.name, bin.symbol))
        }
        for bin in lib.smartPastebins.sorted(by: { $0.order < $1.order }) where bin.showInQuickPaste {
            out.append((.smart(bin.id), bin.name, bin.symbol))
        }
        out.append((.snippets, "Snippets", "text.badge.plus"))
        return out
    }

    func reset(source: Source) {
        filterMode = nil
        self.source = source
        query = ""
        selection = 0
    }

    @ObservationIgnored private var clipsKey = ""
    @ObservationIgnored private var clipsCache: [Clipping] = []

    /// The list, read once per change of source, search or library rather than on every use.
    var clips: [Clipping] {
        let revision = ClipStore.shared.revision
        guard let scope = source.scope else { return [] }
        let key = "\(scope)|\(query)|\(revision)"
        if key != clipsKey {
            clipsCache = ClipStore.shared.clippings(in: scope, query: query, limit: 300)
            clipsKey = key
        }
        return clipsCache
    }

    var snippets: [Snippet] {
        let all = ClipStore.shared.library.snippets.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        guard !query.isEmpty else { return all }
        return all.filter { FuzzySearch.score(query, in: "\($0.name) \($0.abbreviation) \($0.template)") != nil }
    }

    var filters: [Filter] {
        let all = ClipStore.shared.library.filters.filter(\.showInQuickPaste)
        guard !query.isEmpty else { return all }
        return all.compactMap { f in FuzzySearch.score(query, in: "\(f.name) \(f.group)").map { (f, $0) } }
            .sorted { $0.1 > $1.1 }.map(\.0)
    }

    var count: Int {
        if filterMode != nil { return filters.count }
        return source == .snippets ? snippets.count : clips.count
    }

    var selectedClip: Clipping? {
        if let filterMode { return filterMode }
        let c = clips
        return c.indices.contains(selection) ? c[selection] : nil
    }

    var selectedSnippet: Snippet? {
        let s = snippets
        return source == .snippets && s.indices.contains(selection) ? s[selection] : nil
    }

    var selectedFilter: Filter? {
        let f = filters
        return filterMode != nil && f.indices.contains(selection) ? f[selection] : nil
    }

    func move(_ delta: Int) {
        guard count > 0 else { return }
        selection = (selection + delta + count) % count
    }

    func cycleSource(_ delta: Int) {
        let all = sources.map(\.0)
        guard let i = all.firstIndex(of: source) else { source = .history; return }
        source = all[(i + delta + all.count) % all.count]
    }

    private func refreshPreview() {
        previewTask?.cancel()
        filterPreview = nil
        filterError = nil
        guard let clip = filterMode, let filter = selectedFilter else { return }
        previewTask = Task {
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            do {
                let out = try await FilterApplier.run(filter, on: clip)
                if !Task.isCancelled { filterPreview = out }
            } catch {
                if !Task.isCancelled { filterError = error.localizedDescription }
            }
        }
    }

    /// Keyboard handling for the panel. Returns true when the key was used.
    func handle(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let code = Int(event.keyCode)
        switch code {
        case kVK_DownArrow: move(1); return true
        case kVK_UpArrow: move(-1); return true
        case kVK_PageDown: move(8); return true
        case kVK_PageUp: move(-8); return true
        case kVK_Escape:
            if filterMode != nil { filterMode = nil } else if !query.isEmpty { query = "" } else { QuickPastePanel.shared.close() }
            return true
        case kVK_Tab:
            guard filterMode == nil else { return true }
            cycleSource(flags.contains(.shift) ? -1 : 1)
            return true
        case kVK_Return, kVK_ANSI_KeypadEnter:
            if flags.contains(.command) {
                if filterMode == nil, let clip = selectedClip { filterMode = clip } // ⌘↩ opens filters
                return true
            }
            if flags.contains(.option) { activate(.typeOut); return true }
            activate(flags.contains(.shift) ? .pastePlain : .paste)
            return true
        default: break
        }
        guard flags == .command || flags == [.command, .shift] else { return false }
        if let digit = Int(event.charactersIgnoringModifiers ?? ""), (1...9).contains(digit), filterMode == nil {
            selection = digit - 1
            if selection < count { activate(.paste) }
            return true
        }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "c": activate(.copy); return true
        case "p": if let clip = selectedClip { ClipStore.shared.setPinned([clip.id], !clip.pinned) }; return true
        case "s": if let clip = selectedClip { StackController.shared.add([clip.id]) }; return true
        case "o": QuickPastePanel.shared.close(); MainWindow.shared.show(selecting: selectedClip?.id); return true
        case "\u{7f}", "\u{8}": // ⌘⌫
            if let clip = selectedClip, filterMode == nil { ClipStore.shared.delete([clip.id]); selection = min(selection, max(count - 1, 0)) }
            return true
        default: break
        }
        if code == kVK_Delete, filterMode == nil, let clip = selectedClip {
            ClipStore.shared.delete([clip.id])
            return true
        }
        return false
    }

    func activate(_ action: Action) {
        if let filterMode, let filter = selectedFilter {
            let clip = filterMode
            Task {
                do {
                    let text = try await FilterApplier.run(filter, on: clip)
                    QuickPastePanel.shared.close()
                    action == .copy ? Paster.write(text: text) : action == .typeOut ? Paster.typeOut(text) : Paster.paste(text: text)
                } catch {
                    filterError = error.localizedDescription
                    SoundPlayer.play(.error)
                }
            }
            return
        }
        if let snippet = selectedSnippet {
            QuickPastePanel.shared.close()
            if action == .copy { Paster.write(text: SnippetPaster.expand(snippet, inputs: [:])) } else { SnippetPaster.paste(snippet) }
            return
        }
        guard let clip = selectedClip else { return }
        QuickPastePanel.shared.close()
        switch action {
        case .paste: Paster.paste(clip)
        case .pastePlain: Paster.paste(clip, plain: true)
        case .copy: _ = Paster.copy(clip)
        case .typeOut:
            if let text = FilterApplier.sourceText(for: clip) { Paster.typeOut(text) }
        }
    }
}

struct QuickPasteView: View {
    @Bindable var model: QuickPasteModel
    @State private var store = ClipStore.shared
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                list.frame(minWidth: 280)
                Divider()
                preview.frame(minWidth: 220, maxWidth: .infinity)
            }
            Divider()
            footer
        }
        .background(.regularMaterial)
        .onAppear { searchFocused = true }
    }

    var header: some View {
        VStack(spacing: 6) {
            HStack {
                Image(systemName: model.filterMode == nil ? "magnifyingglass" : "camera.filters").foregroundStyle(.secondary)
                TextField(model.filterMode == nil ? "Search \(currentSourceName)" : "Choose a filter", text: $model.query)
                    .textFieldStyle(.plain).font(.title3).focused($searchFocused)
                if model.releaseToPaste {
                    Text("Release to paste").font(.caption).padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.tint.opacity(0.2), in: .capsule)
                }
            }
            if model.filterMode == nil {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(model.sources, id: \.0) { source, name, symbol in
                            Button { model.source = source } label: {
                                Label(name, systemImage: symbol).font(.caption).padding(.horizontal, 8).padding(.vertical, 3)
                                    .background(model.source == source ? Color.accentColor.opacity(0.25) : .clear, in: .capsule)
                            }.buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 12).padding(.top, 14).padding(.bottom, 8)
    }

    var currentSourceName: String { model.sources.first { $0.0 == model.source }?.1 ?? "History" }

    @ViewBuilder var list: some View {
        ScrollViewReader { proxy in
            List {
                if model.filterMode != nil {
                    ForEach(Array(model.filters.enumerated()), id: \.element.id) { index, filter in
                        row(index) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(filter.name)
                                Text(filter.group.isEmpty ? filter.steps.map(\.summary).joined(separator: " → ") : filter.group)
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                } else if model.source == .snippets {
                    ForEach(Array(model.snippets.enumerated()), id: \.element.id) { index, snippet in
                        row(index) {
                            HStack {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(snippet.name)
                                    Text(snippet.template.replacingOccurrences(of: "\n", with: " ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                if !snippet.abbreviation.isEmpty { Text(snippet.abbreviation).font(.caption.monospaced()).foregroundStyle(.tertiary) }
                            }
                        }
                    }
                } else {
                    ForEach(Array(model.clips.enumerated()), id: \.element.id) { index, clip in
                        row(index) { ClipRowContent(clip: clip, lines: Preferences.shared.rowLines, index: index) }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .overlay {
                if model.count == 0 {
                    ContentUnavailableView(model.query.isEmpty ? "Nothing Here Yet" : "No Matches", systemImage: "doc.on.clipboard")
                }
            }
            .onChange(of: model.selection) { proxy.scrollTo(model.selection) }
        }
    }

    func row<Content: View>(_ index: Int, @ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(.vertical, 3).padding(.horizontal, 6)
            .background(index == model.selection ? Color.accentColor.opacity(0.28) : .clear, in: .rect(cornerRadius: 6))
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))
            .id(index)
            .onTapGesture(count: 2) { model.selection = index; model.activate(.paste) }
            .onTapGesture { model.selection = index }
    }

    @ViewBuilder var preview: some View {
        if model.filterMode != nil {
            VStack(alignment: .leading, spacing: 8) {
                Text("Result").font(.caption).foregroundStyle(.secondary)
                ScrollView {
                    Group {
                        if let error = model.filterError { Text(error).foregroundStyle(.red) }
                        else if model.filterMode?.sensitive == true {
                            Label("Hidden, because the clipping looks like a secret. Press Return to paste the result.", systemImage: "lock.fill")
                                .foregroundStyle(.secondary)
                        }
                        else if let out = model.filterPreview { Text(out).font(.body.monospaced()).textSelection(.enabled) }
                        else { ProgressView().controlSize(.small) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }.padding(10)
        } else if let snippet = model.selectedSnippet {
            ScrollView {
                Text(snippet.template).font(.body.monospaced()).frame(maxWidth: .infinity, alignment: .leading).padding(10)
            }
        } else if let clip = model.selectedClip {
            ClipPreview(clip: clip, editable: false)
        } else {
            Color.clear
        }
    }

    var footer: some View {
        HStack(spacing: 14) {
            hint("↩", "Paste"); hint("⇧↩", "Plain"); hint("⌘↩", "Filter"); hint("⌥↩", "Type")
            hint("⇥", "Switch"); hint("⌘S", "Stack"); hint("⌘P", "Pin"); hint("⌘O", "Open")
            Spacer()
        }
        .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.vertical, 6)
    }

    func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 3) { Text(key).fontWeight(.semibold); Text(label) }
    }
}
