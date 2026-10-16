import AppKit
import Carbon.HIToolbox
import PasteLensKit
import SwiftUI

/// A keyboard shortcut: a key code plus Carbon modifier flags, and how to show it.
struct HotKey: Codable, Equatable, Hashable {
    var keyCode: UInt32
    var modifiers: UInt32
    var display: String

    static let controlOptionCommand = UInt32(controlKey | optionKey | cmdKey)

    init(_ stored: StoredHotKey) {
        self.init(keyCode: stored.keyCode, modifiers: stored.modifiers, display: stored.display)
    }

    var stored: StoredHotKey { StoredHotKey(keyCode: keyCode, modifiers: modifiers, display: display) }

    init(keyCode: UInt32, modifiers: UInt32, display: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.display = display
    }

    /// Builds one from a key press, if it has at least one of ⌘ ⌥ ⌃ — a bare key would
    /// steal ordinary typing from every app.
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !flags.intersection([.command, .option, .control]).isEmpty else { return nil }
        keyCode = UInt32(event.keyCode)
        modifiers = Self.carbon(flags)
        display = Self.symbols(flags) + Self.name(for: event)
    }

    /// Whether a key press is this shortcut.
    func matches(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> Bool {
        UInt32(keyCode) == self.keyCode
            && Self.carbon(flags.intersection([.command, .option, .control, .shift])) == modifiers
    }

    /// For showing the shortcut beside a menu item.
    var menuKeyEquivalent: (key: String, mask: NSEvent.ModifierFlags) {
        var mask: NSEvent.ModifierFlags = []
        if modifiers & UInt32(controlKey) != 0 { mask.insert(.control) }
        if modifiers & UInt32(optionKey) != 0 { mask.insert(.option) }
        if modifiers & UInt32(shiftKey) != 0 { mask.insert(.shift) }
        if modifiers & UInt32(cmdKey) != 0 { mask.insert(.command) }
        let key = display.drop(while: { "⌃⌥⇧⌘".contains($0) }).lowercased()
        return (key.count == 1 ? key : "", mask)
    }

    private static func carbon(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var carbon: UInt32 = 0
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        return carbon
    }

    private static func symbols(_ flags: NSEvent.ModifierFlags) -> String {
        var s = ""
        if flags.contains(.control) { s += "⌃" }
        if flags.contains(.option) { s += "⌥" }
        if flags.contains(.shift) { s += "⇧" }
        if flags.contains(.command) { s += "⌘" }
        return s
    }

    /// Builds one from a key code and Carbon modifiers, as caught while recording.
    init?(keyCode: UInt32, carbonModifiers: UInt32) {
        var flags: NSEvent.ModifierFlags = []
        if carbonModifiers & UInt32(controlKey) != 0 { flags.insert(.control) }
        if carbonModifiers & UInt32(optionKey) != 0 { flags.insert(.option) }
        if carbonModifiers & UInt32(shiftKey) != 0 { flags.insert(.shift) }
        if carbonModifiers & UInt32(cmdKey) != 0 { flags.insert(.command) }
        guard let name = Self.name(code: Int(keyCode), characters: Self.layoutCharacter(UInt16(keyCode))) else { return nil }
        self.keyCode = keyCode
        self.modifiers = carbonModifiers
        self.display = Self.symbols(flags) + name
    }

    /// The character a key types on the current keyboard layout, with no modifiers.
    static func layoutCharacter(_ code: UInt16) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        return data.withUnsafeBytes { buffer -> String? in
            guard let layout = buffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            var dead: UInt32 = 0
            var length = 0
            var chars = [UniChar](repeating: 0, count: 4)
            let status = UCKeyTranslate(layout, code, UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                        OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, 4, &length, &chars)
            guard status == noErr, length > 0 else { return nil }
            let s = String(utf16CodeUnits: chars, count: length)
            return s.trimmingCharacters(in: .controlCharacters).isEmpty ? nil : s
        }
    }

    private static func name(for event: NSEvent) -> String {
        name(code: Int(event.keyCode), characters: event.charactersIgnoringModifiers) ?? "?"
    }

    private static func name(code: Int, characters: String?) -> String? {
        if let f = fKeys[code] { return "F\(f)" }
        switch code {
        case kVK_Return: return "↩"
        case kVK_Space: return "Space"
        case kVK_Escape: return "⎋"
        case kVK_Tab: return "⇥"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_Delete: return "⌫"
        case kVK_ForwardDelete: return "⌦"
        case kVK_Home: return "↖"
        case kVK_End: return "↘"
        case kVK_PageUp: return "⇞"
        case kVK_PageDown: return "⇟"
        default:
            guard let characters, !characters.isEmpty else { return nil }
            return characters.uppercased()
        }
    }

    /// Key code → F-key number. A table, not a range: the codes are scattered (F1 is 122,
    /// F20 is 90).
    private static let fKeys: [Int: Int] = {
        let codes = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
                     kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20]
        return Dictionary(uniqueKeysWithValues: codes.enumerated().map { ($1, $0 + 1) })
    }()
}

