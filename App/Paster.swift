import AppKit
import ApplicationServices
import Carbon.HIToolbox
import PasteLensKit

/// Puts clippings on the clipboard and pastes them into the frontmost app.
@MainActor
enum Paster {
    // MARK: Accessibility

    static var trusted: Bool { AXIsProcessTrusted() }

    /// Asks macOS to add PasteLens to the Accessibility list (it shows the system prompt once).
    @discardableResult
    static func requestAccess() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Writing

    /// Writes content to the clipboard. `plain` keeps only the text.
    static func write(_ content: ClipContent, plain: Bool = false) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let marker = NSPasteboard.PasteboardType(UTI.ownMarker)
        let fileURLs = content.representations.filter { $0.type == UTI.fileURL }
        if !plain, fileURLs.count > 1 {
            let items = fileURLs.compactMap { rep -> NSPasteboardItem? in
                let item = NSPasteboardItem()
                item.setData(rep.data, forType: .fileURL)
                item.setData(Data(), forType: marker)
                return item
            }
            pasteboard.writeObjects(items)
        } else {
            let item = NSPasteboardItem()
            if plain, let text = content.plainText ?? fileURLs.first.flatMap({ String(data: $0.data, encoding: .utf8) }) {
                item.setString(text, forType: .string)
            } else {
                for rep in content.representations { item.setData(rep.data, forType: NSPasteboard.PasteboardType(rep.type)) }
            }
            item.setData(Data(), forType: marker)
            pasteboard.writeObjects([item])
        }
        ClipboardMonitor.shared.ownChangeCount = pasteboard.changeCount
    }

    static func write(text: String) { write(.text(text), plain: true) }

    /// Copies a clipping (its content, or `text` when a filter changed it) and moves it to the top.
    static func copy(_ clip: Clipping, text: String? = nil, plain: Bool = false) -> Bool {
        if let text {
            write(text: text)
        } else {
            guard let content = ClipStore.shared.content(for: clip.id) else { NSSound.beep(); return false }
            write(content, plain: plain || Preferences.shared.alwaysPlain)
        }
        ClipStore.shared.touch(clip.id)
        return true
    }

    // MARK: Pasting

    /// Sends ⌘V to the frontmost app, after giving it a moment to regain focus.
    static func pasteClipboard(after delay: TimeInterval = 0.08, cursorFromEnd: Int? = nil) {
        guard trusted else {
            requestAccess()
            SoundPlayer.play(.error)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            postKey(keyCode(for: "v") ?? CGKeyCode(kVK_ANSI_V), flags: .maskCommand)
            SoundPlayer.play(.paste)
            MainActor.assumeIsolated { ActivityStore.shared.record(.paste) }
            if let back = cursorFromEnd, back > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                    for _ in 0..<min(back, 2_000) { postKey(CGKeyCode(kVK_LeftArrow), flags: []) }
                }
            }
        }
    }

    /// Copies and pastes a clipping into the app that was in front.
    static func paste(_ clip: Clipping, text: String? = nil, plain: Bool = false) {
        guard copy(clip, text: text, plain: plain) else { return }
        pasteClipboard()
    }

    static func paste(text: String, cursorFromEnd: Int? = nil) {
        write(text: text)
        pasteClipboard(cursorFromEnd: cursorFromEnd)
    }

    /// Types text as keystrokes, for fields that block pasting.
    static func typeOut(_ text: String) {
        guard trusted else { requestAccess(); return }
        // Line breaks go as Return presses; everything else in runs of up to 16 characters.
        var chunks: [String] = []
        for (index, line) in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n").enumerated() {
            if index > 0 { chunks.append("\n") }
            chunks += Array(line).chunked(16).map { String($0) }
        }
        ActivityStore.shared.record(.paste)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            for chunk in chunks {
                if chunk == "\n" {
                    postKey(CGKeyCode(kVK_Return), flags: [])
                } else {
                    let utf16 = Array(chunk.utf16)
                    for down in [true, false] {
                        let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down)
                        event?.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
                        event?.post(tap: .cghidEventTap)
                    }
                }
                try? await Task.sleep(for: .milliseconds(12))
            }
        }
    }

    /// Sends ⌘C to the frontmost app (for "copy to stack").
    static func copySelection() {
        guard trusted else { requestAccess(); return }
        postKey(keyCode(for: "c") ?? CGKeyCode(kVK_ANSI_C), flags: .maskCommand)
    }

    static func postKey(_ code: CGKeyCode, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .combinedSessionState)
        // Keys the user is still holding (the shortcut that got us here) would otherwise mix in.
        source?.setLocalEventsFilterDuringSuppressionState([.permitLocalMouseEvents, .permitSystemDefinedEvents],
                                                          state: .eventSuppressionStateSuppressionInterval)
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)
            event?.flags = flags
            event?.post(tap: .cghidEventTap)
        }
    }

    /// The key that types `character` on the current keyboard layout (V isn't where QWERTY has it on Dvorak).
    static func keyCode(for character: Character) -> CGKeyCode? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        return data.withUnsafeBytes { buffer -> CGKeyCode? in
            guard let layout = buffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            for code in 0..<128 {
                var dead: UInt32 = 0
                var length = 0
                var chars = [UniChar](repeating: 0, count: 4)
                let status = UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                            OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, 4, &length, &chars)
                if status == noErr, length == 1, Character(UnicodeScalar(chars[0])!) == character { return CGKeyCode(code) }
            }
            return nil
        }
    }
}

extension Array {
    func chunked(_ size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
