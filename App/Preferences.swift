import AppKit
import Carbon.HIToolbox
import Observation
import PasteLensKit

/// Every setting, backed by UserDefaults. Settings in `syncedKeys` follow you to your other
/// Macs (encrypted, like everything else PasteLens syncs).
@Observable
@MainActor
final class Preferences {
    static let shared = Preferences()
    private let defaults = AppDefaults.store
    /// While true, changes come from another Mac and aren't stamped as local edits.
    @ObservationIgnored var applyingRemote = false

    enum Key {
        static let maxClippings = "history.maxClippings"
        static let maxDays = "history.maxDays"
        static let unlimited = "history.unlimited"
        static let maxClipMB = "history.maxClipMB"
        static let ignoredApps = "history.ignoredApps"
        static let captureImages = "history.captureImages"
        static let captureFiles = "history.captureFiles"
        static let paused = "capture.paused"
        static let alwaysPlain = "paste.alwaysPlain"
        static let releaseToPaste = "paste.releaseToPaste"
        static let moveToTop = "paste.moveToTop"
        static let windowPaste = "historyWindow.pasteWith"
        static let menuRecents = "menu.showRecent"
        static let rowLines = "quickPaste.rowLines"
        static let quickPasteAtMouse = "quickPaste.atMouse"
        static let quickPasteCount = "quickPaste.visibleRows"
        static let sounds = "sounds.enabled"
        static let detectSensitive = "privacy.detectSensitive"
        static let sensitiveMinutes = "privacy.sensitiveMinutes"
        static let ocr = "ocr.enabled"
        static let linkPreviews = "links.previews"
        static let expansion = "snippets.expansion"
        static let syncContents = "sync.contents"
        static let syncMaxClipMB = "sync.maxClipMB"
        static let hotKeyPrefix = "hotkey."
    }

    /// Settings that sync between Macs. Sync's own switches, pausing and the Dock and menu
    /// bar choices stay per Mac.
    static let syncedKeys: [String] = [
        Key.maxClippings, Key.maxDays, Key.unlimited, Key.maxClipMB, Key.ignoredApps, Key.captureImages, Key.captureFiles,
        Key.alwaysPlain, Key.releaseToPaste, Key.moveToTop, Key.windowPaste, Key.menuRecents, Key.rowLines, Key.quickPasteAtMouse, Key.quickPasteCount,
        Key.sounds, Key.detectSensitive, Key.sensitiveMinutes, Key.ocr, Key.linkPreviews, Key.expansion,
        Key.syncMaxClipMB, "updatePolicy",
    ] + HotKeyAction.allCases.map { Key.hotKeyPrefix + $0.rawValue }

    // MARK: History

    var maxClippings: Int { didSet { save(Key.maxClippings, maxClippings) } }
    var maxDays: Int { didSet { save(Key.maxDays, maxDays) } }
    /// Keep every clipping, ignoring both limits. The numbers are kept for when it's turned off.
    var unlimited: Bool { didSet { save(Key.unlimited, unlimited) } }
    var maxClipMB: Double { didSet { save(Key.maxClipMB, maxClipMB) } }
    var ignoredApps: [String] { didSet { save(Key.ignoredApps, ignoredApps) } }
    var captureImages: Bool { didSet { save(Key.captureImages, captureImages) } }
    var captureFiles: Bool { didSet { save(Key.captureFiles, captureFiles) } }
    var paused: Bool { didSet { defaults.set(paused, forKey: Key.paused) } }

    // MARK: Pasting

    var alwaysPlain: Bool { didSet { save(Key.alwaysPlain, alwaysPlain) } }
    var releaseToPaste: Bool { didSet { save(Key.releaseToPaste, releaseToPaste) } }
    var moveToTop: Bool { didSet { save(Key.moveToTop, moveToTop) } }
    /// How a clipping is pasted from the history window: double-click, the right-click menu, or both.
    var windowPaste: WindowPaste { didSet { save(Key.windowPaste, windowPaste.rawValue) } }
    /// Whether the menu bar menu lists the most recent clippings.
    var menuRecents: Bool { didSet { save(Key.menuRecents, menuRecents) } }
    var rowLines: Int { didSet { save(Key.rowLines, rowLines) } }
    var quickPasteAtMouse: Bool { didSet { save(Key.quickPasteAtMouse, quickPasteAtMouse) } }
    var quickPasteCount: Int { didSet { save(Key.quickPasteCount, quickPasteCount) } }
    var sounds: Bool { didSet { save(Key.sounds, sounds) } }