/// System-wide shortcuts through Carbon's RegisterEventHotKey: works from a menu bar app
/// and needs no permission. Besides the fixed actions, pastebins, filters and single
/// clippings can carry their own shortcut.
@MainActor
final class HotKeyCenter {
    enum Target: Hashable {
        case action(HotKeyAction)
        case pastebin(UUID)
        case filter(UUID)
        case clipping(UUID)
    }

    static let shared = HotKeyCenter()
    var perform: ((Target) -> Void)?
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var targets: [UInt32: Target] = [:]
    private var installed = false

    /// Everything that should be registered right now.
    private func bindings() -> [(Target, HotKey)] {
        var out: [(Target, HotKey)] = []
        for action in HotKeyAction.allCases { if let key = Preferences.shared.hotKey(action) { out.append((.action(action), key)) } }
        let library = ClipStore.shared.library
        for bin in library.pastebins { if let k = bin.hotKey { out.append((.pastebin(bin.id), HotKey(k))) } }
        for filter in library.filters { if let k = filter.hotKey { out.append((.filter(filter.id), HotKey(k))) } }
        for (id, k) in ClipStore.shared.clipHotKeys { out.append((.clipping(id), HotKey(k))) }
        return out
    }

    /// Registers the shortcuts, replacing earlier registrations.
    func apply() {
        installHandlerOnce()
        unregisterAll()
        var next: UInt32 = 1
        for (target, key) in bindings() {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: OSType(0x504C_4E53), id: next) // "PLNS"
            let status = RegisterEventHotKey(key.keyCode, key.modifiers, id, GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref {
                refs[next] = ref
                targets[next] = target
            } else {
                NSLog("PasteLens: shortcut \(key.display) for \(target) not registered (\(status)), probably taken by another app")
            }
            next += 1
        }
    }

    /// Whether a key press is one of PasteLens's own shortcuts.
    func isOwnHotKey(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> Bool {
        bindings().contains { $0.1.matches(keyCode: keyCode, flags: flags) }
    }

    /// Who already uses a shortcut, to warn before assigning it twice.
    func owner(of key: HotKey) -> String? {
        for (target, existing) in bindings() where existing.keyCode == key.keyCode && existing.modifiers == key.modifiers {
            switch target {
            case .action(let a): return a.title
            case .pastebin(let id): return ClipStore.shared.library.pastebins.first { $0.id == id }?.name
            case .filter(let id): return ClipStore.shared.library.filters.first { $0.id == id }?.name
            case .clipping: return "a clipping"
            }
        }
        return nil
    }

    /// While a shortcut is being recorded, the current ones must not fire.
    func unregisterAll() {
        for ref in refs.values { UnregisterEventHotKey(ref) }
        refs.removeAll()
        targets.removeAll()
    }

    func installHandlerOnce() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), hotKeyHandler, 1, &spec, nil, nil)
    }

    fileprivate func fire(_ id: UInt32) {
        guard let target = targets[id] else { return }
        perform?(target)
    }
}

private func hotKeyHandler(_ next: EventHandlerCallRef?, _ event: EventRef?, _ data: UnsafeMutableRawPointer?) -> OSStatus {
    var id = EventHotKeyID()
    let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                   nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
    guard status == noErr else { return status }
    let value = id.id
    let signature = id.signature
    // Carbon delivers hot keys on the main thread's event loop.
    MainActor.assumeIsolated {
        if signature == RecordingCatcher.signature { RecordingCatcher.fire(value) } else { HotKeyCenter.shared.fire(value) }
    }
    return noErr
}

