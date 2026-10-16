import AppKit
import CryptoKit
import Observation
import PasteLensKit
import Security

/// Syncs the library, clipping contents and settings between your Macs through iCloud Drive,
/// with every file sealed by AES-256-GCM before it leaves this Mac (see `SyncCrypto`).
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

    struct Device: Identifiable, Equatable {
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
    @ObservationIgnored private var folder: URL?
    @ObservationIgnored private var publishScheduled = false
    @ObservationIgnored private var pullTimer: Timer?
    @ObservationIgnored private var watcher: DispatchSourceFileSystemObject?
    @ObservationIgnored private var uploads: Set<UUID> = []
    @ObservationIgnored private var missingContent: Set<UUID> = []
    @ObservationIgnored private var lastSeenSnapshots: [String: Date] = [:]
    @ObservationIgnored private let io = DispatchQueue(label: "PasteLens.sync", qos: .utility)

    private var stamps: [String: Date] {
        get { (UserDefaults.standard.dictionary(forKey: "sync.stamps") as? [String: Date]) ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "sync.stamps") }
    }

    // MARK: Folder

    /// iCloud Drive/PasteLens for the GitHub build; the app's own iCloud container in the App Store build.
    nonisolated static func locateFolder() -> Result<URL, SyncFailure> {
        if let override = ProcessInfo.processInfo.environment["PASTELENS_SYNC_FOLDER"] {
            return .success(URL(fileURLWithPath: override, isDirectory: true))
        }
        #if APPSTORE
        guard FileManager.default.ubiquityIdentityToken != nil else { return .failure(SyncFailure("Sign in to iCloud and turn on iCloud Drive to sync.")) }
        guard let container = FileManager.default.url(forUbiquityContainerIdentifier: "iCloud.com.smanke.PasteLens") else {
            return .failure(SyncFailure("iCloud Drive isn't available to PasteLens."))
        }
        return .success(container.appendingPathComponent("Documents/Sync", isDirectory: true))
        #else
        let home = FileManager.default.homeDirectoryForCurrentUser
        let drive = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        guard FileManager.default.fileExists(atPath: drive.path) else {
            return .failure(SyncFailure("Turn on iCloud Drive in System Settings › Apple Account › iCloud to sync."))
        }
        return .success(drive.appendingPathComponent("PasteLens", isDirectory: true))
        #endif
    }

    struct SyncFailure: Error { var message: String; init(_ m: String) { message = m } }

    var folderDescription: String {
        #if APPSTORE
        "iCloud Drive (PasteLens's app folder)"
        #else
        #if DEBUG
        if ProcessInfo.processInfo.environment["PASTELENS_SYNC_FOLDER"] != nil { return "iCloud Drive/PasteLens" }
        #endif
        return folder.map { $0.path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path + "/Library/Mobile Documents/com~apple~CloudDocs", with: "iCloud Drive") } ?? "iCloud Drive/PasteLens"
        #endif
    }

    // MARK: Lifecycle

    func start() {
        guard enabled else { status = .off; return }
        io.async {
            let located = Self.locateFolder()
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.didLocate(located) }
            }
        }
    }

    private func didLocate(_ located: Result<URL, SyncFailure>) {
        switch located {
        case .failure(let failure):
            status = .unavailable(failure.message)
        case .success(let url):
            folder = url
            try? FileManager.default.createDirectory(at: url.appendingPathComponent(SyncLayout.devices), withIntermediateDirectories: true)
            try? FileManager.default.createDirectory(at: url.appendingPathComponent(SyncLayout.content), withIntermediateDirectories: true)
            let keyring = readKeyring()
            keyringExists = keyring != nil
            guard let keyring, let stored = Keychain.loadKey(), SyncCrypto.keyID(for: stored) == keyring.keyID else {
                key = nil
                status = .needsPassphrase
                return
            }
            key = stored
            watch()
            pull()
        }
    }

    /// Checks the folder and keyring without turning anything on, for the setup sheet.
    func probe() {
        io.async {
            let located = Self.locateFolder()
            var exists = false
            if case .success(let url) = located {
                exists = FileManager.default.fileExists(atPath: url.appendingPathComponent(SyncLayout.keyring).path)
                    || FileManager.default.fileExists(atPath: url.appendingPathComponent("." + SyncLayout.keyring + ".icloud").path)
                if !exists { try? FileManager.default.startDownloadingUbiquitousItem(at: url.appendingPathComponent(SyncLayout.keyring)) }
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.keyringExists = exists
                    if case .failure(let f) = located { self.status = .unavailable(f.message) }
                }
            }
        }
    }

    /// Turns sync on with a passphrase: starts a new encrypted sync set, or joins the one
    /// another Mac started. Throws if the passphrase doesn't match the existing set.
    func setUp(passphrase: String) async throws {
        let located = await withCheckedContinuation { c in io.async { c.resume(returning: Self.locateFolder()) } }
        let url: URL
        switch located {
        case .success(let found): url = found
        case .failure(let failure): throw Bridge.Failure(failure.message)
        }
        folder = url
        try FileManager.default.createDirectory(at: url.appendingPathComponent(SyncLayout.devices), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: url.appendingPathComponent(SyncLayout.content), withIntermediateDirectories: true)
        let dataKey: SymmetricKey
        if let keyring = readKeyring() {
            dataKey = try await Task.detached { try SyncCrypto.unwrap(keyring, passphrase: passphrase) }.value
        } else {
            let (keyring, fresh) = try await Task.detached { try SyncCrypto.createKeyring(passphrase: passphrase) }.value
            try writeKeyring(keyring)
            dataKey = fresh
        }
        Keychain.saveKey(dataKey)
        key = dataKey
        keyringExists = true
        enabled = true
        watch()
        pull()
        uploadAllContent()
    }

    func changePassphrase(to passphrase: String) async throws {
        guard let key else { throw SyncCrypto.CryptoError.wrongPassphrase }
        let keyring = try await Task.detached { try SyncCrypto.wrap(key, passphrase: passphrase) }.value
        try writeKeyring(keyring)
    }

    func turnOff() {
        enabled = false
        stopWatching()
        // This Mac's snapshot goes, so the others stop counting it; the key stays in the
        // keychain for turning sync back on.
        if let file = ownSnapshotURL { try? FileManager.default.removeItem(at: file) }
        status = .off
        devices = []
    }

    /// Removes everything PasteLens keeps in iCloud, for every Mac. Other Macs will need a new passphrase.
    func deleteCloudData() {
        let target = folder
        turnOff()
        Keychain.deleteKey()
        key = nil
        keyringExists = false
        if let target { try? FileManager.default.removeItem(at: target) }
    }

    private func watch() {
        stopWatching()
        pullTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            MainActor.assumeIsolated { SyncEngine.shared.pull() }
        }
        guard let devices = folder?.appendingPathComponent(SyncLayout.devices) else { return }
        let fd = open(devices.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .extend], queue: .main)
        source.setEventHandler {
            MainActor.assumeIsolated { SyncEngine.shared.schedulePull() }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        watcher = source
    }

    private func stopWatching() {
        pullTimer?.invalidate()
        pullTimer = nil
        watcher?.cancel()
        watcher = nil
    }

    @ObservationIgnored private var pullScheduled = false
    private func schedulePull() {
        guard !pullScheduled else { return }
        pullScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            MainActor.assumeIsolated {
                self.pullScheduled = false
                self.pull()
            }
        }
    }

    // MARK: Local changes

    func libraryChanged() {
        guard enabled, key != nil else { return }
        guard !publishScheduled else { return }
        publishScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            MainActor.assumeIsolated {
                self.publishScheduled = false
                self.publish()
            }
        }
    }

    func settingChanged(_ key: String) {
        guard !Preferences.shared.applyingRemote else { return }
        stamps[key] = Date()
        libraryChanged()
    }

    func contentAdded(_ id: UUID, replace: Bool = false) {
        guard enabled, key != nil, Preferences.shared.syncContents else { return }
        upload(id)
    }

    func contentDeleted(_ ids: [UUID]) {
        guard enabled, let folder else { return }
        io.async {
            let dir = folder.appendingPathComponent(SyncLayout.content)
            let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
            for id in ids {
                for name in names where name.hasPrefix(id.uuidString) || name.hasPrefix("." + id.uuidString) {
                    try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
                }
            }
        }
    }

    // MARK: Files

    private var ownSnapshotURL: URL? {
        folder?.appendingPathComponent(SyncLayout.devices).appendingPathComponent("\(DeviceIdentity.id).\(SyncLayout.snapshotExtension)")
    }

    private func contentURL(for clip: Clipping) -> URL? {
        folder?.appendingPathComponent(SyncLayout.content)
            .appendingPathComponent("\(clip.id.uuidString)-\(clip.contentHash.prefix(12)).\(SyncLayout.contentExtension)")
    }

    private func readKeyring() -> SyncCrypto.Keyring? {
        guard let url = folder?.appendingPathComponent(SyncLayout.keyring) else { return nil }
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? SyncMerge.decode(SyncCrypto.Keyring.self, from: data)
    }

    private func writeKeyring(_ keyring: SyncCrypto.Keyring) throws {
        guard let url = folder?.appendingPathComponent(SyncLayout.keyring) else { return }
        try SyncMerge.encode(keyring).write(to: url, options: .atomic)
    }

    private func settingRecords() -> [SyncRecord] {
        let defaults = UserDefaults.standard
        let stamps = self.stamps
        return Preferences.syncedKeys.compactMap { key in
            guard let value = defaults.object(forKey: key),
                  let payload = try? PropertyListSerialization.data(fromPropertyList: ["v": value], format: .binary, options: 0) else { return nil }
            // Never-changed settings carry the oldest possible date, so any real choice wins.
            return SyncRecord(kind: .setting, id: key, updatedAt: stamps[key] ?? Date(timeIntervalSince1970: 0), payload: payload)
        }
    }

    private func publish() {
        guard enabled, let key, let url = ownSnapshotURL else { return }
        var library = ClipStore.shared.library
        if !Preferences.shared.syncContents { library.clippings = [] }
        let records = SyncMerge.records(for: library, settings: settingRecords(),
                                        maxClipBytes: Int(Preferences.shared.syncMaxClipMB * 1_048_576))
        let snapshot = DeviceSnapshot(deviceID: DeviceIdentity.id, deviceName: DeviceIdentity.name, appVersion: AppInfo.version, records: records)
        io.async {
            do {
                let sealed = try SyncCrypto.seal(SyncMerge.encode(snapshot), using: key)
                try sealed.write(to: url, options: .atomic)
                DispatchQueue.main.async { MainActor.assumeIsolated { SyncEngine.shared.lastSync = Date() } }
            } catch {
                DispatchQueue.main.async { MainActor.assumeIsolated { SyncEngine.shared.status = .failed("Couldn't write to iCloud Drive: \(error.localizedDescription)") } }
            }
        }
    }

    /// Reads every other Mac's snapshot and merges what's newer.
    func pull() {
        guard enabled, let key, let folder else { return }
        if case .needsPassphrase = status { return }
        status = .syncing
        let own = DeviceIdentity.id
        io.async {
            // A different keyring means the passphrase was reset on another Mac.
            if let data = try? Data(contentsOf: folder.appendingPathComponent(SyncLayout.keyring)),
               let keyring = try? SyncMerge.decode(SyncCrypto.Keyring.self, from: data),
               keyring.keyID != SyncCrypto.keyID(for: key) {
                DispatchQueue.main.async { MainActor.assumeIsolated { SyncEngine.shared.keyChangedElsewhere() } }
                return
            }
            let dir = folder.appendingPathComponent(SyncLayout.devices)
            let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
            var snapshots: [DeviceSnapshot] = []
            var unreadable = 0
            for name in names {
                // iCloud leaves ".Name.icloud" placeholders for files it hasn't downloaded yet.
                if name.hasPrefix("."), name.hasSuffix(".icloud") {
                    try? FileManager.default.startDownloadingUbiquitousItem(at: dir.appendingPathComponent(name))
                    continue
                }
                guard name.hasSuffix(SyncLayout.snapshotExtension), !name.hasPrefix(own) else { continue }
                guard let sealed = try? Data(contentsOf: dir.appendingPathComponent(name)) else { continue }
                do {
                    snapshots.append(try SyncMerge.decode(DeviceSnapshot.self, from: SyncCrypto.open(sealed, using: key)))
                } catch {
                    unreadable += 1
                }
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { SyncEngine.shared.merge(snapshots, unreadable: unreadable) }
            }
        }
    }

    private func keyChangedElsewhere() {
        Keychain.deleteKey()
        key = nil
        stopWatching()
        status = .needsPassphrase
    }

    private func merge(_ snapshots: [DeviceSnapshot], unreadable: Int) {
        devices = snapshots.map { Device(id: $0.deviceID, name: $0.deviceName, lastSeen: $0.writtenAt, appVersion: $0.appVersion) }
            .sorted { $0.name < $1.name }
        var library = ClipStore.shared.library
        let outcome = SyncMerge.merge(snapshots, into: &library, localSettings: stamps)
        if outcome.changed {
            ClipStore.shared.applyMerged(library, removed: outcome.removedClippings)
            HotKeyCenter.shared.apply()
        }
        if !outcome.settings.isEmpty { apply(outcome.settings) }
        for id in outcome.arrivedClippings where !ClipStore.shared.hasContent(id) { missingContent.insert(id) }
        fetchMissingContent()
        lastSync = Date()
        status = unreadable > 0 ? .failed("\(unreadable) Mac\(unreadable == 1 ? "'s" : "s'") data couldn't be decrypted.") : .idle
        // Publish after merging so the others see the combined view (and new tombstones).
        if outcome.changed || lastSeenSnapshots.isEmpty { libraryChanged() }
        for s in snapshots { lastSeenSnapshots[s.deviceID] = s.writtenAt }
    }

    private func apply(_ records: [SyncRecord]) {
        let defaults = UserDefaults.standard
        var stamps = self.stamps
        for record in records {
            guard let payload = record.payload,
                  let dict = try? PropertyListSerialization.propertyList(from: payload, format: nil) as? [String: Any],
                  let value = dict["v"] else { continue }
            defaults.set(value, forKey: record.id)
            stamps[record.id] = record.updatedAt
        }
        self.stamps = stamps
        Preferences.shared.reloadFromDefaults()
        #if !APPSTORE
        Preferences.shared.applyingRemote = true
        AutoUpdater.shared.reloadPolicy()
        Preferences.shared.applyingRemote = false
        #endif
    }

    // MARK: Content transfer

    private func upload(_ id: UUID) {
        guard let key, let clip = ClipStore.shared.clip(id), SyncMerge.syncable(clip, maxClipBytes: Int(Preferences.shared.syncMaxClipMB * 1_048_576)),
              let url = contentURL(for: clip), let content = ClipStore.shared.content(for: id), !uploads.contains(id) else { return }
        uploads.insert(id)
        pendingContent = uploads.count
        io.async {
            if !FileManager.default.fileExists(atPath: url.path) {
                let encoder = PropertyListEncoder()
                encoder.outputFormat = .binary
                if let plain = try? encoder.encode(content), let sealed = try? SyncCrypto.seal(plain, using: key) {
                    try? sealed.write(to: url, options: .atomic)
                }
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    SyncEngine.shared.uploads.remove(id)
                    SyncEngine.shared.pendingContent = SyncEngine.shared.uploads.count
                }
            }
        }
    }

    /// Makes sure every syncable clipping's content is in iCloud (after setup, or turning content sync on).
    func uploadAllContent() {
        guard enabled, key != nil, Preferences.shared.syncContents, let folder else { return }
        let existing = Set((try? FileManager.default.contentsOfDirectory(atPath: folder.appendingPathComponent(SyncLayout.content).path)) ?? [])
        for clip in ClipStore.shared.library.clippings where !clip.sensitive {
            let name = "\(clip.id.uuidString)-\(clip.contentHash.prefix(12)).\(SyncLayout.contentExtension)"
            if !existing.contains(name) && !existing.contains(".\(name).icloud") { upload(clip.id) }
        }
    }

    private func fetchMissingContent() {
        guard let key, !missingContent.isEmpty else { return }
        let wanted = missingContent.compactMap { ClipStore.shared.clip($0) }.compactMap { clip in contentURL(for: clip).map { (clip.id, $0) } }
        missingContent = Set(missingContent.filter { id in ClipStore.shared.clip(id) != nil })
        io.async {
            var fetched: [(UUID, ClipContent)] = []
            for (id, url) in wanted {
                guard let sealed = try? Data(contentsOf: url) else {
                    try? FileManager.default.startDownloadingUbiquitousItem(at: url)
                    continue
                }
                if let plain = try? SyncCrypto.open(sealed, using: key),
                   let content = try? PropertyListDecoder().decode(ClipContent.self, from: plain) {
                    fetched.append((id, content))
                }
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    for (id, content) in fetched {
                        ClipStore.shared.storeContent(content, for: id)
                        SyncEngine.shared.missingContent.remove(id)
                    }
                    if !fetched.isEmpty { ClipStore.shared.changed(syncNow: false) }
                    SyncEngine.shared.pendingContent = SyncEngine.shared.missingContent.count + SyncEngine.shared.uploads.count
                }
            }
        }
    }
}

/// The sync data key, kept in this Mac's login keychain.
enum Keychain {
    static let service = "com.smanke.PasteLens.sync"
    /// Test runs pointed at a scratch sync folder keep their key apart from the real one.
    static let account = ProcessInfo.processInfo.environment["PASTELENS_SYNC_FOLDER"] == nil ? "data-key" : "data-key-test"

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
