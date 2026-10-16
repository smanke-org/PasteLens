import Foundation
import Observation
import PasteLensKit

/// Counts of copies and pastes per day, for Settings › Activity.
///
/// Kept apart from History on purpose: History is trimmed and can be cleared, and the graph
/// should still show how much PasteLens was used. Only numbers are stored, in the database's
/// `kv` table. With sync on, they travel to the other Macs inside this Mac's encrypted
/// Device record, so each Mac's counts can be told apart on the graph.
@Observable
@MainActor
final class ActivityStore {
    static let shared = ActivityStore()

    private(set) var log = ActivityLog()

    private static let key = "activity.log"

    private init() {
        if let data = ClipStore.shared.db.data(forKey: Self.key), let saved = try? JSONDecoder().decode(ActivityLog.self, from: data) {
            log = saved
        } else {
            seedFromHistory()
        }
    }

    func record(_ kind: ActivityKind, at date: Date = Date()) {
        log.record(kind, at: date)
        log.trim()
        save()
        SyncEngine.shared.activityChanged()
    }

    /// The first time, start the copy count from the clippings this Mac already copied.
    /// Pastes were never recorded before, so they start at zero.
    private func seedFromHistory() {
        for (origin, date) in ClipStore.shared.db.copyOrigins() where origin == DeviceIdentity.id {
            log.record(.copy, at: date)
        }
        log.trim()
        save()
    }

    private func save() {
        do {
            try ClipStore.shared.db.set(try JSONEncoder().encode(log), forKey: Self.key)
        } catch {
            NSLog("PasteLens: couldn't save activity: \(error.localizedDescription)")
        }
    }
}