/// While a shortcut is being recorded, every modifier combination is briefly registered as a
/// hot key. macOS hands registered hot keys to the app that owns them, even combinations its
/// own system shortcuts would otherwise swallow before any window sees them (Control-` is one).
@MainActor
enum RecordingCatcher {
    static let signature: OSType = 0x504C_5243 // "PLRC"
    /// Every mix of ⌃ ⌥ ⇧ ⌘ that includes at least one of ⌃ ⌥ ⌘.
    static let modifierSets: [UInt32] = (1..<16).compactMap { bits -> UInt32? in
        var mods: UInt32 = 0
        if bits & 1 != 0 { mods |= UInt32(controlKey) }
        if bits & 2 != 0 { mods |= UInt32(optionKey) }
        if bits & 4 != 0 { mods |= UInt32(shiftKey) }
        if bits & 8 != 0 { mods |= UInt32(cmdKey) }
        return mods == UInt32(shiftKey) ? nil : mods
    }
    /// Modifier and function keys themselves aren't shortcuts.
    static let skipped: Set<Int> = [kVK_Command, kVK_Shift, kVK_CapsLock, kVK_Option, kVK_Control, kVK_RightCommand,
                                    kVK_RightShift, kVK_RightOption, kVK_RightControl, kVK_Function]
    private static var refs: [EventHotKeyRef] = []
    private static var onCatch: ((HotKey) -> Void)?

    static func begin(_ caught: @escaping (HotKey) -> Void) {
        end()
        onCatch = caught
        HotKeyCenter.shared.installHandlerOnce()
        for code in 0..<128 where !skipped.contains(code) {
            for (index, mods) in modifierSets.enumerated() {
                var ref: EventHotKeyRef?
                let id = EventHotKeyID(signature: signature, id: UInt32(code << 4 | index))
                if RegisterEventHotKey(UInt32(code), mods, id, GetApplicationEventTarget(), 0, &ref) == noErr, let ref {
                    refs.append(ref)
                }
            }
        }
    }

    static func end() {
        for ref in refs { UnregisterEventHotKey(ref) }
        refs.removeAll()
        onCatch = nil
    }

    static func fire(_ id: UInt32) {
        let code = id >> 4, index = Int(id & 0xF)
        guard modifierSets.indices.contains(index), let key = HotKey(keyCode: code, carbonModifiers: modifierSets[index]) else { return }
        onCatch?(key)
    }
}

/// Click, then press a shortcut. Esc cancels, Delete clears.
struct ShortcutRecorder: NSViewRepresentable {
    @Binding var hotKey: HotKey?

    func makeNSView(context: Context) -> RecorderButton {
        let view = RecorderButton()
        view.onChange = { hotKey = $0 }
        view.hotKey = hotKey
        return view
    }

    func updateNSView(_ view: RecorderButton, context: Context) {
        view.onChange = { hotKey = $0 }
        view.hotKey = hotKey
    }

    final class RecorderButton: NSButton {
        var onChange: ((HotKey?) -> Void)?
        var hotKey: HotKey? { didSet { refresh() } }
        private var recording = false { didSet { refresh() } }
        private var monitor: Any?

        override init(frame: NSRect) {
            super.init(frame: frame)
            bezelStyle = .rounded
            target = self
            action = #selector(toggle)
            refresh()
        }

        required init?(coder: NSCoder) { fatalError() }

        override var intrinsicContentSize: NSSize { NSSize(width: 140, height: super.intrinsicContentSize.height) }

        private func refresh() {
            title = recording ? "Press a shortcut…" : (hotKey?.display ?? "Click to set")
        }

        @objc private func toggle() {
            recording ? stop() : start()
        }

        private func start() {
            recording = true
            HotKeyCenter.shared.unregisterAll()
            // Combinations with ⌘ ⌥ or ⌃ arrive here, including ones macOS would otherwise keep.
            RecordingCatcher.begin { [weak self] key in
                guard let self, self.recording else { return }
                self.hotKey = key
                self.onChange?(key)
                self.stop()
            }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                switch Int(event.keyCode) {
                case kVK_Escape:
                    self.stop()
                case kVK_Delete, kVK_ForwardDelete:
                    self.hotKey = nil
                    self.onChange?(nil)
                    self.stop()
                default:
                    guard let key = HotKey(event: event) else { NSSound.beep(); return nil }
                    self.hotKey = key
                    self.onChange?(key)
                    self.stop()
                }
                return nil
            }
        }

        private func stop() {
            recording = false
            RecordingCatcher.end()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            // The binding writes Preferences synchronously, so this sees the new key.
            HotKeyCenter.shared.apply()
        }
    }
}