    // MARK: Privacy and smarts

    var detectSensitive: Bool { didSet { save(Key.detectSensitive, detectSensitive) } }
    var sensitiveMinutes: Int { didSet { save(Key.sensitiveMinutes, sensitiveMinutes) } }
    var ocr: Bool { didSet { save(Key.ocr, ocr) } }
    var linkPreviews: Bool { didSet { save(Key.linkPreviews, linkPreviews) } }
    var expansion: Bool { didSet { save(Key.expansion, expansion) } }

    // MARK: Sync

    var syncContents: Bool { didSet { defaults.set(syncContents, forKey: Key.syncContents) } }
    var syncMaxClipMB: Double { didSet { save(Key.syncMaxClipMB, syncMaxClipMB) } }

    // MARK: Shortcuts

    var hotKeys: [HotKeyAction: HotKey] = [:]

    func hotKey(_ action: HotKeyAction) -> HotKey? { hotKeys[action] }

    func setHotKey(_ key: HotKey?, for action: HotKeyAction) {
        hotKeys[action] = key
        let k = Key.hotKeyPrefix + action.rawValue
        if let key, let data = try? JSONEncoder().encode(key) { defaults.set(data, forKey: k) } else { defaults.set(Data(), forKey: k) }
        stamp(k)
    }

    private init() {
        defaults.register(defaults: [
            Key.maxClippings: 1_000, Key.maxDays: 0, Key.unlimited: false, Key.maxClipMB: 50.0, Key.ignoredApps: [String](),
            Key.captureImages: true, Key.captureFiles: true, Key.alwaysPlain: false, Key.releaseToPaste: false,
            Key.moveToTop: true, Key.windowPaste: WindowPaste.both.rawValue, Key.menuRecents: true, Key.rowLines: 1, Key.quickPasteAtMouse: true, Key.quickPasteCount: 9, Key.sounds: true,
            Key.detectSensitive: true, Key.sensitiveMinutes: 2, Key.ocr: true, Key.linkPreviews: true, Key.expansion: false,
            Key.syncContents: true, Key.syncMaxClipMB: 25.0,
        ])
        maxClippings = defaults.integer(forKey: Key.maxClippings)
        maxDays = defaults.integer(forKey: Key.maxDays)
        unlimited = defaults.bool(forKey: Key.unlimited)
        maxClipMB = defaults.double(forKey: Key.maxClipMB)
        ignoredApps = defaults.stringArray(forKey: Key.ignoredApps) ?? []
        captureImages = defaults.bool(forKey: Key.captureImages)
        captureFiles = defaults.bool(forKey: Key.captureFiles)
        paused = defaults.bool(forKey: Key.paused)
        alwaysPlain = defaults.bool(forKey: Key.alwaysPlain)
        releaseToPaste = defaults.bool(forKey: Key.releaseToPaste)
        moveToTop = defaults.bool(forKey: Key.moveToTop)
        windowPaste = WindowPaste(rawValue: defaults.string(forKey: Key.windowPaste) ?? "") ?? .both
        menuRecents = defaults.bool(forKey: Key.menuRecents)
        rowLines = defaults.integer(forKey: Key.rowLines)
        quickPasteAtMouse = defaults.bool(forKey: Key.quickPasteAtMouse)
        quickPasteCount = defaults.integer(forKey: Key.quickPasteCount)
        sounds = defaults.bool(forKey: Key.sounds)
        detectSensitive = defaults.bool(forKey: Key.detectSensitive)
        sensitiveMinutes = defaults.integer(forKey: Key.sensitiveMinutes)
        ocr = defaults.bool(forKey: Key.ocr)
        linkPreviews = defaults.bool(forKey: Key.linkPreviews)
        expansion = defaults.bool(forKey: Key.expansion)
        syncContents = defaults.bool(forKey: Key.syncContents)
        syncMaxClipMB = defaults.double(forKey: Key.syncMaxClipMB)
        loadHotKeys()
    }

