import AppKit
import CloudKit
import CryptoKit
import Observation
import PasteLensKit
import Security

/// Syncs the library, clipping contents and settings between your Macs through CloudKit,
/// one record per change, with every record sealed by AES-256-GCM before it leaves this Mac
/// (see `SyncCrypto`). Apple's servers only ever see record names, dates and ciphertext.
///
/// Records live in a custom zone of the private database:
///
///     Keyring          the data key, wrapped with the sync passphrase
///     Device_<id>      each Mac's name and last visit (sealed)
///     Item_<kind>_<id> a clipping's details, a pastebin, filter, snippet or setting (sealed)
///     Content_<id>     a clipping's bytes, as a sealed asset
///
/// Changes are pushed as they happen and fetched incrementally with a change token, so a
/// new copy costs one small upload no matter how big History is. Each Item carries the time
/// it last changed, and the newest version wins on every Mac; deletions travel as records
/// marked deleted, so a slower Mac can't bring something back.
@Observable
@MainActor
final class SyncEngine {
    static let shared = SyncEngine()

    enum Status: Equatable {
        case off
        case unavailable(String)
        /// Sync is on but this Mac doesn't hold the key yet (first setup, or the passphrase changed elsewhere).
        case needsPassphrase
        case syncing
        case idle
        case failed(String)

        var summary: String {
            switch self {
            case .off: "Off"
            case .unavailable(let why): why
            case .needsPassphrase: "Enter your sync passphrase to start syncing"
            case .syncing: "Syncing…"
            case .idle: "Up to date"
            case .failed(let why): why
            }
        }
    }

    struct Device: Identifiable, Equatable, Codable {
        var id: String
        var name: String
        var lastSeen: Date
        var appVersion: String
    }

    private(set) var status: Status = .off
    private(set) var lastSync: Date?
    private(set) var devices: [Device] = []
    /// Whether a keyring already exists in iCloud (so setup means joining, not starting).
    private(set) var keyringExists = false
    private(set) var pendingContent = 0

