import Foundation
import SQLite3

/// Reads data exported or kept by Pastebot so people can bring it along: its filter files
/// (.pastebotfilter, a property list) and its clipping database (SQLite).
public enum PastebotImport {
    public struct FilterResult: Sendable {
        public var filter: Filter
        /// Steps that had no PasteLens equivalent and were left out.
        public var skipped: [String]
    }

    static let prefix = "PTHPastebotFilterOperationDescriptor"

    public static func filter(fromFile url: URL) throws -> FilterResult {
        let data = try Data(contentsOf: url)
        guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw FilterError("\(url.lastPathComponent) isn't a filter file.")
        }
        let name = plist["name"] as? String ?? url.deletingPathExtension().lastPathComponent
        return filter(fromPlist: plist, fallbackName: name)
    }

    public static func filter(fromPlist plist: [String: Any], fallbackName: String) -> FilterResult {
        var steps: [FilterStep] = []
        var skipped: [String] = []
        for op in plist["operationDescriptors"] as? [[String: Any]] ?? [] {
            let className = (op["className"] as? String ?? "").replacingOccurrences(of: prefix, with: "")
            if let step = step(className, op) { steps.append(step) } else if className != "NoOperationFilter" { skipped.append(className) }
        }
        var filter = Filter(name: plist["name"] as? String ?? fallbackName, details: plist["filterDescription"] as? String ?? "",
                            group: "Imported", steps: steps)
        if filter.steps.isEmpty { filter.details = "Nothing in this filter could be converted." }
        return FilterResult(filter: filter, skipped: skipped)
    }

    static func step(_ className: String, _ op: [String: Any]) -> FilterStep? {
        func int(_ key: String) -> Int { (op[key] as? NSNumber)?.intValue ?? 0 }
        func bool(_ key: String) -> Bool { (op[key] as? NSNumber)?.boolValue ?? false }
        func str(_ key: String) -> String { op[key] as? String ?? "" }
        switch className {
        case "Case":
            let map: [Int: FilterStep.CaseStyle] = [0: .upper, 1: .lower, 2: .title, 3: .sentence, 4: .snake, 5: .camel]
            return FilterStep(.changeCase, choice: (map[int("caseType")] ?? .lower).rawValue)
        case "EncodeBase64": return FilterStep(.encode, choice: FilterStep.Encoding.base64.rawValue, flag1: bool("decode"))
        case "EncodeHex": return FilterStep(.encode, choice: FilterStep.Encoding.hex.rawValue, flag1: bool("decode"))
        case "EncodeHTMLEntity": return FilterStep(.encode, choice: FilterStep.Encoding.htmlEntities.rawValue, flag1: bool("decode"))
        case "EncodeURL": return FilterStep(.encode, choice: FilterStep.Encoding.url.rawValue, flag1: bool("decode"))
        case "Find":
            // Their find fields hold real newlines and backslashes; ours read \n and \\ as escapes.
            let regex = int("findType") & 1024 != 0
            let find = regex ? str("findString") : str("findString").replacingOccurrences(of: "\\", with: "\\\\")
            return FilterStep(.findReplace, text1: find, text2: escapeBackslashes(str("replaceString")), flag1: regex, flag2: bool("caseSensitive"))
        case "Extract":
            let map: [Int: FilterStep.ExtractKind] = [0: .urls, 1: .emails, 2: .phoneNumbers, 3: .regex]
            return FilterStep(.extract, choice: (map[int("type")] ?? .urls).rawValue, text1: str("pattern"), text2: str("template"))
        case "LineQuote":
            return FilterStep(.quote, text1: escapeBackslashes(str("prefixString")), text2: escapeBackslashes(str("suffixString")), flag1: bool("eachLine"))
        case "Lines":
            let map: [Int: FilterStep.LinesOp] = [0: .trim, 1: .removeEmpty, 2: .removeDuplicates, 6: .join]
            guard let lines = map[int("linesType")] else { return nil }
            return FilterStep(.lines, choice: lines.rawValue, text1: str("joinSeparator"))
        case "LineEnds":
            return FilterStep(.lineEnds, choice: min(max(int("lineEndingType"), 0), 2))
        case "LineWrap":
            let width = int("wrapLength")
            return FilterStep(.wrap, flag1: width == 0, number: width)
        case "PlainText": return FilterStep(.plainText)
        case "SmartPunctuation": return FilterStep(.punctuation, flag1: bool("stupefy"))
        case "Sort": return FilterStep(.sort, choice: bool("descending") ? FilterStep.SortOrder.descending.rawValue : 0, flag1: bool("caseSensitive"))
        case "Translate": return FilterStep(.translate, text1: str("targetLanguage").isEmpty ? "en" : str("targetLanguage"))
        case "Shell": return FilterStep(.shell, text1: str("scriptString"))
        case "ExternalShell": return FilterStep(.appScript, text1: str("scriptName"))
        default: return nil
        }
    }

    static func escapeBackslashes(_ s: String) -> String { s.replacingOccurrences(of: "\\", with: "\\\\") }

    // MARK: - Clipping database

    public struct ImportedClip: Sendable {
        public var uuid: String
        public var createdAt: Date
        public var copiedAt: Date
        public var title: String?
        public var sourceName: String?
        public var sourceBundleID: String?
        public var content: ClipContent
    }

    public struct DatabaseResult: Sendable {
        public var clips: [ImportedClip]
        /// Custom pastebins: name and the uuids of clippings saved in it.
        public var pastebins: [(name: String, uuids: [String])]
        public var databases: [URL]
    }

    /// Finds SQLite databases under `folder` that have Pastebot's tables and reads them all.
    public static func clippings(under folder: URL, limit: Int = 50_000) throws -> DatabaseResult {
        var result = DatabaseResult(clips: [], pastebins: [], databases: [])
        var seen = Set<String>()
        let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey])?
            .compactMap { $0 as? URL } ?? []
        for file in files where ["sqlite", "db", "sqlite3", "pastebot"].contains(file.pathExtension.lowercased()) || file.pathExtension.isEmpty {
            guard let db = try? Database(file), db.hasTable("entries"), db.hasTable("types_data") else { continue }
            result.databases.append(file)
            for clip in db.readClips(limit: limit) where seen.insert(clip.uuid).inserted { result.clips.append(clip) }
            result.pastebins.append(contentsOf: db.readPastebins())
        }
        if result.databases.isEmpty { throw FilterError("No Pastebot clipping database was found in that folder.") }
        return result
    }

    final class Database {
        private var handle: OpaquePointer?

        init(_ url: URL) throws {
            guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
                sqlite3_close(handle)
                throw FilterError("Can't open \(url.lastPathComponent)")
            }
        }

        deinit { sqlite3_close(handle) }

        func hasTable(_ name: String) -> Bool {
            !rows("SELECT name FROM sqlite_master WHERE type='table' AND name='\(name)'").isEmpty
        }

        func columns(_ table: String) -> Set<String> {
            Set(rows("PRAGMA table_info(\(table))").compactMap { $0["name"] as? String })
        }

        func rows(_ sql: String) -> [[String: Any]] {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            var out: [[String: Any]] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                var row: [String: Any] = [:]
                for i in 0..<sqlite3_column_count(stmt) {
                    let name = String(cString: sqlite3_column_name(stmt, i))
                    switch sqlite3_column_type(stmt, i) {
                    case SQLITE_INTEGER: row[name] = sqlite3_column_int64(stmt, i)
                    case SQLITE_FLOAT: row[name] = sqlite3_column_double(stmt, i)
                    case SQLITE_TEXT: row[name] = String(cString: sqlite3_column_text(stmt, i))
                    case SQLITE_BLOB:
                        let count = Int(sqlite3_column_bytes(stmt, i))
                        row[name] = count > 0 ? Data(bytes: sqlite3_column_blob(stmt, i), count: count) : Data()
                    default: break
                    }
                }
                out.append(row)
            }
            return out
        }

        static func date(_ value: Any?) -> Date? {
            let seconds: Double
            switch value {
            case let n as Int64: seconds = Double(n)
            case let d as Double: seconds = d
            case let s as String:
                if let d = Double(s) { seconds = d } else { return ISO8601DateFormatter().date(from: s) }
            default: return nil
            }
            // Small numbers count from 2001 (Apple's reference date), large ones from 1970.
            return seconds < 900_000_000 ? Date(timeIntervalSinceReferenceDate: seconds) : Date(timeIntervalSince1970: seconds)
        }

        func readClips(limit: Int) -> [ImportedClip] {
            let cols = columns("entries")
            let order = cols.contains("copied_at") ? "COALESCE(copied_at, created_at)" : (cols.contains("position") ? "position" : "created_at")
            let entries = rows("SELECT * FROM entries ORDER BY \(order) DESC LIMIT \(limit)")
            var reps: [String: [ClipRepresentation]] = [:]
            for row in rows("SELECT entry_uuid, type, data FROM types_data WHERE item_index = 0 ORDER BY id") {
                guard let uuid = row["entry_uuid"] as? String, let type = row["type"] as? String else { continue }
                let data = row["data"] as? Data ?? (row["data"] as? String).map { Data($0.utf8) } ?? Data()
                guard !data.isEmpty else { continue }
                reps[uuid, default: []].append(ClipRepresentation(type: type, data: data))
            }
            return entries.compactMap { row in
                guard let uuid = row["uuid"] as? String, let representations = reps[uuid], !representations.isEmpty else { return nil }
                let created = Self.date(row["created_at"]) ?? Date()
                return ImportedClip(uuid: uuid, createdAt: created, copiedAt: Self.date(row["copied_at"]) ?? created,
                                    title: (row["title"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                                    sourceName: row["source_name"] as? String, sourceBundleID: row["source_bundle_identifier"] as? String,
                                    content: ClipContent(representations: representations))
            }
        }

        func readPastebins() -> [(name: String, uuids: [String])] {
            guard hasTable("pasteboard") else { return [] }
            let uuidPattern = try! NSRegularExpression(pattern: "[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}")
            return rows("SELECT name, entry_uuids FROM pasteboard").compactMap { row in
                guard let name = row["name"] as? String, !name.isEmpty else { return nil }
                let raw: String
                if let s = row["entry_uuids"] as? String { raw = s } else if let d = row["entry_uuids"] as? Data {
                    raw = String(decoding: d, as: UTF8.self)
                } else { raw = "" }
                let uuids = uuidPattern.matches(in: raw, range: NSRange(raw.startIndex..., in: raw))
                    .compactMap { Range($0.range, in: raw).map { String(raw[$0]) } }
                return (name, uuids)
            }
        }
    }
}