    private func loadHotKeys() {
        var keys: [HotKeyAction: HotKey] = [:]
        for action in HotKeyAction.allCases {
            if let data = defaults.data(forKey: Key.hotKeyPrefix + action.rawValue) {
                // An empty value means "cleared on purpose", not "use the default".
                if !data.isEmpty, let key = try? JSONDecoder().decode(HotKey.self, from: data) { keys[action] = key }
            } else if let fallback = action.defaultKey {
                keys[action] = fallback
            }
        }
        hotKeys = keys
    }

    var retention: RetentionPolicy {
        unlimited ? RetentionPolicy(maxClippings: 0, maxDays: 0) : RetentionPolicy(maxClippings: maxClippings, maxDays: maxDays)
    }

    private func save(_ key: String, _ value: Any) {
        defaults.set(value, forKey: key)
        stamp(key)
    }

    private func stamp(_ key: String) {
        guard !applyingRemote else { return }
        SyncEngine.shared.settingChanged(key)
    }

    /// Re-reads everything after values arrived from another Mac.
    func reloadFromDefaults() {
        applyingRemote = true
        defer { applyingRemote = false }
        let fresh = Preferences.Snapshot(defaults)
        if maxClippings != fresh.maxClippings { maxClippings = fresh.maxClippings }
        if maxDays != fresh.maxDays { maxDays = fresh.maxDays }
        if unlimited != fresh.unlimited { unlimited = fresh.unlimited }
        if maxClipMB != fresh.maxClipMB { maxClipMB = fresh.maxClipMB }
        if ignoredApps != fresh.ignoredApps { ignoredApps = fresh.ignoredApps }
        if captureImages != fresh.captureImages { captureImages = fresh.captureImages }
        if captureFiles != fresh.captureFiles { captureFiles = fresh.captureFiles }
        if alwaysPlain != fresh.alwaysPlain { alwaysPlain = fresh.alwaysPlain }
        if releaseToPaste != fresh.releaseToPaste { releaseToPaste = fresh.releaseToPaste }
        if moveToTop != fresh.moveToTop { moveToTop = fresh.moveToTop }
        let freshPaste = WindowPaste(rawValue: defaults.string(forKey: Key.windowPaste) ?? "") ?? .both
        if windowPaste != freshPaste { windowPaste = freshPaste }
        if menuRecents != defaults.bool(forKey: Key.menuRecents) { menuRecents = defaults.bool(forKey: Key.menuRecents) }
        if rowLines != fresh.rowLines { rowLines = fresh.rowLines }
        if quickPasteAtMouse != fresh.quickPasteAtMouse { quickPasteAtMouse = fresh.quickPasteAtMouse }
        if quickPasteCount != fresh.quickPasteCount { quickPasteCount = fresh.quickPasteCount }
        if sounds != fresh.sounds { sounds = fresh.sounds }
        if detectSensitive != fresh.detectSensitive { detectSensitive = fresh.detectSensitive }
        if sensitiveMinutes != fresh.sensitiveMinutes { sensitiveMinutes = fresh.sensitiveMinutes }
        if ocr != fresh.ocr { ocr = fresh.ocr }
        if linkPreviews != fresh.linkPreviews { linkPreviews = fresh.linkPreviews }
        if expansion != fresh.expansion { expansion = fresh.expansion }
        if syncMaxClipMB != fresh.syncMaxClipMB { syncMaxClipMB = fresh.syncMaxClipMB }
        loadHotKeys()
        HotKeyCenter.shared.apply()
        SnippetExpander.shared.refresh()
    }

