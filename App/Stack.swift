import AppKit
import Observation
import PasteLensKit
import SwiftUI

/// A queue of clippings to paste one after another: add several, then press "Paste Next"
/// repeatedly. Optionally, everything copied while the stack is collecting joins it.
@Observable
@MainActor
final class StackController {
    static let shared = StackController()

    private(set) var items: [UUID] = []
    /// While on, every new copy is added to the stack.
    var collecting = false
    /// Paste from the top (first in, first out) or the bottom (last in, first out).
    var firstInFirstOut = true

    func add(_ ids: [UUID]) {
        for id in ids where !items.contains(id) { items.append(id) }
        SoundPlayer.play(.stackAdd)
        StackWindow.shared.showIfNeeded()
    }

    func remove(_ ids: [UUID]) { items.removeAll { ids.contains($0) } }

    func clear() {
        items.removeAll()
        collecting = false
    }

    func move(from source: IndexSet, to destination: Int) { items.move(fromOffsets: source, toOffset: destination) }

    func didCopy(_ clip: Clipping) {
        if collecting, !items.contains(clip.id) { add([clip.id]) }
    }

    /// Copies the selection in the front app (⌘C) and adds what arrives to the stack.
    func copySelectionToStack() {
        Paster.copySelection()
        let before = NSPasteboard.general.changeCount
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            MainActor.assumeIsolated {
                guard NSPasteboard.general.changeCount != before, let clip = ClipboardMonitor.shared.captureNow() ?? ClipStore.shared.history.first else {
                    SoundPlayer.play(.error)
                    return
                }
                StackController.shared.add([clip.id])
            }
        }
    }

    /// Pastes the next item and takes it off the stack.
    func pasteNext() {
        items.removeAll { ClipStore.shared.clip($0) == nil }
        guard let id = firstInFirstOut ? items.first : items.last, let clip = ClipStore.shared.clip(id) else {
            SoundPlayer.play(.error)
            return
        }
        items.removeAll { $0 == id }
        Paster.paste(clip)
        if items.isEmpty { collecting = false }
    }

    func libraryChanged() { items.removeAll { ClipStore.shared.clip($0) == nil } }
}

/// A small floating window listing the stack.
@MainActor
final class StackWindow {
    static let shared = StackWindow()
    private var panel: NSPanel?

    var isVisible: Bool { panel?.isVisible == true }

    func showIfNeeded() { if !isVisible { show() } }

    func toggle() { isVisible ? panel?.orderOut(nil) : show() }

    func show() {
        if panel == nil {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 360),
                                styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
                                backing: .buffered, defer: false)
            panel.title = "Stack"
            panel.isFloatingPanel = true
            panel.level = .floating
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.contentView = NSHostingView(rootView: StackView())
            if let screen = NSScreen.main {
                panel.setFrameTopLeftPoint(NSPoint(x: screen.visibleFrame.maxX - 320, y: screen.visibleFrame.maxY - 20))
            }
            panel.setFrameAutosaveName("PasteLensStack")
            self.panel = panel
        }
        panel?.orderFrontRegardless()
    }
}

struct StackView: View {
    @State private var stack = StackController.shared
    @State private var store = ClipStore.shared

    var body: some View {
        VStack(spacing: 0) {
            if stack.items.isEmpty {
                ContentUnavailableView("Stack Is Empty", systemImage: "square.stack.3d.up",
                                       description: Text("Add clippings with “Add to Stack”, or turn on Collect and copy things one after another."))
            } else {
                List {
                    ForEach(Array(stack.items.enumerated()), id: \.element) { index, id in
                        if let clip = store.clip(id) {
                            HStack {
                                Text("\(index + 1)").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 18)
                                ClipRowContent(clip: clip, lines: 1)
                                Spacer()
                                Button { stack.remove([id]) } label: { Image(systemName: "xmark.circle.fill") }
                                    .buttonStyle(.plain).foregroundStyle(.tertiary)
                            }
                        }
                    }
                    .onMove { stack.move(from: $0, to: $1) }
                }
            }
            Divider()
            HStack {
                Toggle("Collect", isOn: $stack.collecting).toggleStyle(.checkbox)
                    .help("Add everything you copy to the stack")
                Picker("", selection: $stack.firstInFirstOut) {
                    Text("First In, First Out").tag(true)
                    Text("Last In, First Out").tag(false)
                }.labelsHidden().controlSize(.small).fixedSize()
                Spacer()
                Button("Clear") { stack.clear() }.disabled(stack.items.isEmpty)
            }
            .padding(8)
            if let key = Preferences.shared.hotKey(.pasteFromStack) {
                Text("Press \(key.display) to paste the next item").font(.caption).foregroundStyle(.secondary).padding(.bottom, 8)
            }
        }
        .frame(minWidth: 260, minHeight: 200)
    }
}
