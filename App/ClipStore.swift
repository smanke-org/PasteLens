import AppKit
import IOKit
import Observation
import PasteLensKit

/// The library on disk and in memory: clipping metadata in library.json, each clipping's
/// bytes in its own file under Content/.
@Observable
@MainActor
final class ClipStore {
    static let shared = ClipStore()

    private(set) var library = Library()
    /// Bumped on every change, so views can cheaply notice one.
    private(set) var revision = 0

    @ObservationIgnored let folder: URL
    @ObservationIgnored private var contentCache: [UUID: ClipContent] = [:]
    @ObservationIgnored private var cacheOrder: [UUID] = []
    @ObservationIgnored private var saveScheduled = false

    var clipHotKeys: [UUID: StoredHotKey] { library.clipHotKeys }

    private init() {
        if let override = ProcessInfo.processInfo.environment["PASTELENS_DATA_FOLDER"] {
            folder = URL(fileURLWithPath: override)
        } else {
            folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("PasteLens", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: contentFolder, withIntermediateDirectories: true)
        load()
    }

    var contentFolder: URL { folder.appendingPathComponent("Content", isDirectory: true) }
    private var libraryFile: URL { folder.appendingPathComponent("library.json") }

    // MARK: Loading and saving

    private func load() {
        if let data = try? Data(contentsOf: libraryFile), let loaded = try? SyncMerge.decode(Library.self, from: data) {
            library = loaded
        }
        if !library.seededDefaults {
            library.filters = DefaultContent.filters()
            library.snippets = DefaultContent.snippets()
            library.pastebins = DefaultContent.pastebins()
            library.smartPastebins = SmartPastebin.defaults
            library.seededDefaults = true
            saveNow()
        } else {
            addNewBuiltInFilters()
        }
    }

    /// Filters added to PasteLens in an update appear for existing users too, unless they deleted them.
    private func addNewBuiltInFilters() {
        let have = Set(library.filters.compactMap(\.builtInKey))
        let deleted = Set(library.tombstones.keys)
        var added = false
        for filter in DefaultContent.filters() where !have.contains(filter.builtInKey!) {
            if deleted.contains("builtin:\(filter.builtInKey!)") { continue }
            library.filters.append(filter)
            added = true
        }
        if added { saveNow() }
    }

    func saveNow() {
        do {
            let data = try SyncMerge.encode(library)
            try data.write(to: libraryFile, options: .atomic)
        } catch {
            NSLog("PasteLens: couldn't save the library: \(error.localizedDescription)")
        }
    }

    /// Records a change: saves soon, tells sync, and refreshes views.
    func changed(syncNow: Bool = true) {
        revision += 1
        if !saveScheduled {
            saveScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                MainActor.assumeIsolated {
                    self?.saveScheduled = false
                    self?.saveNow()
                }
            }
        }
        if syncNow { SyncEngine.shared.libraryChanged() }
    }

    // MARK: Content

    func contentURL(_ id: UUID) -> URL { contentFolder.appendingPathComponent(id.uuidString + ".plist") }

    func content(for id: UUID) -> ClipContent? {
        if let cached = contentCache[id] { return cached }
        guard let data = try? Data(contentsOf: contentURL(id)),
              let content = try? PropertyListDecoder().decode(ClipContent.self, from: data) else { return nil }
        remember(content, for: id)
        return content
    }

    func hasContent(_ id: UUID) -> Bool { contentCache[id] != nil || FileManager.default.fileExists(atPath: contentURL(id).path) }

    func storeContent(_ content: ClipContent, for id: UUID) {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        if let data = try? encoder.encode(content) { try? data.write(to: contentURL(id), options: .atomic) }
        remember(content, for: id)
    }

    private func remember(_ content: ClipContent, for id: UUID) {
        contentCache[id] = content
        cacheOrder.removeAll { $0 == id }
        cacheOrder.append(id)
        if cacheOrder.count > 60 { contentCache[cacheOrder.removeFirst()] = nil }
    }

    func text(of id: UUID) -> String? { content(for: id)?.plainText }

    // MARK: Lookup

    func clip(_ id: UUID) -> Clipping? { library.clippings.first { $0.id == id } }

    private func index(_ id: UUID) -> Int? { library.clippings.firstIndex { $0.id == id } }

    var history: [Clipping] { library.clippings.filter(\.inHistory) }