    private struct Snapshot {
        let maxClippings, maxDays, rowLines, quickPasteCount, sensitiveMinutes: Int
        let maxClipMB, syncMaxClipMB: Double
        let ignoredApps: [String]
        let unlimited, captureImages, captureFiles, alwaysPlain, releaseToPaste, moveToTop, quickPasteAtMouse, sounds,
            detectSensitive, ocr, linkPreviews, expansion: Bool
        init(_ d: UserDefaults) {
            maxClippings = d.integer(forKey: Key.maxClippings); maxDays = d.integer(forKey: Key.maxDays)
            unlimited = d.bool(forKey: Key.unlimited)
            rowLines = d.integer(forKey: Key.rowLines); quickPasteCount = d.integer(forKey: Key.quickPasteCount)
            sensitiveMinutes = d.integer(forKey: Key.sensitiveMinutes); maxClipMB = d.double(forKey: Key.maxClipMB)
            syncMaxClipMB = d.double(forKey: Key.syncMaxClipMB); ignoredApps = d.stringArray(forKey: Key.ignoredApps) ?? []
            captureImages = d.bool(forKey: Key.captureImages); captureFiles = d.bool(forKey: Key.captureFiles)
            alwaysPlain = d.bool(forKey: Key.alwaysPlain); releaseToPaste = d.bool(forKey: Key.releaseToPaste)
            moveToTop = d.bool(forKey: Key.moveToTop); quickPasteAtMouse = d.bool(forKey: Key.quickPasteAtMouse)
            sounds = d.bool(forKey: Key.sounds); detectSensitive = d.bool(forKey: Key.detectSensitive)
            ocr = d.bool(forKey: Key.ocr); linkPreviews = d.bool(forKey: Key.linkPreviews); expansion = d.bool(forKey: Key.expansion)
        }
    }

    func resetToDefaults() {
        for key in Self.syncedKeys { defaults.removeObject(forKey: key) }
        reloadFromDefaults()
        for key in Self.syncedKeys { stamp(key) }
    }
}

/// How the history window pastes a clipping into the app that was in front.
enum WindowPaste: String, CaseIterable, Identifiable {
    case doubleClick, rightClick, both
    var id: String { rawValue }
    var title: String {
        switch self {
        case .doubleClick: "Double-click"
        case .rightClick: "Right-click menu"
        case .both: "Double-click and right-click menu"
        }
    }
    var onDoubleClick: Bool { self != .rightClick }
    var inMenu: Bool { self != .doubleClick }
}

/// The global shortcuts PasteLens offers.
enum HotKeyAction: String, CaseIterable, Identifiable {
    case quickPaste, mainWindow, pastePlain, pasteFromStack, showStack, addToStack, togglePause, snippets

    var id: String { rawValue }

    var title: String {
        switch self {
        case .quickPaste: "Quick Paste"
        case .mainWindow: "Open PasteLens"
        case .pastePlain: "Paste as Plain Text"
        case .pasteFromStack: "Paste Next from Stack"
        case .showStack: "Show Stack"
        case .addToStack: "Copy to Stack"
        case .togglePause: "Pause or Resume Recording"
        case .snippets: "Snippets"
        }
    }

    var detail: String {
        switch self {
        case .quickPaste: "Search and paste anything you've copied."
        case .mainWindow: "Browse and organize your clippings."
        case .pastePlain: "Paste the clipboard without formatting."
        case .pasteFromStack: "Paste the next stack item, then move on."
        case .showStack: "Show or hide the stack window."
        case .addToStack: "Copy the selection and add it to the stack."
        case .togglePause: "Stop or start recording what you copy."
        case .snippets: "Quick Paste, opened on your snippets."
        }
    }

    var defaultKey: HotKey? {
        switch self {
        case .quickPaste: HotKey(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(cmdKey | shiftKey), display: "⇧⌘V")
        case .pastePlain: HotKey(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(cmdKey | shiftKey | optionKey), display: "⌥⇧⌘V")
        case .pasteFromStack: HotKey(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(cmdKey | shiftKey | controlKey), display: "⌃⇧⌘V")
        case .addToStack: HotKey(keyCode: UInt32(kVK_ANSI_C), modifiers: UInt32(cmdKey | shiftKey | controlKey), display: "⌃⇧⌘C")
        default: nil
        }
    }
}
