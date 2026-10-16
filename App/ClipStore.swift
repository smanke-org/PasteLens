import AppKit
import IOKit
import Observation
import PasteLensKit

/// The library: clipping metadata in an SQLite database (PasteLens.sqlite), each clipping's
/// bytes in its own file under Content/, and the small things (pastebins, smart pastebins,
/// filters, snippets) kept in memory and saved in the database's key-value table.
@Observable
@MainActor
final class ClipStore {
    static let shared = ClipStore()

    /// Pastebins, smart pastebins, filters, snippets and per-Mac shortcuts. Clippings are
    /// not kept here any more; they're read from the database a page at a time.
    private(set) var library = Library()
    /// Bumped on every change, so views know to read again.
    private(set) var revision = 0

    @ObservationIgnored let folder: URL
    @ObservationIgnored private(set) var db: ClipDatabase!
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
        do {
            db = try ClipDatabase(url: folder.appendingPathComponent("PasteLens.sqlite"))
        } catch {
            // Without its database PasteLens can't keep anything; say so rather than lose data.
            let alert = NSAlert()
            alert.messageText = "PasteLens Can't Open Its Library"
            alert.informativeText = "\(error.localizedDescription)\n\nNothing has been changed. The library is in \(folder.path)."
            alert.runModal()
            exit(1)
        }
        load()
    }

    var contentFolder: URL { folder.appendingPathComponent("Content", isDirectory: true) }
    private var legacyLibraryFile: URL { folder.appendingPathComponent("library.json") }
    private static let libraryKey = "library"

    // MARK: Loading and saving

    private func load() {
        if let data = db.data(forKey: Self.libraryKey) {
            if let loaded = try? SyncMerge.decode(Library.self, from: data) { library = loaded }
        } else if FileManager.default.fileExists(atPath: legacyLibraryFile.path) {
            importLegacyLibrary()
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

    /// 1.0.x kept everything in library.json. Moves it into the database once, and keeps the
    /// old file (renamed) in case it's ever needed.
    private func importLegacyLibrary() {
        do {
            let data = try Data(contentsOf: legacyLibraryFile)
            var old = try SyncMerge.decode(Library.self, from: data)
            // Before 1.0.6, a clipping saved in a pastebin also stayed in History.
            for i in old.clippings.indices where !old.clippings[i].pastebinIDs.isEmpty { old.clippings[i].inHistory = false }
            try db.upsert(old.clippings)
            try db.transaction {
                for (key, date) in old.tombstones { try db.setTombstone(key, at: date) }
            }
            let clippings = old.clippings
            old.clippings = []
            old.tombstones = [:]
            library = old
            saveNow()
            let done = folder.appendingPathComponent("library-before-database.json")
            try? FileManager.default.removeItem(at: done)
            try FileManager.default.moveItem(at: legacyLibraryFile, to: done)
            NSLog("PasteLens: moved \(clippings.count) clippings from library.json into the database")
        } catch {
            let aside = folder.appendingPathComponent("library-unreadable-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.copyItem(at: legacyLibraryFile, to: aside)
            NSLog("PasteLens: couldn't read library.json (\(error)); kept a copy at \(aside.path)")
        }
    }

    /// Filters added to PasteLens in an update appear for existing users too, unless they deleted them.
    private func addNewBuiltInFilters() {
        let have = Set(library.filters.compactMap(\.builtInKey))
        var added = false
        for filter in DefaultContent.filters() where !have.contains(filter.builtInKey!) {
            if db.tombstone("builtin:\(filter.builtInKey!)") != nil { continue }
            library.filters.append(filter)
            added = true
        }
        if added { saveNow() }
    }

    func saveNow() {
        do {
            var meta = library
            meta.clippings = []
            meta.tombstones = [:]
            try db.set(SyncMerge.encode(meta), forKey: Self.libraryKey)
        } catch {
            NSLog("PasteLens: couldn't save the library: \(error.localizedDescription)")
        }
    }

    /// Records a change to pastebins, filters or snippets: saves soon and refreshes views.
    private func metaChanged() {
        revision += 1
        guard !saveScheduled else { return }
        saveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            MainActor.assumeIsolated {
                self?.saveScheduled = false
                self?.saveNow()
            }
        }
    }

    /// Refreshes views after clippings changed in the database.
    func clippingsChanged() { revision += 1 }

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

    func clip(_ id: UUID) -> Clipping? { db.clip(id) }

    /// The most recent History clippings.
    func recent(_ limit: Int) -> [Clipping] { db.page(.history, limit: limit) }

    func count(_ scope: Scope) -> Int? {
        switch scope {
        case .history: db.count(.history)
        case .pinned: db.count(.pinned)
        case .all: db.totalCount
        case .pastebin(let id): db.count(.pastebin(id))
        case .smart: nil
        }
    }

    /// A page of clippings in a scope, newest first, or best match first when searching.
    func clippings(in scope: Scope, query: String = "", limit: Int = 200, offset: Int = 0) -> [Clipping] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        let filter: ClipDatabase.Filter
        switch scope {
        case .history: filter = .history
        case .pinned: filter = .pinned
        case .all: filter = .all
        case .pastebin(let id): filter = .pastebin(id)
        case .smart(let id):
            // Smart pastebin rules run in Swift, over clippings read newest first in batches.
            guard let smart = library.smartPastebins.first(where: { $0.id == id }) else { return [] }
            let now = Date()
            var matches: [Clipping] = []
            let want = trimmed.isEmpty ? offset + limit : 2_000
            db.forEach(.all) { clip in
                if smart.matches(clip, now: now) { matches.append(clip) }
                return matches.count < want
            }
            guard !trimmed.isEmpty else { return Array(matches.dropFirst(offset).prefix(limit)) }
            return matches.compactMap { clip -> (Clipping, Double)? in
                FuzzySearch.score(trimmed, in: clip.sensitive ? (clip.title ?? "") : clip.searchableText).map { (clip, $0) }
            }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.copiedAt > $1.0.copiedAt }
            .dropFirst(offset).prefix(limit).map(\.0)
        }
        if trimmed.isEmpty { return db.page(filter, limit: limit, offset: offset) }
        return Array(db.search(trimmed, in: filter, limit: offset + limit).dropFirst(offset))
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

    // MARK: Writing clippings

    /// Saves clippings and queues them for sync.
    private func write(_ clips: [Clipping], sync: Bool = true) {
        do { try db.upsert(clips) } catch { NSLog("PasteLens: couldn't save clippings: \(error.localizedDescription)") }
        if sync { for clip in clips { SyncEngine.shared.mark(.clipping, clip.id.uuidString) } }
        clippingsChanged()
    }

    /// Adds what was just copied, or moves an identical History item back to the top.
    @discardableResult
    func record(_ content: ClipContent, source: (bundleID: String?, name: String?), imageSize: (Int, Int)?,
                sensitive: SensitiveScanner.Finding?) -> Clipping {
        let now = Date()
        ActivityStore.shared.record(.copy, at: now)
        let hash = ClipBuilder.hash(content)
        if var existing = db.historyClip(withHash: hash) {
            existing.copiedAt = now
            existing.updatedAt = now
            if let name = source.name { existing.sourceName = name; existing.sourceBundleID = source.bundleID }
            write([existing], sync: !existing.sensitive)
            return existing
        }
        var clip = ClipBuilder.make(from: content, source: source, origin: DeviceIdentity.id, imageSize: imageSize, now: now)
        if let sensitive {
            clip.sensitive = true
            clip.title = sensitive.label
            clip.expiresAt = now.addingTimeInterval(Double(max(Preferences.shared.sensitiveMinutes, 1)) * 60)
        }
        storeContent(content, for: clip.id)
        write([clip], sync: !clip.sensitive)
        pruneHistory()
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
        write([clip])
        if clip.kind == .image, Preferences.shared.ocr { recognizeText(in: clip.id) }
        return clip
    }

    /// Adds many at once, in one transaction (imports).
    func addMany(_ items: [(ClipContent, Clipping)]) {
        for (content, clip) in items { storeContent(content, for: clip.id) }
        write(items.map(\.1))
    }

    #if DEBUG
    /// Writes test clippings without touching sync or the content cache.
    func addQuietly(_ items: [(ClipContent, Clipping)]) {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        for (content, clip) in items {
            if let data = try? encoder.encode(content) { try? data.write(to: contentURL(clip.id)) }
        }
        try? db.upsert(items.map(\.1))
        clippingsChanged()
    }
    #endif

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

    func update(_ id: UUID, sync: Bool = true, _ change: (inout Clipping) -> Void) {
        guard var clip = db.clip(id) else { return }
        change(&clip)
        clip.updatedAt = Date()
        write([clip], sync: sync && !clip.sensitive)
    }

    /// Moves a clipping to the top of its list, as if just copied. One kept in a pastebin
    /// stays there rather than coming back into History.
    func touch(_ id: UUID) {
        guard Preferences.shared.moveToTop else { return }
        update(id) {
            $0.copiedAt = Date()
            if $0.pastebinIDs.isEmpty { $0.inHistory = true }
        }
    }

    func setPinned(_ ids: [UUID], _ pinned: Bool) {
        for id in ids { update(id) { $0.pinned = pinned } }
    }

    /// Moves clippings into a pastebin. They leave History (and the pastebin they were
    /// moved from), so each clipping lives in one place and clearing History never touches it.
    func move(_ ids: [UUID], to pastebin: UUID, from scope: Scope? = nil) {
        for id in ids {
            update(id) {
                if case .pastebin(let source) = scope, source != pastebin { $0.pastebinIDs.removeAll { $0 == source } }
                if !$0.pastebinIDs.contains(pastebin) { $0.pastebinIDs.append(pastebin) }
                $0.inHistory = false
            }
        }
        SoundPlayer.play(.save)
    }

    /// Takes clippings out of a pastebin. One that isn't anywhere else goes back to History
    /// rather than disappearing.
    func remove(_ ids: [UUID], from pastebin: UUID) {
        for id in ids {
            update(id) {
                $0.pastebinIDs.removeAll { $0 == pastebin }
                if $0.pastebinIDs.isEmpty { $0.inHistory = true; $0.copiedAt = Date() }
            }
        }
        pruneHistory()
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
    }

    func delete(_ ids: [UUID], sound: Bool = true) {
        guard !ids.isEmpty else { return }
        let now = Date()
        let secrets = Set(db.clips(ids).filter(\.sensitive).map(\.id))
        try? db.delete(ids)
        try? db.transaction {
            for id in ids where !secrets.contains(id) { try db.setTombstone("clipping:\(id.uuidString)", at: now) }
        }
        var hotKeysChanged = false
        for id in ids {
            try? FileManager.default.removeItem(at: contentURL(id))
            contentCache[id] = nil
            if library.clipHotKeys.removeValue(forKey: id) != nil { hotKeysChanged = true }
            // Secrets never left this Mac, so there's nothing to tell the others.
            if !secrets.contains(id) { SyncEngine.shared.mark(.clipping, id.uuidString) }
        }
        if hotKeysChanged { metaChanged() }
        StackController.shared.remove(ids)
        clippingsChanged()
        if sound { SoundPlayer.play(.delete) }
    }

    /// Clears History. Pinned clippings stay (pinned), and clippings in pastebins aren't in History.
    func clearHistory() {
        var drop: [UUID] = []
        var unpinFromHistory: [Clipping] = []
        for clip in db.page(.history, limit: Int.max) {
            if clip.isKept {
                var c = clip
                c.inHistory = false
                c.updatedAt = Date()
                unpinFromHistory.append(c)
            } else {
                drop.append(clip.id)
            }
        }
        if !unpinFromHistory.isEmpty { write(unpinFromHistory) }
        delete(drop)
    }

    /// Applies the history limits and deletes expired secrets.
    func pruneHistory() {
        let retention = Preferences.shared.retention
        let drop = db.expired(keeping: retention.maxClippings, maxDays: retention.maxDays) + db.expiredSecrets()
        if !drop.isEmpty { delete(Array(Set(drop)), sound: false) }
    }

    /// Joins several clippings' text into a new clipping.
    @discardableResult
    func merge(_ ids: [UUID], separator: String) -> Clipping? {
        let ordered = db.clips(ids).sorted { $0.copiedAt < $1.copiedAt }
        let texts = ordered.compactMap { text(of: $0.id) ?? ($0.previewText.isEmpty ? nil : $0.previewText) }
        guard !texts.isEmpty else { return nil }
        return add(.text(texts.joined(separator: separator)), title: nil, source: (Bundle.main.bundleIdentifier, "PasteLens"))
    }

    func setHotKey(_ key: StoredHotKey?, forClip id: UUID) {
        library.clipHotKeys[id] = key
        metaChanged()
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
        metaChanged()
        SyncEngine.shared.mark(.pastebin, bin.id.uuidString)
        HotKeyCenter.shared.apply()
    }

    func deletePastebin(_ id: UUID) {
        library.pastebins.removeAll { $0.id == id }
        try? db.setTombstone("pastebin:\(id.uuidString)", at: Date())
        remove(db.ids(.pastebin(id)), from: id)
        metaChanged()
        SyncEngine.shared.mark(.pastebin, id.uuidString)
        HotKeyCenter.shared.apply()
    }

    func upsertSmart(_ bin: SmartPastebin) {
        var bin = bin
        bin.updatedAt = Date()
        if let i = library.smartPastebins.firstIndex(where: { $0.id == bin.id }) { library.smartPastebins[i] = bin } else {
            bin.order = (library.smartPastebins.map(\.order).max() ?? 0) + 1
            library.smartPastebins.append(bin)
        }
        metaChanged()
        SyncEngine.shared.mark(.smartPastebin, bin.id.uuidString)
    }

    func deleteSmart(_ id: UUID) {
        library.smartPastebins.removeAll { $0.id == id }
        try? db.setTombstone("smartPastebin:\(id.uuidString)", at: Date())
        metaChanged()
        SyncEngine.shared.mark(.smartPastebin, id.uuidString)
    }

    func upsertFilter(_ filter: Filter) {
        var filter = filter
        filter.updatedAt = Date()
        if let i = library.filters.firstIndex(where: { $0.id == filter.id }) { library.filters[i] = filter } else { library.filters.append(filter) }
        metaChanged()
        SyncEngine.shared.mark(.filter, filter.id.uuidString)
        HotKeyCenter.shared.apply()
    }

    func deleteFilter(_ id: UUID) {
        let key = library.filters.first { $0.id == id }?.builtInKey
        library.filters.removeAll { $0.id == id }
        try? db.setTombstone("filter:\(id.uuidString)", at: Date())
        // Remember deleted built-ins so an update doesn't bring them back.
        if let key { try? db.setTombstone("builtin:\(key)", at: Date()) }
        metaChanged()
        SyncEngine.shared.mark(.filter, id.uuidString)
        HotKeyCenter.shared.apply()
    }

    func restoreDefaultFilters() {
        let have = Set(library.filters.compactMap(\.builtInKey))
        for filter in DefaultContent.filters() where !have.contains(filter.builtInKey!) {
            try? db.setTombstone("builtin:\(filter.builtInKey!)", at: nil)
            try? db.setTombstone("filter:\(filter.id.uuidString)", at: nil)
            var restored = filter
            restored.updatedAt = Date()
            library.filters.append(restored)
            SyncEngine.shared.mark(.filter, restored.id.uuidString)
        }
        metaChanged()
    }

    func upsertSnippet(_ snippet: Snippet) {
        var snippet = snippet
        snippet.updatedAt = Date()
        if let i = library.snippets.firstIndex(where: { $0.id == snippet.id }) { library.snippets[i] = snippet } else { library.snippets.append(snippet) }
        metaChanged()
        SyncEngine.shared.mark(.snippet, snippet.id.uuidString)
        SnippetExpander.shared.refresh()
    }

    func deleteSnippet(_ id: UUID) {
        library.snippets.removeAll { $0.id == id }
        try? db.setTombstone("snippet:\(id.uuidString)", at: Date())
        metaChanged()
        SyncEngine.shared.mark(.snippet, id.uuidString)
        SnippetExpander.shared.refresh()
    }

    func filter(named nameOrID: String) -> Filter? {
        library.filters.first { $0.id.uuidString.caseInsensitiveCompare(nameOrID) == .orderedSame }
            ?? library.filters.first { $0.name.caseInsensitiveCompare(nameOrID) == .orderedSame }
    }

    // MARK: Sync

    /// The local version of a record, as sync sees it: its payload (nil when deleted or
    /// missing) and when it last changed (a tombstone's date for deletions).
    func localRecord(_ kind: SyncRecord.Kind, _ id: String) -> SyncRecord? {
        let key = "\(kind.rawValue):\(id)"
        if let date = db.tombstone(key) { return SyncRecord(kind: kind, id: id, updatedAt: date, deleted: true) }
        guard let uuid = UUID(uuidString: id) else { return nil }
        switch kind {
        case .clipping:
            guard let clip = db.clip(uuid), !clip.sensitive else { return nil }
            return SyncRecord(kind: kind, id: id, updatedAt: clip.updatedAt, payload: try? SyncMerge.encode(clip))
        case .pastebin:
            return library.pastebins.first { $0.id == uuid }.map { SyncRecord(kind: kind, id: id, updatedAt: $0.updatedAt, payload: try? SyncMerge.encode($0)) }
        case .smartPastebin:
            return library.smartPastebins.first { $0.id == uuid }.map { SyncRecord(kind: kind, id: id, updatedAt: $0.updatedAt, payload: try? SyncMerge.encode($0)) }
        case .filter:
            return library.filters.first { $0.id == uuid }.map { SyncRecord(kind: kind, id: id, updatedAt: $0.updatedAt, payload: try? SyncMerge.encode($0)) }
        case .snippet:
            return library.snippets.first { $0.id == uuid }.map { SyncRecord(kind: kind, id: id, updatedAt: $0.updatedAt, payload: try? SyncMerge.encode($0)) }
        case .setting:
            return nil
        }
    }

    /// Every record this Mac would publish, for the first upload.
    func allRecordKeys() -> [(SyncRecord.Kind, String)] {
        var keys: [(SyncRecord.Kind, String)] = db.ids(.all).map { (.clipping, $0.uuidString) }
        keys += library.pastebins.map { (.pastebin, $0.id.uuidString) }
        keys += library.smartPastebins.map { (.smartPastebin, $0.id.uuidString) }
        keys += library.filters.map { (.filter, $0.id.uuidString) }
        keys += library.snippets.map { (.snippet, $0.id.uuidString) }
        for key in db.tombstoneKeys() {
            let parts = key.split(separator: ":", maxSplits: 1).map(String.init)
            if parts.count == 2, let kind = SyncRecord.Kind(rawValue: parts[0]), kind != .setting { keys.append((kind, parts[1])) }
        }
        return keys
    }

    /// Applies a record from another Mac if it's newer than what's here. Returns the id of a
    /// clipping whose content should be fetched.
    @discardableResult
    func applyRemote(_ record: SyncRecord) -> UUID? {
        if let local = localRecord(record.kind, record.id) {
            if record.updatedAt < local.updatedAt { return nil }
            if record.updatedAt == local.updatedAt && (local.deleted || !record.deleted) { return nil }
        }
        let key = record.key
        if record.deleted {
            try? db.setTombstone(key, at: record.updatedAt)
            guard let uuid = UUID(uuidString: record.id) else { return nil }
            switch record.kind {
            case .clipping:
                try? db.delete([uuid])
                try? FileManager.default.removeItem(at: contentURL(uuid))
                contentCache[uuid] = nil
                StackController.shared.remove([uuid])
                clippingsChanged()
            case .pastebin: library.pastebins.removeAll { $0.id == uuid }; metaChanged()
            case .smartPastebin: library.smartPastebins.removeAll { $0.id == uuid }; metaChanged()
            case .filter: library.filters.removeAll { $0.id == uuid }; metaChanged()
            case .snippet: library.snippets.removeAll { $0.id == uuid }; metaChanged()
            case .setting: break
            }
            return nil
        }
        guard let payload = record.payload else { return nil }
        try? db.setTombstone(key, at: nil)
        switch record.kind {
        case .clipping:
            guard var clip = try? SyncMerge.decode(Clipping.self, from: payload) else { return nil }
            clip.sensitive = false
            // The same thing copied on two Macs: keep the older record everywhere.
            if clip.inHistory, let twin = db.historyClip(withHash: clip.contentHash), twin.id != clip.id {
                if clip.createdAt < twin.createdAt || (clip.createdAt == twin.createdAt && clip.id.uuidString < twin.id.uuidString) {
                    clip.copiedAt = max(clip.copiedAt, twin.copiedAt)
                    clip.pinned = clip.pinned || twin.pinned
                    clip.updatedAt = max(clip.updatedAt, twin.updatedAt)
                    if hasContent(twin.id), !hasContent(clip.id), let content = content(for: twin.id) { storeContent(content, for: clip.id) }
                    try? db.upsert(clip)
                    delete([twin.id], sound: false)
                    SyncEngine.shared.mark(.clipping, clip.id.uuidString)
                } else {
                    try? db.setTombstone("clipping:\(clip.id.uuidString)", at: max(clip.updatedAt, twin.updatedAt))
                    SyncEngine.shared.mark(.clipping, clip.id.uuidString)
                    return nil
                }
            } else {
                try? db.upsert(clip)
            }
            clippingsChanged()
            return hasContent(clip.id) ? nil : clip.id
        case .pastebin:
            if let item = try? SyncMerge.decode(Pastebin.self, from: payload) { upsertLocal(item, into: &library.pastebins) }
        case .smartPastebin:
            if let item = try? SyncMerge.decode(SmartPastebin.self, from: payload) { upsertLocal(item, into: &library.smartPastebins) }
        case .filter:
            if let item = try? SyncMerge.decode(Filter.self, from: payload) { upsertLocal(item, into: &library.filters) }
        case .snippet:
            if let item = try? SyncMerge.decode(Snippet.self, from: payload) { upsertLocal(item, into: &library.snippets) }
        case .setting: break
        }
        metaChanged()
        return nil
    }

    private func upsertLocal<T: Identifiable>(_ item: T, into array: inout [T]) {
        if let i = array.firstIndex(where: { $0.id == item.id }) { array[i] = item } else { array.append(item) }
    }

    /// After a batch of remote changes: shortcuts and abbreviations may have changed.
    func remoteBatchApplied() {
        HotKeyCenter.shared.apply()
        SnippetExpander.shared.refresh()
        StackController.shared.libraryChanged()
    }
}

/// A stable, anonymous id for this Mac: a hash of the hardware UUID.
enum DeviceIdentity {
    static let id: String = {
        if let override = ProcessInfo.processInfo.environment["PASTELENS_DEVICE_ID"] { return override }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        defer { IOObjectRelease(service) }
        if let uuid = IORegistryEntryCreateCFProperty(service, "IOPlatformUUID" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String {
            return String(SyncCrypto.sha256Hex(Data(("PasteLens" + uuid).utf8)).prefix(16))
        }
        let key = "deviceID"
        if let saved = AppDefaults.store.string(forKey: key) { return saved }
        let made = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16)).lowercased()
        AppDefaults.store.set(made, forKey: key)
        return made
    }()

    static var name: String { ProcessInfo.processInfo.environment["PASTELENS_DEVICE_NAME"] ?? Host.current().localizedName ?? "Mac" }
}