    func clippings(in scope: Scope, query: String = "") -> [Clipping] {
        var items: [Clipping]
        switch scope {
        case .history: items = library.clippings.filter(\.inHistory)
        case .pinned: items = library.clippings.filter(\.pinned)
        case .pastebin(let id): items = library.clippings.filter { $0.pastebinIDs.contains(id) }
        case .smart(let id):
            guard let smart = library.smartPastebins.first(where: { $0.id == id }) else { return [] }
            let now = Date()
            items = library.clippings.filter { smart.matches($0, now: now) }
        case .all: items = library.clippings
        }
        items.sort { $0.copiedAt > $1.copiedAt }
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return items }
        return items.compactMap { clip -> (Clipping, Double)? in
            guard let score = FuzzySearch.score(trimmed, in: clip.sensitive ? (clip.title ?? "") : clip.searchableText) else { return nil }
            return (clip, score)
        }
        // Better matches first; among equals, the most recent.
        .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.copiedAt > $1.0.copiedAt }
        .map(\.0)
    }

    enum Scope: Hashable {
        case history, pinned, all
        case pastebin(UUID)
        case smart(UUID)

        @MainActor init?(id: String?) {
            guard let id, !id.isEmpty else { self = .history; return }
            switch id.lowercased() {
            case "history", "general", Pastebin.historyID.uuidString.lowercased(): self = .history
            case "pinned", Pastebin.pinnedID.uuidString.lowercased(): self = .pinned
            case "all": self = .all
            default:
                guard let uuid = UUID(uuidString: id) else { return nil }
                if ClipStore.shared.library.smartPastebins.contains(where: { $0.id == uuid }) { self = .smart(uuid) } else { self = .pastebin(uuid) }
            }
        }
    }

    // MARK: Recording

    /// Adds what was just copied, or moves an identical history item back to the top.
    @discardableResult
    func record(_ content: ClipContent, source: (bundleID: String?, name: String?), imageSize: (Int, Int)?,
                sensitive: SensitiveScanner.Finding?) -> Clipping {
        let now = Date()
        let hash = ClipBuilder.hash(content)
        if let i = library.clippings.firstIndex(where: { $0.inHistory && $0.contentHash == hash }) {
            library.clippings[i].copiedAt = now
            library.clippings[i].updatedAt = now
            if let name = source.name { library.clippings[i].sourceName = name; library.clippings[i].sourceBundleID = source.bundleID }
            let clip = library.clippings[i]
            library.clippings.remove(at: i)
            library.clippings.insert(clip, at: 0)
            changed()
            return clip
        }
        var clip = ClipBuilder.make(from: content, source: source, origin: DeviceIdentity.id, imageSize: imageSize, now: now)
        if let sensitive {
            clip.sensitive = true
            clip.title = sensitive.label
            clip.expiresAt = now.addingTimeInterval(Double(max(Preferences.shared.sensitiveMinutes, 1)) * 60)
        }
        storeContent(content, for: clip.id)
        library.clippings.insert(clip, at: 0)
        pruneHistory()
        changed()
        if !clip.sensitive { SyncEngine.shared.contentAdded(clip.id) }
        if clip.kind == .image, Preferences.shared.ocr { recognizeText(in: clip.id) }
        return clip
    }

    /// Adds a clipping that didn't come from the clipboard (text from the CLI, a merge, an import).
    @discardableResult
    func add(_ content: ClipContent, title: String? = nil, source: (bundleID: String?, name: String?) = (nil, nil),
             createdAt: Date = Date(), copiedAt: Date? = nil, inHistory: Bool = true, pastebins: [UUID] = []) -> Clipping {
        var clip = ClipBuilder.make(from: content, source: source, origin: DeviceIdentity.id, imageSize: Self.imageSize(content), now: createdAt)
        clip.copiedAt = copiedAt ?? createdAt
        clip.updatedAt = Date()
        clip.title = title
        clip.inHistory = inHistory
        clip.pastebinIDs = pastebins
        storeContent(content, for: clip.id)
        library.clippings.append(clip)
        library.clippings.sort { $0.copiedAt > $1.copiedAt }
        changed()
        SyncEngine.shared.contentAdded(clip.id)
        if clip.kind == .image, Preferences.shared.ocr { recognizeText(in: clip.id) }
        return clip
    }

    static func imageSize(_ content: ClipContent) -> (Int, Int)? {
        for type in UTI.imageTypes {
            if let data = content.data(for: type), let rep = NSBitmapImageRep(data: data) { return (rep.pixelsWide, rep.pixelsHigh) }
        }
        return nil
    }

    func recognizeText(in id: UUID) {
        guard let content = content(for: id) else { return }
        Task {
            guard let text = await Recognizer.text(in: content), !text.isEmpty else { return }
            self.update(id) { $0.ocrText = text }
        }
    }

    // MARK: Editing

    func update(_ id: UUID, sync: Bool = true, _ change: (inout Clipping) -> Void) {
        guard let i = index(id) else { return }
        change(&library.clippings[i])
        library.clippings[i].updatedAt = Date()
        changed(syncNow: sync)
    }

    /// Moves a clipping to the top of history, as if just copied.
    func touch(_ id: UUID) {
        guard Preferences.shared.moveToTop else { return }
        update(id) {
            $0.copiedAt = Date()
            $0.inHistory = true
        }
        library.clippings.sort { $0.copiedAt > $1.copiedAt }
    }

    func setPinned(_ ids: [UUID], _ pinned: Bool) {
        for id in ids { update(id) { $0.pinned = pinned } }
    }

    func save(_ ids: [UUID], to pastebin: UUID) {
        for id in ids { update(id) { if !$0.pastebinIDs.contains(pastebin) { $0.pastebinIDs.append(pastebin) } } }
        SoundPlayer.play(.save)
    }

    func remove(_ ids: [UUID], from pastebin: UUID) {
        for id in ids {
            update(id) { $0.pastebinIDs.removeAll { $0 == pastebin } }
            if let clip = clip(id), !clip.inHistory, clip.pastebinIDs.isEmpty, !clip.pinned { delete([id]) }
        }
    }

    /// Replaces a clipping's text, as when edited in the preview.
    func replaceText(_ id: UUID, with text: String) {
        let content = ClipContent.text(text)
        storeContent(content, for: id)
        update(id) {
            let fresh = ClipBuilder.make(from: content, source: ($0.sourceBundleID, $0.sourceName), origin: $0.origin)
            $0.kind = fresh.kind
            $0.types = fresh.types
            $0.preferredType = fresh.preferredType
            $0.previewText = fresh.previewText
            $0.textLength = fresh.textLength
            $0.sizeBytes = fresh.sizeBytes
            $0.contentHash = fresh.contentHash
        }
        SyncEngine.shared.contentAdded(id, replace: true)
    }

    func delete(_ ids: [UUID]) {
        guard !ids.isEmpty else { return }
        let set = Set(ids)
        let now = Date()
        library.clippings.removeAll { set.contains($0.id) }
        for id in ids {
            library.tombstones["clipping:\(id.uuidString)"] = now
            library.clipHotKeys[id] = nil
            try? FileManager.default.removeItem(at: contentURL(id))
            contentCache[id] = nil
        }
        StackController.shared.remove(ids)
        changed()
        SyncEngine.shared.contentDeleted(ids)
        SoundPlayer.play(.delete)
    }

    /// Clears history. Pinned clippings and ones saved in a pastebin stay where they are.
    func clearHistory() {
        let drop = library.clippings.filter { $0.inHistory && !$0.isKept }.map(\.id)
        for i in library.clippings.indices where library.clippings[i].inHistory {
            library.clippings[i].inHistory = false
            library.clippings[i].updatedAt = Date()
        }
        delete(drop)
    }

    /// Applies the history limits and deletes expired secrets.
    func pruneHistory() {
        let now = Date()
        let expiredSecrets = library.clippings.filter { $0.sensitive && ($0.expiresAt ?? .distantFuture) < now }.map(\.id)
        var drop = Preferences.shared.retention.expired(in: library.clippings, now: now)
        // A clipping that's also in a pastebin only leaves history.
        let kept = Set(library.clippings.filter { !$0.pastebinIDs.isEmpty }.map(\.id))
        for id in drop where kept.contains(id) {
            if let i = index(id) { library.clippings[i].inHistory = false; library.clippings[i].updatedAt = now }
        }
        drop.removeAll { kept.contains($0) }
        if !expiredSecrets.isEmpty || !drop.isEmpty { delete(Array(Set(drop + expiredSecrets))) }
    }

    /// Joins several clippings' text into a new clipping.
    @discardableResult
    func merge(_ ids: [UUID], separator: String) -> Clipping? {
        let ordered = ids.compactMap(clip).sorted { $0.copiedAt < $1.copiedAt }
        let texts = ordered.compactMap { text(of: $0.id) ?? ($0.previewText.isEmpty ? nil : $0.previewText) }
        guard !texts.isEmpty else { return nil }
        return add(.text(texts.joined(separator: separator)), title: nil, source: (Bundle.main.bundleIdentifier, "PasteLens"))
    }

    func setHotKey(_ key: StoredHotKey?, forClip id: UUID) {
        library.clipHotKeys[id] = key
        changed(syncNow: false)
        HotKeyCenter.shared.apply()
    }

    // MARK: Pastebins, filters, snippets

    func upsertPastebin(_ bin: Pastebin) {
        var bin = bin
        bin.updatedAt = Date()
        if let i = library.pastebins.firstIndex(where: { $0.id == bin.id }) { library.pastebins[i] = bin } else {
            bin.order = (library.pastebins.map(\.order).max() ?? 0) + 1
            library.pastebins.append(bin)
        }
        changed()
        HotKeyCenter.shared.apply()
    }

    func deletePastebin(_ id: UUID) {
        library.pastebins.removeAll { $0.id == id }
        library.tombstones["pastebin:\(id.uuidString)"] = Date()
        let orphans = library.clippings.filter { $0.pastebinIDs.contains(id) }.map(\.id)
        for clip in orphans { remove([clip], from: id) }
        changed()
        HotKeyCenter.shared.apply()
    }

    func upsertSmart(_ bin: SmartPastebin) {
        var bin = bin
        bin.updatedAt = Date()
        if let i = library.smartPastebins.firstIndex(where: { $0.id == bin.id }) { library.smartPastebins[i] = bin } else {
            bin.order = (library.smartPastebins.map(\.order).max() ?? 0) + 1
            library.smartPastebins.append(bin)
        }
        changed()
    }

    func deleteSmart(_ id: UUID) {
        library.smartPastebins.removeAll { $0.id == id }
        library.tombstones["smartPastebin:\(id.uuidString)"] = Date()
        changed()
    }

    func upsertFilter(_ filter: Filter) {
        var filter = filter
        filter.updatedAt = Date()
        if let i = library.filters.firstIndex(where: { $0.id == filter.id }) { library.filters[i] = filter } else { library.filters.append(filter) }
        changed()
        HotKeyCenter.shared.apply()
    }

    func deleteFilter(_ id: UUID) {
        let key = library.filters.first { $0.id == id }?.builtInKey
        library.filters.removeAll { $0.id == id }
        library.tombstones["filter:\(id.uuidString)"] = Date()
        // Remember deleted built-ins so an update doesn't bring them back.
        if let key { library.tombstones["builtin:\(key)"] = Date() }
        changed()
        HotKeyCenter.shared.apply()
    }

    func restoreDefaultFilters() {
        let have = Set(library.filters.compactMap(\.builtInKey))
        for filter in DefaultContent.filters() where !have.contains(filter.builtInKey!) {
            library.tombstones["builtin:\(filter.builtInKey!)"] = nil
            library.filters.append(filter)
        }
        changed()
    }

    func upsertSnippet(_ snippet: Snippet) {
        var snippet = snippet
        snippet.updatedAt = Date()
        if let i = library.snippets.firstIndex(where: { $0.id == snippet.id }) { library.snippets[i] = snippet } else { library.snippets.append(snippet) }
        changed()
        SnippetExpander.shared.refresh()
    }

    func deleteSnippet(_ id: UUID) {
        library.snippets.removeAll { $0.id == id }
        library.tombstones["snippet:\(id.uuidString)"] = Date()
        changed()
        SnippetExpander.shared.refresh()
    }

    func filter(named nameOrID: String) -> Filter? {
        library.filters.first { $0.id.uuidString.caseInsensitiveCompare(nameOrID) == .orderedSame }
            ?? library.filters.first { $0.name.caseInsensitiveCompare(nameOrID) == .orderedSame }
    }

    // MARK: Sync

    /// Replaces the library with a merged one from SyncEngine.
    func applyMerged(_ merged: Library, removed: [UUID]) {
        let previousIDs = Set(library.clippings.map(\.id))
        library = merged
        for id in removed {
            try? FileManager.default.removeItem(at: contentURL(id))
            contentCache[id] = nil
        }
        let added = merged.clippings.filter { !previousIDs.contains($0.id) }
        changed(syncNow: false)
        HotKeyCenter.shared.apply()
        SnippetExpander.shared.refresh()
        if !added.isEmpty { StackController.shared.libraryChanged() }
    }
}

/// A stable, anonymous id for this Mac: a hash of the hardware UUID.
enum DeviceIdentity {
    static let id: String = {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        defer { IOObjectRelease(service) }
        if let uuid = IORegistryEntryCreateCFProperty(service, "IOPlatformUUID" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String {
            return String(SyncCrypto.sha256Hex(Data(("PasteLens" + uuid).utf8)).prefix(16))
        }
        let key = "deviceID"
        if let saved = UserDefaults.standard.string(forKey: key) { return saved }
        let made = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16)).lowercased()
        UserDefaults.standard.set(made, forKey: key)
        return made
    }()

    static var name: String { Host.current().localizedName ?? "Mac" }
}
