import Foundation
import Testing
@testable import PasteLensKit

/// Times database operations on a copy of a real database: PASTELENS_PROFILE_DB=/path swift test --filter ProfileTests
@Suite struct ProfileTests {
    @Test func profile() throws {
        guard let path = ProcessInfo.processInfo.environment["PASTELENS_PROFILE_DB"] else { return }
        func time(_ label: String, _ work: () throws -> Void) rethrows {
            let t = Date(); try work(); print("PROFILE \(label): \(String(format: "%.1f", Date().timeIntervalSince(t) * 1000)) ms")
        }
        var db: ClipDatabase!
        try time("open") { db = try ClipDatabase(url: URL(fileURLWithPath: path)) }
        time("count") { _ = db.count(.history) }
        var clip: Clipping!
        time("page 1") { clip = db.page(.history, limit: 1).first }
        time("clip by id") { _ = db.clip(clip.id) }
        clip.note = "x"
        try time("upsert one") { try db.upsert(clip) }
        try time("upsert one again") { try db.upsert(clip) }
        time("expired secrets") { _ = db.expiredSecrets() }
        time("historyClip hash") { _ = db.historyClip(withHash: clip.contentHash) }
        time("search common") { _ = db.search("budget friday", in: .history, limit: 300) }
        time("search typo") { _ = db.search("harbr", in: .history, limit: 300) }
        try time("kv set") { try db.set(Data(count: 10), forKey: "x") }
    }
}
