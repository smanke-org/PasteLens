import AppKit
import Carbon.HIToolbox
import PasteLensKit
import SwiftUI

/// Types a snippet's text when you type its abbreviation anywhere. Watches keystrokes through
/// a listen-only event tap (needs Input Monitoring), erases the abbreviation with Delete
/// presses, then pastes the expansion.
@MainActor
final class SnippetExpander {
    static let shared = SnippetExpander()

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var buffer = ""
    private var abbreviations: [String: UUID] = [:]
    private(set) var permissionMissing = false

    var running: Bool { tap != nil }

    func refresh() {
        abbreviations = [:]
        for snippet in ClipStore.shared.library.snippets where !snippet.abbreviation.isEmpty {
            abbreviations[snippet.abbreviation] = snippet.id
        }
        if Preferences.shared.expansion && !abbreviations.isEmpty { start() } else { stop() }
    }

    static var inputMonitoringGranted: Bool { CGPreflightListenEventAccess() }

    static func requestInputMonitoring() { CGRequestListenEventAccess() }

    private func start() {
        guard tap == nil else { return }
        guard Self.inputMonitoringGranted else {
            permissionMissing = true
            Self.requestInputMonitoring()
            return
        }
        permissionMissing = false
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue) | CGEventMask(1 << CGEventType.leftMouseDown.rawValue)
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly,
                                          eventsOfInterest: mask, callback: expanderCallback, userInfo: nil) else {
            permissionMissing = true
            return
        }
        self.tap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        tap = nil
        runLoopSource = nil
        buffer = ""
    }

    fileprivate func handle(_ type: CGEventType, _ event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        guard type == .keyDown else { buffer = ""; return }
        let flags = event.flags
        if flags.contains(.maskCommand) || flags.contains(.maskControl) { buffer = ""; return }
        // Not in our own windows, and never in password fields (secure input hides keys anyway).
        if NSApp.isActive || IsSecureEventInputEnabled() { buffer = ""; return }
        let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
        if code == kVK_Delete { buffer = String(buffer.dropLast()); return }
        if [kVK_Return, kVK_Tab, kVK_Escape, kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow].contains(code) { buffer = ""; return }
        var length = 0
        var chars = [UniChar](repeating: 0, count: 4)
        event.keyboardGetUnicodeString(maxStringLength: 4, actualStringLength: &length, unicodeString: &chars)
        guard length > 0 else { return }
        buffer += String(utf16CodeUnits: chars, count: length)
        if buffer.count > 64 { buffer = String(buffer.suffix(64)) }
        for (abbreviation, id) in abbreviations where buffer.hasSuffix(abbreviation) {
            buffer = ""
            expand(id, erasing: abbreviation.count)
            return
        }
    }

    private func expand(_ id: UUID, erasing count: Int) {
        guard let snippet = ClipStore.shared.library.snippets.first(where: { $0.id == id }) else { return }
        // Let the last typed key land before erasing.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            for _ in 0..<count { Paster.postKey(CGKeyCode(kVK_Delete), flags: []) }
            SnippetPaster.paste(snippet, delay: 0.05)
        }
    }
}

private func expanderCallback(_ proxy: CGEventTapProxy, _ type: CGEventType, _ event: CGEvent, _ info: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    MainActor.assumeIsolated { SnippetExpander.shared.handle(type, event) }
    return Unmanaged.passUnretained(event)
}

/// Expands and pastes snippets, asking for {input:…} fields first.
@MainActor
enum SnippetPaster {
    static func paste(_ snippet: Snippet, delay: TimeInterval = 0) {
        let fields = Template.fields(in: snippet.template)
        let finish: ([String: String]) -> Void = { inputs in
            Task { @MainActor in
                let clipboard = NSPasteboard.general.string(forType: .string) ?? ""
                let expansion = Template.expand(snippet.template, clipboard: clipboard, inputs: inputs)
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    Paster.paste(text: expansion.text, cursorFromEnd: expansion.cursorFromEnd)
                }
            }
        }
        if fields.isEmpty { finish([:]) } else { FieldPrompt.ask(snippet.name, fields: fields, completion: finish) }
    }

    static func expand(_ snippet: Snippet, inputs: [String: String]) -> String {
        Template.expand(snippet.template, clipboard: NSPasteboard.general.string(forType: .string) ?? "", inputs: inputs).text
    }
}

/// A small window that asks for a snippet's fill-in fields, then hands back focus.
@MainActor
enum FieldPrompt {
    private static var panel: NSPanel?

    static func ask(_ title: String, fields: [Template.Field], completion: @escaping ([String: String]) -> Void) {
        let previous = NSWorkspace.shared.frontmostApplication
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 100), styleMask: [.titled, .closable],
                            backing: .buffered, defer: false)
        panel.title = title
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        let close: ([String: String]?) -> Void = { values in
            panel.orderOut(nil)
            Self.panel = nil
            previous?.activate()
            if let values { completion(values) }
        }
        panel.contentView = NSHostingView(rootView: FieldPromptView(fields: fields, done: close))
        panel.setContentSize(panel.contentView!.fittingSize)
        panel.center()
        Self.panel = panel
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }
}

struct FieldPromptView: View {
    let fields: [Template.Field]
    let done: ([String: String]?) -> Void
    @State private var values: [String: String] = [:]
    @FocusState private var focused: String?

    var body: some View {
        Form {
            ForEach(fields, id: \.name) { field in
                TextField(field.name, text: Binding(get: { values[field.name] ?? field.defaultValue }, set: { values[field.name] = $0 }))
                    .focused($focused, equals: field.name)
            }
        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Spacer()
                Button("Cancel") { done(nil) }.keyboardShortcut(.cancelAction)
                Button("Paste") {
                    var all: [String: String] = [:]
                    for f in fields { all[f.name] = values[f.name] ?? f.defaultValue }
                    done(all)
                }.keyboardShortcut(.defaultAction)
            }.padding()
        }
        .frame(width: 360)
        .onAppear { focused = fields.first?.name }
    }
}
