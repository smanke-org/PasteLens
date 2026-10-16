import Foundation

/// The layout PasteLens keeps in iCloud Drive, and how Macs agree on it.
///
///     PasteLens/
///       Keyring.json               the data key, wrapped with the sync passphrase
///       Devices/<device>.plsync    each Mac's full view of the library, encrypted; one writer per file
///       Content/<clipping>.plclip  each clipping's bytes, encrypted; written once by the Mac that copied it
///
/// No file is ever written by two Macs, so iCloud never has to resolve a conflict. Each
/// Mac reads everyone's snapshot and keeps, for every record, the version with the newest
/// `updatedAt` (last writer wins); deletions travel as tombstones so a slower Mac can't
/// bring something back.
public enum SyncLayout {
    public static let keyring = "Keyring.json"
    public static let devices = "Devices"
    public static let content = "Content"
    public static let snapshotExtension = "plsync"
    public static let contentExtension = "plclip"
    /// Tombstones older than this are forgotten.
    public static let tombstoneLifetime: TimeInterval = 90 * 86_400
}

public struct SyncRecord: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case clipping, pastebin, smartPastebin, filter, snippet, setting }

    public var kind: Kind
    public var id: String
    public var updatedAt: Date
    public var deleted: Bool
    public var payload: Data?

    public init(kind: Kind, id: String, updatedAt: Date, deleted: Bool = false, payload: Data? = nil) {
        self.kind = kind
        self.id = id
        self.updatedAt = updatedAt
        self.deleted = deleted
        self.payload = payload
    }

    public var key: String { "\(kind.rawValue):\(id)" }
}

public struct DeviceSnapshot: Codable, Sendable {
    public var deviceID: String
    public var deviceName: String
    public var writtenAt: Date
    public var appVersion: String
    public var records: [SyncRecord]

    public init(deviceID: String, deviceName: String, writtenAt: Date = Date(), appVersion: String, records: [SyncRecord]) {
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.writtenAt = writtenAt
        self.appVersion = appVersion
        self.records = records
    }
}