    var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: "sync.enabled") }
        set { UserDefaults.standard.set(newValue, forKey: "sync.enabled") }
    }

    @ObservationIgnored private var key: SymmetricKey?
    @ObservationIgnored private var outbox: Set<String> = []
    @ObservationIgnored private var pushScheduled = false
    @ObservationIgnored private var pushing = false
    @ObservationIgnored private var fetching = false
    @ObservationIgnored private var fetchAgain = false
    @ObservationIgnored private var pollTimer: Timer?
    @ObservationIgnored private var missingContent: Set<UUID> = []
    @ObservationIgnored private var started = false

    static let containerID = "iCloud.com.smanke.PasteLens"
    @ObservationIgnored private lazy var container = CKContainer(identifier: Self.containerID)
    private var database: CKDatabase { container.privateCloudDatabase }
    private let zoneID = CKRecordZone.ID(zoneName: ProcessInfo.processInfo.environment["PASTELENS_CLOUD_ZONE"] ?? "PasteLens",
                                         ownerName: CKCurrentUserDefaultName)

    private var store: ClipStore { ClipStore.shared }

    private var stamps: [String: Date] {
        get { (UserDefaults.standard.dictionary(forKey: "sync.stamps") as? [String: Date]) ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "sync.stamps") }
    }

    var folderDescription: String { "iCloud (PasteLens's private database)" }

    // MARK: Lifecycle

    func start() {
        loadOutbox()
        guard enabled else { status = .off; return }
        if !started {
            started = true
            NotificationCenter.default.addObserver(forName: .CKAccountChanged, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { SyncEngine.shared.restart() }
            }
        }
        Task { await connect() }
    }

    private func restart() {
        key = nil
        Task { await connect() }
    }

    /// Checks the account and keyring, then starts syncing if this Mac has the key.
    private func connect() async {
        guard enabled else { return }
        do {
            guard try await accountAvailable() else { return }
            try await ensureZone()
            let keyring = try await fetchKeyring()
            keyringExists = keyring != nil
            guard let keyring, let stored = Keychain.loadKey(), SyncCrypto.keyID(for: stored) == keyring.keyID else {
                key = nil
                status = .needsPassphrase
                return
            }
            key = stored
            await subscribe()
            startPolling()
            await fetchChanges()
            await publishDevice()
            schedulePush(after: 0.5)
        } catch {
            status = .failed(describe(error))
        }
    }

    /// Whether iCloud is usable; sets the status when it isn't.
    private func accountAvailable() async throws -> Bool {
        let account = try await container.accountStatus()
        switch account {
        case .available: return true
        case .noAccount: status = .unavailable("Sign in to iCloud in System Settings to sync.")
        case .restricted: status = .unavailable("iCloud is restricted on this Mac.")
        case .temporarilyUnavailable: status = .unavailable("iCloud is temporarily unavailable. PasteLens will try again.")
        default: status = .unavailable("iCloud isn't available right now.")
        }
        return false
    }

    /// Checks iCloud and whether a keyring exists, for the setup screen.
    func probe() {
        Task {
            do {
                guard try await accountAvailable() else { return }
                try await ensureZone()
                keyringExists = try await fetchKeyring() != nil || legacyKeyring() != nil
                if case .unavailable = status { status = enabled ? .needsPassphrase : .off }
            } catch {
                status = .failed(describe(error))
            }
        }
    }

    /// Turns sync on with a passphrase: starts a new encrypted sync set, or joins the one
    /// another Mac started. Throws if the passphrase doesn't match.
    func setUp(passphrase: String) async throws {
        guard try await accountAvailable() else { throw Bridge.Failure(status.summary) }
        try await ensureZone()
        let dataKey: SymmetricKey
        if let keyring = try await fetchKeyring() {
            dataKey = try await Task.detached { try SyncCrypto.unwrap(keyring, passphrase: passphrase) }.value
        } else if let legacy = legacyKeyring() {
            // 1.0.x synced through iCloud Drive; keep its key so the same passphrase works.
            dataKey = try await Task.detached { try SyncCrypto.unwrap(legacy, passphrase: passphrase) }.value
            try await saveKeyring(legacy)
        } else {
            let (keyring, fresh) = try await Task.detached { try SyncCrypto.createKeyring(passphrase: passphrase) }.value
            try await saveKeyring(keyring)
            dataKey = fresh
        }
        Keychain.saveKey(dataKey)
        key = dataKey
        keyringExists = true
        enabled = true
        // Everything here goes up once; after that, only changes.
        for (kind, id) in store.allRecordKeys() { outbox.insert(Self.itemName(kind, id)) }
        for setting in Preferences.syncedKeys where UserDefaults.standard.object(forKey: setting) != nil {
            outbox.insert(Self.itemName(.setting, setting))
        }
        saveOutbox()
        await subscribe()
        startPolling()
        await fetchChanges()
        await publishDevice()
        schedulePush(after: 0.2)
    }

    func changePassphrase(to passphrase: String) async throws {
        guard let key else { throw SyncCrypto.CryptoError.wrongPassphrase }
        let keyring = try await Task.detached { try SyncCrypto.wrap(key, passphrase: passphrase) }.value
        try await saveKeyring(keyring)
    }

    func turnOff() {
        enabled = false
        pollTimer?.invalidate()
        pollTimer = nil
        status = .off
        let device = CKRecord.ID(recordName: "Device_\(DeviceIdentity.id)", zoneID: zoneID)
        Task { _ = try? await database.deleteRecord(withID: device) }
        devices = []
    }

    /// Removes everything PasteLens keeps in iCloud, for every Mac. Other Macs will need a new passphrase.
    func deleteCloudData() {
        turnOff()
        Keychain.deleteKey()
        key = nil
        keyringExists = false
        let zone = zoneID
        Task { _ = try? await database.deleteRecordZone(withID: zone) }
        UserDefaults.standard.removeObject(forKey: "ck.zoneReady")
        UserDefaults.standard.removeObject(forKey: "ck.subscribed")
        try? store.db.set(nil, forKey: "ck.token")
        clearOutbox()
    }

    // MARK: Local changes

    /// A record changed or was deleted here; it goes up shortly.
    func mark(_ kind: SyncRecord.Kind, _ id: String) {
        outbox.insert(Self.itemName(kind, id))
        saveOutbox()
        guard enabled, key != nil else { return }
        schedulePush(after: 1.5)
    }

    func settingChanged(_ key: String) {
        guard !Preferences.shared.applyingRemote else { return }
        stamps[key] = Date()
        mark(.setting, key)
    }

    /// Clippings content toggled back on: queue every clipping so their content goes up.
    func uploadAllContent() {
        for id in store.db.ids(.all) { outbox.insert(Self.itemName(.clipping, id.uuidString)) }
        saveOutbox()
        schedulePush(after: 0.5)
    }

    func pull() { Task { await fetchChanges() } }

    /// Alias kept for callers from before CloudKit.
    func libraryChanged() { schedulePush(after: 1.5) }

    private func startPolling() {
        pollTimer?.invalidate()
        // CloudKit normally announces changes; this catches anything missed. A fetch with
        // nothing new is one small request.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            MainActor.assumeIsolated { SyncEngine.shared.pull() }
        }
    }

    private func schedulePush(after delay: TimeInterval) {
        guard !pushScheduled else { return }
        pushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            MainActor.assumeIsolated {
                SyncEngine.shared.pushScheduled = false
                Task { await SyncEngine.shared.push() }
            }
        }
    }

    // MARK: Outbox

    private func loadOutbox() {
        if let data = store.db.data(forKey: "ck.outbox"), let names = try? JSONDecoder().decode([String].self, from: data) {
            outbox = Set(names)
        }
    }

    private func saveOutbox() {
        try? store.db.set(try? JSONEncoder().encode(Array(outbox)), forKey: "ck.outbox")
    }

    private func clearOutbox() {
        outbox = []
        saveOutbox()
    }

    // MARK: Record names

    static func itemName(_ kind: SyncRecord.Kind, _ id: String) -> String { "Item_\(kind.rawValue)_\(id)" }

    static func parseItemName(_ name: String) -> (SyncRecord.Kind, String)? {
        let parts = name.split(separator: "_", maxSplits: 2).map(String.init)
        guard parts.count == 3, parts[0] == "Item", let kind = SyncRecord.Kind(rawValue: parts[1]) else { return nil }
        return (kind, parts[2])
    }

    private func recordID(_ name: String) -> CKRecord.ID { CKRecord.ID(recordName: name, zoneID: zoneID) }

    /// A record ready to save: the last known server version when there is one, so CloudKit
    /// can tell whether someone else changed it meanwhile.
    private func baseRecord(_ name: String, type: String) -> CKRecord {
        if let data = store.db.data(forKey: "ck.sys.\(name)"),
           let coder = try? NSKeyedUnarchiver(forReadingFrom: data) {
            coder.requiresSecureCoding = true
            if let record = CKRecord(coder: coder) { coder.finishDecoding(); return record }
        }
        return CKRecord(recordType: type, recordID: recordID(name))
    }

    private func remember(_ record: CKRecord) {
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: coder)
        coder.finishEncoding()
        try? store.db.set(coder.encodedData, forKey: "ck.sys.\(record.recordID.recordName)")
    }

    // MARK: Pushing

    private func localSettingRecord(_ setting: String) -> SyncRecord? {
        guard let value = UserDefaults.standard.object(forKey: setting),
              let payload = try? PropertyListSerialization.data(fromPropertyList: ["v": value], format: .binary, options: 0) else { return nil }
        return SyncRecord(kind: .setting, id: setting, updatedAt: stamps[setting] ?? Date(timeIntervalSince1970: 0), payload: payload)
    }

    private func localRecord(_ kind: SyncRecord.Kind, _ id: String) -> SyncRecord? {
        kind == .setting ? localSettingRecord(id) : store.localRecord(kind, id)
    }

    private func push() async {
        guard enabled, let key, !pushing, !outbox.isEmpty else { return }
        pushing = true
        status = .syncing
        defer { pushing = false }
        let maxBytes = Int(Preferences.shared.syncMaxClipMB * 1_048_576)
        while !outbox.isEmpty {
            let batch = Array(outbox.prefix(150))
            var saves: [CKRecord] = []
            var deletes: [CKRecord.ID] = []
            var tempFiles: [URL] = []
            for name in batch {
                guard let (kind, id) = Self.parseItemName(name), let local = localRecord(kind, id) else { continue }
                if kind == .clipping, !local.deleted {
                    guard Preferences.shared.syncContents else { continue }
                    // Very large clippings stay on this Mac.
                    if maxBytes > 0, let payload = local.payload, let clip = try? SyncMerge.decode(Clipping.self, from: payload),
                       clip.sizeBytes > maxBytes { continue }
                }
                guard let sealed = try? SyncCrypto.seal(SyncMerge.encode(local), using: key) else { continue }
                let record = baseRecord(name, type: "Item")
                record["data"] = sealed as CKRecordValue
                saves.append(record)
                if kind == .clipping, let uuid = UUID(uuidString: id) {
                    if local.deleted {
                        deletes.append(recordID("Content_\(uuid.uuidString)"))
                    } else if let content = contentRecord(for: uuid, payload: local.payload, key: key) {
                        saves.append(content.record)
                        tempFiles.append(content.file)
                    }
                }
            }
            let done = await save(saves, deleting: deletes)
            for file in tempFiles { try? FileManager.default.removeItem(at: file) }
            guard done else { saveOutbox(); return }
            outbox.subtract(batch)
            saveOutbox()
        }
        lastSync = Date()
        status = .idle
    }

    /// The clipping's bytes as a sealed asset, if they haven't gone up since they last changed.
    private func contentRecord(for id: UUID, payload: Data?, key: SymmetricKey) -> (record: CKRecord, file: URL)? {
        guard let payload, let clip = try? SyncMerge.decode(Clipping.self, from: payload),
              store.db.data(forKey: "ck.content.\(id.uuidString)") != Data(clip.contentHash.utf8),
              let content = store.content(for: id) else { return nil }
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        guard let plain = try? encoder.encode(content), let sealed = try? SyncCrypto.seal(plain, using: key) else { return nil }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("pastelens-\(UUID().uuidString).plclip")
        guard (try? sealed.write(to: file)) != nil else { return nil }
        let record = baseRecord("Content_\(id.uuidString)", type: "Content")
        record["asset"] = CKAsset(fileURL: file)
        record["hash"] = clip.contentHash as CKRecordValue
        return (record, file)
    }

    /// Saves records, resolving conflicts by keeping whichever version changed last.
    /// Returns false when the batch should be retried later.
    private func save(_ records: [CKRecord], deleting: [CKRecord.ID]) async -> Bool {
        guard !records.isEmpty || !deleting.isEmpty else { return true }
        do {
            let (saveResults, _) = try await database.modifyRecords(saving: records, deleting: deleting,
                                                                    savePolicy: .ifServerRecordUnchanged, atomically: false)
            var retry: [CKRecord] = []
            for (id, result) in saveResults {
                switch result {
                case .success(let saved):
                    remember(saved)
                    if saved.recordType == "Content", let hash = saved["hash"] as? String {
                        try? store.db.set(Data(hash.utf8), forKey: "ck.content.\(id.recordName.dropFirst(8))")
                    }
                case .failure(let error):
                    guard let ck = error as? CKError else { continue }
                    if ck.code == .serverRecordChanged, let server = ck.serverRecord,
                       let mine = records.first(where: { $0.recordID == id }) {
                        if let resolved = resolve(mine: mine, server: server) { retry.append(resolved) }
                    } else if ck.code == .zoneNotFound || ck.code == .userDeletedZone {
                        UserDefaults.standard.removeObject(forKey: "ck.zoneReady")
                        try? await ensureZone()
                        return false
                    } else {
                        NSLog("PasteLens: sync couldn't save \(id.recordName): \(ck.localizedDescription)")
                    }
                }
            }
            if !retry.isEmpty { return await save(retry, deleting: []) }
            return true
        } catch {
            status = .failed(describe(error))
            if let ck = error as? CKError, let delay = ck.retryAfterSeconds {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    MainActor.assumeIsolated { SyncEngine.shared.schedulePush(after: 0) }
                }
            }
            return false
        }
    }

    /// Someone else changed a record since this Mac last saw it. Whichever version changed
    /// later wins; if it's theirs, it's applied here instead of saving ours.
    private func resolve(mine: CKRecord, server: CKRecord) -> CKRecord? {
        remember(server)
        guard let key else { return nil }
        if server.recordType == "Content" {
            server["asset"] = mine["asset"]
            server["hash"] = mine["hash"]
            return server
        }
        guard let mineData = mine["data"] as? Data, let theirsData = server["data"] as? Data,
              let ours = try? SyncMerge.decode(SyncRecord.self, from: SyncCrypto.open(mineData, using: key)),
              let theirs = try? SyncMerge.decode(SyncRecord.self, from: SyncCrypto.open(theirsData, using: key)) else {
            server["data"] = mine["data"]
            return server
        }
        if theirs.updatedAt > ours.updatedAt || (theirs.updatedAt == ours.updatedAt && theirs.deleted && !ours.deleted) {
            apply(theirs)
            return nil
        }
        server["data"] = mineData as CKRecordValue
        return server
    }

    // MARK: Fetching

    func fetchChanges() async {
        guard enabled, let key else { return }
        if fetching { fetchAgain = true; return }
        fetching = true
        status = .syncing
        var token: CKServerChangeToken?
        if let data = store.db.data(forKey: "ck.token") {
            token = try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: data)
        }
        var applied = 0
        do {
            var more = true
            while more {
                let changes = try await database.recordZoneChanges(inZoneWith: zoneID, since: token)
                for (_, result) in changes.modificationResultsByID {
                    guard case .success(let modification) = result else { continue }
                    let record = modification.record
                    remember(record)
                    if handle(record, key: key) { applied += 1 }
                }
                token = changes.changeToken
                more = changes.moreComing
                if let data = try? NSKeyedArchiver.archivedData(withRootObject: changes.changeToken, requiringSecureCoding: true) {
                    try? store.db.set(data, forKey: "ck.token")
                }
                if case .needsPassphrase = status { fetching = false; return }
            }
        } catch let error as CKError where error.code == .changeTokenExpired {
            try? store.db.set(nil, forKey: "ck.token")
            fetching = false
            await fetchChanges()
            return
        } catch let error as CKError where error.code == .zoneNotFound || error.code == .userDeletedZone {
            // The sync data was deleted from another Mac.
            fetching = false
            UserDefaults.standard.removeObject(forKey: "ck.zoneReady")
            keyChangedElsewhere()
            return
        } catch {
            fetching = false
            status = .failed(describe(error))
            return
        }
        if applied > 0 { store.remoteBatchApplied() }
        await fetchMissingContent(key: key)
        lastSync = Date()
        if case .syncing = status { status = .idle }
        fetching = false
        if fetchAgain {
            fetchAgain = false
            await fetchChanges()
        }
    }

    /// Applies one fetched record. Returns true if something here changed.
    private func handle(_ record: CKRecord, key: SymmetricKey) -> Bool {
        switch record.recordType {
        case "Keyring":
            if let data = record["data"] as? Data, let keyring = try? SyncMerge.decode(SyncCrypto.Keyring.self, from: data),
               keyring.keyID != SyncCrypto.keyID(for: key) {
                keyChangedElsewhere()
            }
            return false
        case "Device":
            guard let data = record["data"] as? Data, let plain = try? SyncCrypto.open(data, using: key),
                  let device = try? JSONDecoder().decode(Device.self, from: plain), device.id != DeviceIdentity.id else { return false }
            devices.removeAll { $0.id == device.id }
            devices.append(device)
            devices.sort { $0.name < $1.name }
            return false
        case "Content":
            guard let asset = record["asset"] as? CKAsset, let url = asset.fileURL, let sealed = try? Data(contentsOf: url),
                  let plain = try? SyncCrypto.open(sealed, using: key),
                  let content = try? PropertyListDecoder().decode(ClipContent.self, from: plain),
                  let id = UUID(uuidString: String(record.recordID.recordName.dropFirst(8))) else { return false }
            if store.clip(id) != nil || missingContent.contains(id) {
                store.storeContent(content, for: id)
                missingContent.remove(id)
                if let hash = record["hash"] as? String { try? store.db.set(Data(hash.utf8), forKey: "ck.content.\(id.uuidString)") }
                store.clippingsChanged()
            }
            return false
        case "Item":
            guard let data = record["data"] as? Data, let plain = try? SyncCrypto.open(data, using: key),
                  let item = try? SyncMerge.decode(SyncRecord.self, from: plain) else { return false }
            return apply(item)
        default:
            return false
        }
    }

    @discardableResult
    private func apply(_ item: SyncRecord) -> Bool {
        if item.kind == .setting {
            if let local = stamps[item.id], item.updatedAt <= local { return false }
            guard let payload = item.payload,
                  let dict = try? PropertyListSerialization.propertyList(from: payload, format: nil) as? [String: Any],
                  let value = dict["v"] else { return false }
            UserDefaults.standard.set(value, forKey: item.id)
            var s = stamps
            s[item.id] = item.updatedAt
            stamps = s
            Preferences.shared.reloadFromDefaults()
            #if !APPSTORE
            Preferences.shared.applyingRemote = true
            AutoUpdater.shared.reloadPolicy()
            Preferences.shared.applyingRemote = false
            #endif
            return true
        }
        if let missing = store.applyRemote(item) { missingContent.insert(missing) }
        return true
    }

    private func fetchMissingContent(key: SymmetricKey) async {
        missingContent = Set(missingContent.filter { store.clip($0) != nil && !store.hasContent($0) })
        pendingContent = missingContent.count
        guard !missingContent.isEmpty else { return }
        let ids = missingContent.map { recordID("Content_\($0.uuidString)") }
        for start in stride(from: 0, to: ids.count, by: 100) {
            let chunk = Array(ids[start..<min(start + 100, ids.count)])
            guard let results = try? await database.records(for: chunk) else { continue }
            for (_, result) in results {
                if case .success(let record) = result { _ = handle(record, key: key) }
            }
        }
        pendingContent = missingContent.count
    }

    private func keyChangedElsewhere() {
        Keychain.deleteKey()
        key = nil
        pollTimer?.invalidate()
        status = .needsPassphrase
        keyringExists = false
    }

    // MARK: Zone, keyring, devices, subscription

    private func ensureZone() async throws {
        if UserDefaults.standard.string(forKey: "ck.zoneReady") == zoneID.zoneName { return }
        _ = try await database.modifyRecordZones(saving: [CKRecordZone(zoneID: zoneID)], deleting: [])
        UserDefaults.standard.set(zoneID.zoneName, forKey: "ck.zoneReady")
    }

    private func fetchKeyring() async throws -> SyncCrypto.Keyring? {
        do {
            let record = try await database.record(for: recordID("Keyring"))
            remember(record)
            guard let data = record["data"] as? Data else { return nil }
            return try? SyncMerge.decode(SyncCrypto.Keyring.self, from: data)
        } catch let error as CKError where error.code == .unknownItem {
            return nil
        } catch let error as CKError where error.code == .zoneNotFound || error.code == .userDeletedZone {
            UserDefaults.standard.removeObject(forKey: "ck.zoneReady")
            try await ensureZone()
            return nil
        }
    }

    /// The wrapped key isn't a secret by itself: it only opens with the passphrase.
    private func saveKeyring(_ keyring: SyncCrypto.Keyring) async throws {
        let record = baseRecord("Keyring", type: "Keyring")
        record["data"] = try SyncMerge.encode(keyring) as CKRecordValue
        let (results, _) = try await database.modifyRecords(saving: [record], deleting: [], savePolicy: .allKeys, atomically: true)
        for (_, result) in results { if case .success(let saved) = result { remember(saved) } }
    }

    /// 1.0.x kept its keyring in iCloud Drive; read it so upgrading Macs keep their passphrase.
    private func legacyKeyring() -> SyncCrypto.Keyring? {
        #if APPSTORE
        return nil
        #else
        if ProcessInfo.processInfo.environment["PASTELENS_DATA_FOLDER"] != nil { return nil } // test runs
        let file = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/PasteLens/Keyring.json")
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? SyncMerge.decode(SyncCrypto.Keyring.self, from: data)
        #endif
    }

    private func publishDevice() async {
        guard let key else { return }
        let device = Device(id: DeviceIdentity.id, name: DeviceIdentity.name, lastSeen: Date(), appVersion: AppInfo.version)
        guard let plain = try? JSONEncoder().encode(device), let sealed = try? SyncCrypto.seal(plain, using: key) else { return }
        let record = baseRecord("Device_\(DeviceIdentity.id)", type: "Device")
        record["data"] = sealed as CKRecordValue
        if let (results, _) = try? await database.modifyRecords(saving: [record], deleting: [], savePolicy: .allKeys, atomically: true) {
            for (_, result) in results { if case .success(let saved) = result { remember(saved) } }
        }
    }

    /// Asks CloudKit to wake PasteLens when another Mac changes something.
    private func subscribe() async {
        NSApp.registerForRemoteNotifications()
        let id = "pastelens-zone-\(zoneID.zoneName)"
        guard UserDefaults.standard.string(forKey: "ck.subscribed") != id else { return }
        let subscription = CKRecordZoneSubscription(zoneID: zoneID, subscriptionID: id)
        let info = CKSubscription.NotificationInfo()
        info.shouldSendContentAvailable = true
        subscription.notificationInfo = info
        if (try? await database.modifySubscriptions(saving: [subscription], deleting: [])) != nil {
            UserDefaults.standard.set(id, forKey: "ck.subscribed")
        }
    }

    func describe(_ error: Error) -> String {
        guard let ck = error as? CKError else { return error.localizedDescription }
        switch ck.code {
        case .networkUnavailable, .networkFailure: return "Offline. PasteLens will sync when you're connected."
        case .quotaExceeded: return "Your iCloud storage is full."
        case .notAuthenticated: return "Sign in to iCloud in System Settings to sync."
        case .serviceUnavailable, .requestRateLimited, .zoneBusy: return "iCloud is busy. PasteLens will try again shortly."
        case .missingEntitlement, .badContainer: return "This copy of PasteLens isn't set up for iCloud."
        default: return ck.localizedDescription
        }
    }
}

/// The sync data key, kept in this Mac's login keychain.
enum Keychain {
    static let service = "com.smanke.PasteLens.sync"
    /// Test runs pointed at their own data folder keep their key apart from the real one.
    static let account = ProcessInfo.processInfo.environment["PASTELENS_DATA_FOLDER"] == nil ? "data-key" : "data-key-test"

    static func saveKey(_ key: SymmetricKey) {
        deleteKey()
        let data = key.withUnsafeBytes { Data($0) }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrLabel as String: "PasteLens sync key",
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        if status != errSecSuccess { NSLog("PasteLens: couldn't save the sync key (\(status))") }
    }

    static func loadKey() -> SymmetricKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data, data.count == 32 else { return nil }
        return SymmetricKey(data: data)
    }

    static func deleteKey() {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
    }
}