public enum SyncMerge {
    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .millisecondsSince1970
        e.outputFormatting = [.sortedKeys]
        return e
    }()
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .millisecondsSince1970
        return d
    }()

    public static func encode<T: Encodable>(_ value: T) throws -> Data { try encoder.encode(value) }
    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T { try decoder.decode(type, from: data) }

    /// What this Mac publishes: everything in the library that may leave it, plus tombstones and settings.
    /// `maxClipBytes` keeps very large clippings on this Mac (0 means no limit).
    public static func records(for library: Library, settings: [SyncRecord], maxClipBytes: Int = 0) -> [SyncRecord] {
        var out: [SyncRecord] = []
        for clip in library.clippings where syncable(clip, maxClipBytes: maxClipBytes) {
            out.append(SyncRecord(kind: .clipping, id: clip.id.uuidString, updatedAt: clip.updatedAt, payload: try? encode(clip)))
        }
        for bin in library.pastebins { out.append(SyncRecord(kind: .pastebin, id: bin.id.uuidString, updatedAt: bin.updatedAt, payload: try? encode(bin))) }
        for bin in library.smartPastebins { out.append(SyncRecord(kind: .smartPastebin, id: bin.id.uuidString, updatedAt: bin.updatedAt, payload: try? encode(bin))) }
        for filter in library.filters { out.append(SyncRecord(kind: .filter, id: filter.id.uuidString, updatedAt: filter.updatedAt, payload: try? encode(filter))) }
        for snippet in library.snippets { out.append(SyncRecord(kind: .snippet, id: snippet.id.uuidString, updatedAt: snippet.updatedAt, payload: try? encode(snippet))) }
        for (key, date) in library.tombstones {
            let parts = key.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, let kind = SyncRecord.Kind(rawValue: parts[0]) else { continue }
            out.append(SyncRecord(kind: kind, id: parts[1], updatedAt: date, deleted: true))
        }
        out.append(contentsOf: settings)
        return out
    }

    public static func syncable(_ clip: Clipping, maxClipBytes: Int) -> Bool {
        !clip.sensitive && (maxClipBytes <= 0 || clip.sizeBytes <= maxClipBytes)
    }

    public struct Outcome: Sendable {
        /// Clippings added or changed by another Mac, whose content may still need fetching.
        public var arrivedClippings: [UUID] = []
        public var removedClippings: [UUID] = []
        public var settings: [SyncRecord] = []
        public var changed = false
    }

    /// Applies whatever other Macs have that is newer than what's here.
    /// `localSettings` maps each synced setting key to when it last changed here.
    public static func merge(_ snapshots: [DeviceSnapshot], into library: inout Library,
                             localSettings: [String: Date]) -> Outcome {
        var outcome = Outcome()
        // Newest remote version of every record.
        var newest: [String: SyncRecord] = [:]
        for snapshot in snapshots {
            for record in snapshot.records {
                if let current = newest[record.key], !wins(record, over: current) { continue }
                newest[record.key] = record
            }
        }

        let clipIndex = Dictionary(uniqueKeysWithValues: library.clippings.enumerated().map { ($1.id.uuidString, $0) })
        var removedKeys = Set<String>()
        var updatedClips: [Int: Clipping] = [:]
        var addedClips: [Clipping] = []

        for (key, record) in newest {
            let localDate = localDate(for: record, in: library, clipIndex: clipIndex, localSettings: localSettings)
            let localDeleted = library.tombstones[key] != nil
            if let localDate {
                if record.updatedAt < localDate { continue }
                if record.updatedAt == localDate && (localDeleted || !record.deleted) { continue }
            }
            if record.kind == .setting {
                outcome.settings.append(record)
                continue
            }
            if record.deleted {
                library.tombstones[key] = record.updatedAt
                removedKeys.insert(key)
                if record.kind == .clipping, let id = UUID(uuidString: record.id) { outcome.removedClippings.append(id) }
                outcome.changed = true
                continue
            }
            guard let payload = record.payload else { continue }
            library.tombstones[key] = nil
            outcome.changed = true
            switch record.kind {
            case .clipping:
                guard var clip = try? decode(Clipping.self, from: payload) else { continue }
                clip.sensitive = false
                if let index = clipIndex[record.id] { updatedClips[index] = clip } else { addedClips.append(clip) }
                outcome.arrivedClippings.append(clip.id)
            case .pastebin:
                if let item = try? decode(Pastebin.self, from: payload) { upsert(item, into: &library.pastebins) }
            case .smartPastebin:
                if let item = try? decode(SmartPastebin.self, from: payload) { upsert(item, into: &library.smartPastebins) }
            case .filter:
                if let item = try? decode(Filter.self, from: payload) { upsert(item, into: &library.filters) }
            case .snippet:
                if let item = try? decode(Snippet.self, from: payload) { upsert(item, into: &library.snippets) }
            case .setting: break
            }
        }

        if !updatedClips.isEmpty || !addedClips.isEmpty || !removedKeys.isEmpty {
            for (index, clip) in updatedClips { library.clippings[index] = clip }
            library.clippings.removeAll { removedKeys.contains("clipping:\($0.id.uuidString)") }
            // Something the same as a local clipping (copied on both Macs) is merged, not duplicated.
            for clip in addedClips {
                if let twin = library.clippings.firstIndex(where: { $0.contentHash == clip.contentHash && $0.inHistory && clip.inHistory }) {
                    let local = library.clippings[twin]
                    // Keep the older id everywhere so both Macs converge on one record.
                    if clip.createdAt < local.createdAt || (clip.createdAt == local.createdAt && clip.id.uuidString < local.id.uuidString) {
                        var merged = clip
                        merged.copiedAt = max(clip.copiedAt, local.copiedAt)
                        merged.pinned = clip.pinned || local.pinned
                        merged.pastebinIDs = Array(Set(clip.pastebinIDs + local.pastebinIDs))
                        merged.updatedAt = max(clip.updatedAt, local.updatedAt)
                        library.clippings[twin] = merged
                        library.tombstones["clipping:\(local.id.uuidString)"] = merged.updatedAt
                        outcome.removedClippings.append(local.id)
                    } else {
                        library.tombstones["clipping:\(clip.id.uuidString)"] = max(clip.updatedAt, local.updatedAt)
                    }
                } else {
                    library.clippings.append(clip)
                }
            }
            library.clippings.sort { $0.copiedAt > $1.copiedAt }
        }
        pruneTombstones(&library)
        return outcome
    }

    static func wins(_ a: SyncRecord, over b: SyncRecord) -> Bool {
        if a.updatedAt != b.updatedAt { return a.updatedAt > b.updatedAt }
        return a.deleted && !b.deleted
    }

    static func localDate(for record: SyncRecord, in library: Library, clipIndex: [String: Int],
                          localSettings: [String: Date]) -> Date? {
        if let tomb = library.tombstones[record.key] { return tomb }
        switch record.kind {
        case .clipping: return clipIndex[record.id].map { library.clippings[$0].updatedAt }
        case .pastebin: return library.pastebins.first { $0.id.uuidString == record.id }?.updatedAt
        case .smartPastebin: return library.smartPastebins.first { $0.id.uuidString == record.id }?.updatedAt
        case .filter: return library.filters.first { $0.id.uuidString == record.id }?.updatedAt
        case .snippet: return library.snippets.first { $0.id.uuidString == record.id }?.updatedAt
        case .setting: return localSettings[record.id]
        }
    }

    static func upsert<T: Identifiable>(_ item: T, into array: inout [T]) {
        if let i = array.firstIndex(where: { $0.id == item.id }) { array[i] = item } else { array.append(item) }
    }

    public static func pruneTombstones(_ library: inout Library, now: Date = Date()) {
        library.tombstones = library.tombstones.filter { now.timeIntervalSince($0.value) < SyncLayout.tombstoneLifetime }
    }
}
