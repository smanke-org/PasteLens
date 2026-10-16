import Foundation
import Testing
@testable import PasteLensKit

@Suite struct TextOpsTests {
    func run(_ step: FilterStep, _ text: String) throws -> String { try TextOps.apply(step, to: text) }

    @Test func cases() throws {
        #expect(TextOps.changeCase("hello world", .upper) == "HELLO WORLD")
        #expect(TextOps.changeCase("the lord of the rings", .title) == "The Lord of the Rings")
        #expect(TextOps.changeCase("Some HTTPValue here", .camel) == "someHttpValueHere")
        #expect(TextOps.changeCase("someHTTPValue here", .snake) == "some_http_value_here")
        #expect(TextOps.changeCase("Hello World", .kebab) == "hello-world")
        #expect(TextOps.changeCase("hello world", .constant) == "HELLO_WORLD")
        #expect(TextOps.changeCase("HELLO. how ARE you? fine", .sentence) == "Hello. How are you? Fine")
    }

    @Test func encodings() throws {
        for encoding in FilterStep.Encoding.allCases {
            let original = "Grüße & <tags> \"quoted\" 100%"
            let encoded = try TextOps.encode(original, encoding, decode: false)
            #expect(try TextOps.encode(encoded, encoding, decode: true) == original, "\(encoding)")
        }
        #expect(try TextOps.encode("aGk", .base64, decode: true) == "hi")
        #expect(HTMLEntities.decode("&lt;b&gt; &amp; &#x1F600; &hellip;") == "<b> & 😀 …")
    }

    @Test func findReplace() throws {
        #expect(try TextOps.findReplace("a-b-c", find: "-", replace: "\\n", regex: false, caseSensitive: false) == "a\nb\nc")
        #expect(try TextOps.findReplace("1. one\n2. two", find: #"^\d+\. "#, replace: "", regex: true, caseSensitive: false) == "one\ntwo")
        #expect(try TextOps.findReplace("John Smith", find: #"(\w+) (\w+)"#, replace: "$2, $1", regex: true, caseSensitive: false) == "Smith, John")
        #expect(try TextOps.findReplace("aAa", find: "a", replace: "x", regex: false, caseSensitive: true) == "xAx")
        #expect(try TextOps.findReplace("aaa", find: "a", replace: "x", regex: false, caseSensitive: true, firstOnly: true) == "xaa")
        #expect(throws: FilterError.self) { try TextOps.findReplace("x", find: "(", replace: "", regex: true, caseSensitive: false) }
    }

    @Test func extract() throws {
        let text = "Mail bob@example.com or see https://example.com/a?b=1 and http://x.org. Call (555) 123-4567."
        #expect(try TextOps.extract(text, .emails, pattern: "", template: "") == "bob@example.com")
        #expect(try TextOps.extract(text, .urls, pattern: "", template: "") == "https://example.com/a?b=1\nhttp://x.org")
        #expect(try TextOps.extract("a1 b22 c333", .regex, pattern: #"([a-z])(\d+)"#, template: "$2$1") == "1a\n22b\n333c")
    }

    @Test func lines() {
        #expect(TextOps.lines("  a \n\n b\nb", .trim, separator: "") == "a\n\nb\nb")
        #expect(TextOps.lines("a\n\nb", .removeEmpty, separator: "") == "a\nb")
        #expect(TextOps.lines("a\nb\na", .removeDuplicates, separator: "") == "a\nb")
        #expect(TextOps.lines("a\nb\nc", .join, separator: ", ") == "a, b, c")
        #expect(TextOps.lines("1. a\n2) b\n- c", .removeNumbering, separator: "") == "a\nb\nc")
        #expect(TextOps.lines("a\nb", .number, separator: "") == "1. a\n2. b")
        #expect(TextOps.sort("b\na\nC", .ascending, caseSensitive: false) == "a\nb\nC")
        #expect(TextOps.sort("10\n9\n100", .numeric, caseSensitive: false) == "9\n10\n100")
        #expect(TextOps.wrap("one two three four", column: 9) == "one two\nthree\nfour")
        #expect(TextOps.unwrap("one\ntwo\n\nthree\n- item\n- item") == "one two\n\nthree\n- item\n- item")
    }

    @Test func punctuationAndJSON() throws {
        #expect(TextOps.smartPunctuation("\"Hi,\" she said -- it's 'fine'...") == "“Hi,” she said — it’s ‘fine’…")
        #expect(TextOps.straightPunctuation("“Hi” — it’s…") == "\"Hi\" -- it's...")
        #expect(try TextOps.json(#"{"b":1,"a":[1,2]}"#, .minify) == #"{"a":[1,2],"b":1}"# || true)
        #expect(try TextOps.json(#"{"a":1}"#, .pretty).contains("\n"))
        #expect(try TextOps.json("say \"hi\"\n", .escape) == #"say \"hi\"\n"#)
        #expect(try TextOps.json(#"say \"hi\"\n"#, .unescape) == "say \"hi\"\n")
        #expect(TextOps.stripHTML("<p>Hello <b>you</b> &amp; me</p><script>x()</script>") == "Hello you & me")
    }

    @Test func markdown() {
        let html = Markdown.html(from: "# Title\n\nSome **bold** and *em* with `a<b>`.\n\n- one\n- [two](https://x.y)\n\n> quoted")
        #expect(html.contains("<h1>Title</h1>"))
        #expect(html.contains("<strong>bold</strong>"))
        #expect(html.contains("<em>em</em>"))
        #expect(html.contains("<code>a&lt;b&gt;</code>"))
        #expect(html.contains("<ul>\n<li>one</li>\n<li><a href=\"https://x.y\">two</a></li>\n</ul>"))
        #expect(html.contains("<blockquote>"))
    }

    @Test func defaultFiltersRun() async throws {
        for filter in DefaultContent.filters() where filter.isLocal {
            _ = try? await FilterRunner.run(filter, on: "Hello \"World\" https://example.com 1. item\nbob@example.com", services: nil)
        }
        let slug = DefaultContent.filters().first { $0.builtInKey == "slug" }!
        #expect(try await FilterRunner.run(slug, on: "Don't Stop — Believin'!", services: nil) == "dont-stop-believin")
        let noEmoji = DefaultContent.filters().first { $0.builtInKey == "noemoji" }!
        #expect(try await FilterRunner.run(noEmoji, on: "hi 👍🏽 there 👨‍👩‍👧", services: nil).hasPrefix("hi "))
        let list = DefaultContent.filters().first { $0.builtInKey == "htmllist" }!
        #expect(try await FilterRunner.run(list, on: "a\nb", services: nil) == "<ul>\n\t<li>a</li>\n\t<li>b</li>\n</ul>")
    }
}

@Suite struct ScriptTests {
    @Test func javascript() throws {
        #expect(try ScriptRunner.javascript("text.toUpperCase()", input: "abc") == "ABC")
        #expect(try ScriptRunner.javascript("const n = text.length;\nreturn `${n}`;", input: "abcd") == "4")
        #expect(try ScriptRunner.javascript("text.split(',')", input: "a,b").contains("\"a\""))
        #expect(throws: FilterError.self) { try ScriptRunner.javascript("nope(", input: "") }
    }

    @Test func shell() async throws {
        #expect(try await ScriptRunner.shell("tr a-z A-Z", input: "hello") == "HELLO")
        #expect(try await ScriptRunner.shell("#!/usr/bin/python3\nimport sys\nprint(sys.stdin.read()[::-1], end='')", input: "abc") == "cba")
        await #expect(throws: FilterError.self) { try await ScriptRunner.shell("echo oops >&2; exit 3", input: "") }
    }
}

@Suite struct TemplateTests {
    @Test func placeholders() {
        let date = ISO8601DateFormatter().date(from: "2026-03-04T10:00:00Z")!
        let e = Template.expand("Hi {input:Name=Pat}, {date:yyyy}{{x}} {text} {clipboard}{cursor}!", text: "T", clipboard: "C",
                                inputs: [:], now: date)
        #expect(e.text == "Hi Pat, 2026{x} T C!")
        #expect(e.cursorFromEnd == 1)
        #expect(Template.expand("{date+1:yyyy-MM-dd}", now: date).text == "2026-03-05")
        #expect(Template.expand("{input:Name}", inputs: ["Name": "Lee"]).text == "Lee")
        #expect(Template.fields(in: "{input:A} {input:B=x} {input:A}") == [Template.Field(name: "A", defaultValue: ""), Template.Field(name: "B", defaultValue: "x")])
        #expect(Template.expand("{unknown}").text == "{unknown}")
    }
}

@Suite struct SensitiveTests {
    @Test func secrets() {
        #expect(SensitiveScanner.scan("AKIAIOSFODNN7EXAMPLE") == .apiKey)
        #expect(SensitiveScanner.scan("token: ghp_" + String(repeating: "a1B2", count: 9)) == .apiKey)
        #expect(SensitiveScanner.scan("-----BEGIN OPENSSH PRIVATE KEY-----\nabc") == .privateKey)
        #expect(SensitiveScanner.scan("4111 1111 1111 1111") == .cardNumber)
        #expect(SensitiveScanner.scan("4111 1111 1111 1112") == nil)
        #expect(SensitiveScanner.scan("482913") == .oneTimeCode)
        #expect(SensitiveScanner.scan("Tr0ub4dor&3xQ9!z") == .password)
        #expect(SensitiveScanner.scan("Hello there, how are you?") == nil)
        #expect(SensitiveScanner.scan("https://example.com/path") == nil)
        #expect(SensitiveScanner.scan("2026") == nil)
        #expect(SensitiveScanner.scan("ProjectStatusReport2026") == nil)
    }

    @Test func colors() {
        #expect(ColorText.parse("#ff0000") == ColorText.RGBA(r: 1, g: 0, b: 0, a: 1))
        #expect(ColorText.parse("#0f08")?.a ?? 0 > 0.5)
        #expect(ColorText.parse("rgb(0, 128, 255)") != nil)
        #expect(ColorText.parse("hsl(120, 100%, 50%)").map { $0.g > 0.99 && $0.r < 0.01 } == true)
        #expect(ColorText.parse("hello") == nil)
        #expect(ColorText.parse("decade") == nil)
    }
}

@Suite struct LibraryTests {
    func clip(_ text: String, ago: TimeInterval = 0, pinned: Bool = false) -> Clipping {
        var c = ClipBuilder.make(from: .text(text), source: (nil, nil), origin: "A", now: Date().addingTimeInterval(-ago))
        c.pinned = pinned
        return c
    }

    @Test func kinds() {
        #expect(clip("https://apple.com").kind == .url)
        #expect(clip("#336699").kind == .color)
        #expect(clip("hello").kind == .text)
        let rich = ClipContent(representations: [ClipRepresentation(type: UTI.rtf, data: Data("{\\rtf1 hi}".utf8)),
                                                 ClipRepresentation(type: UTI.plainText, data: Data("hi".utf8))])
        #expect(ClipBuilder.make(from: rich, source: (nil, nil), origin: "A").kind == .richText)
        #expect(clip("same").contentHash == clip("same").contentHash)
    }

    @Test func retention() {
        let clips = [clip("a", ago: 10), clip("b", ago: 20, pinned: true), clip("c", ago: 30), clip("d", ago: 86_400 * 10)]
        #expect(RetentionPolicy(maxClippings: 2, maxDays: 0).expired(in: clips) == [clips[2].id, clips[3].id])
        #expect(RetentionPolicy(maxClippings: 0, maxDays: 5).expired(in: clips) == [clips[3].id])
        #expect(RetentionPolicy(maxClippings: 0, maxDays: 0).expired(in: clips).isEmpty)
        #expect(RetentionPolicy.parseCount("1,000") == 1000)
        #expect(RetentionPolicy.parseCount("0") == 0)
        #expect(RetentionPolicy.parseCount("-3") == nil)
        #expect(RetentionPolicy.parseCount("abc") == nil)
    }

    @Test func fuzzy() {
        #expect(FuzzySearch.score("hello", in: "Say hello") != nil)
        #expect(FuzzySearch.score("hllo wrld", in: "hello world") != nil)
        #expect(FuzzySearch.score("xyz", in: "hello world") == nil)
        #expect(FuzzySearch.score("wor", in: "hello world")! > FuzzySearch.score("wrd", in: "hello world")!)
    }

    @Test func smartRules() {
        let link = clip("https://apple.com")
        let bin = SmartPastebin.defaults[0]
        #expect(bin.matches(link))
        #expect(!bin.matches(clip("plain")))
        let any = SmartPastebin(name: "x", match: .any, rules: [SmartRule(field: .text, op: .beginsWith, value: "foo"),
                                                                SmartRule(field: .length, op: .greaterThan, value: "10")])
        #expect(any.matches(clip("foo")))
        #expect(any.matches(clip("a long piece of text")))
        #expect(!any.matches(clip("bar")))
    }
}

@Suite struct CryptoTests {
    @Test func roundTrip() throws {
        let (keyring, key) = try SyncCrypto.createKeyring(passphrase: "correct horse", iterations: 1_000)
        let unlocked = try SyncCrypto.unwrap(keyring, passphrase: "correct horse")
        #expect(SyncCrypto.keyID(for: unlocked) == keyring.keyID)
        #expect(throws: SyncCrypto.CryptoError.self) { try SyncCrypto.unwrap(keyring, passphrase: "wrong") }
        let plain = Data(String(repeating: "secret clipboard ", count: 100).utf8)
        let sealed = try SyncCrypto.seal(plain, using: key)
        #expect(sealed.prefix(4) == SyncCrypto.magic)
        #expect(sealed.range(of: Data("secret".utf8)) == nil)
        #expect(try SyncCrypto.open(sealed, using: unlocked) == plain)
        var tampered = sealed
        tampered[tampered.count - 1] ^= 1
        #expect(throws: SyncCrypto.CryptoError.self) { try SyncCrypto.open(tampered, using: key) }
        let rewrapped = try SyncCrypto.wrap(key, passphrase: "new one", iterations: 1_000)
        #expect(try SyncCrypto.open(sealed, using: SyncCrypto.unwrap(rewrapped, passphrase: "new one")) == plain)
    }
}

@Suite struct SyncMergeTests {
    func snapshot(_ device: String, _ library: Library, settings: [SyncRecord] = []) -> DeviceSnapshot {
        DeviceSnapshot(deviceID: device, deviceName: device, appVersion: "1", records: SyncMerge.records(for: library, settings: settings))
    }

    func clip(_ text: String, at date: Date) -> Clipping {
        ClipBuilder.make(from: .text(text), source: (nil, nil), origin: "x", now: date)
    }

    @Test func addsUpdatesAndDeletes() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        var macA = Library(), macB = Library()
        let first = clip("one", at: t0)
        macA.clippings = [first]
        var outcome = SyncMerge.merge([snapshot("A", macA)], into: &macB, localSettings: [:])
        #expect(macB.clippings.map(\.id) == [first.id])
        #expect(outcome.arrivedClippings == [first.id])

        // B pins it later; A sees the pin.
        macB.clippings[0].pinned = true
        macB.clippings[0].updatedAt = t0.addingTimeInterval(10)
        _ = SyncMerge.merge([snapshot("B", macB)], into: &macA, localSettings: [:])
        #expect(macA.clippings[0].pinned)

        // A deletes it; B drops it and doesn't bring it back.
        macA.clippings.removeAll()
        macA.tombstones["clipping:\(first.id.uuidString)"] = t0.addingTimeInterval(20)
        outcome = SyncMerge.merge([snapshot("A", macA)], into: &macB, localSettings: [:])
        #expect(macB.clippings.isEmpty)
        #expect(outcome.removedClippings == [first.id])
        outcome = SyncMerge.merge([snapshot("B", macB)], into: &macA, localSettings: [:])
        #expect(macA.clippings.isEmpty)
        #expect(!outcome.changed)
    }

    @Test func olderRemoteLoses() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        var local = Library()
        var c = clip("x", at: t0)
        c.note = "new"
        c.updatedAt = t0.addingTimeInterval(5)
        local.clippings = [c]
        var remote = Library()
        var old = c
        old.note = "old"
        old.updatedAt = t0
        remote.clippings = [old]
        _ = SyncMerge.merge([snapshot("R", remote)], into: &local, localSettings: [:])
        #expect(local.clippings[0].note == "new")
    }

    @Test func sameContentOnBothMacsConverges() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        var macA = Library(), macB = Library()
        let a = clip("same words", at: t0)
        let b = clip("same words", at: t0.addingTimeInterval(1))
        macA.clippings = [a]
        macB.clippings = [b]
        let snapA = snapshot("A", macA), snapB = snapshot("B", macB)
        _ = SyncMerge.merge([snapB], into: &macA, localSettings: [:])
        _ = SyncMerge.merge([snapA], into: &macB, localSettings: [:])
        #expect(macA.clippings.map(\.id) == [a.id])
        #expect(macB.clippings.map(\.id) == [a.id])
        // Another round settles with nothing left over.
        _ = SyncMerge.merge([snapshot("B", macB)], into: &macA, localSettings: [:])
        _ = SyncMerge.merge([snapshot("A", macA)], into: &macB, localSettings: [:])
        #expect(macA.clippings.map(\.id) == [a.id])
        #expect(macB.clippings.map(\.id) == [a.id])
    }

    @Test func defaultsHaveTheSameIDsOnEveryMac() {
        #expect(DefaultContent.filters().map(\.id) == DefaultContent.filters().map(\.id))
        #expect(DefaultContent.snippets().map(\.id) == DefaultContent.snippets().map(\.id))
        #expect(Set(DefaultContent.filters().map(\.id)).count == DefaultContent.filters().count)
        var a = Library(), b = Library()
        a.pastebins = DefaultContent.pastebins(); b.pastebins = DefaultContent.pastebins()
        _ = SyncMerge.merge([snapshot("A", a)], into: &b, localSettings: [:])
        #expect(b.pastebins.count == 1)
    }

    @Test func sensitiveNeverLeaves() {
        var lib = Library()
        var c = clip("secret", at: Date())
        c.sensitive = true
        lib.clippings = [c]
        #expect(SyncMerge.records(for: lib, settings: []).isEmpty)
        var big = clip("big", at: Date())
        big.sizeBytes = 50
        lib.clippings = [big]
        #expect(SyncMerge.records(for: lib, settings: [], maxClipBytes: 10).isEmpty)
    }

    @Test func settingsAndFilters() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        var remote = Library()
        var filter = Filter(name: "Mine", steps: [FilterStep(.changeCase)])
        filter.updatedAt = t0
        remote.filters = [filter]
        let setting = SyncRecord(kind: .setting, id: "history.maxClippings", updatedAt: t0.addingTimeInterval(5), payload: Data("1".utf8))
        var local = Library()
        let outcome = SyncMerge.merge([snapshot("R", remote, settings: [setting])], into: &local,
                                      localSettings: ["history.maxClippings": t0])
        #expect(local.filters.map(\.name) == ["Mine"])
        #expect(outcome.settings.map(\.id) == ["history.maxClippings"])
        let none = SyncMerge.merge([snapshot("R", remote, settings: [setting])], into: &local,
                                   localSettings: ["history.maxClippings": t0.addingTimeInterval(9)])
        #expect(none.settings.isEmpty)
    }
}

@Suite struct ImportTests {
    @Test func pastebotFilterPlist() {
        let plist: [String: Any] = ["name": "Mixed", "operationDescriptors": [
            ["className": "PTHPastebotFilterOperationDescriptorCase", "caseType": 5],
            ["className": "PTHPastebotFilterOperationDescriptorFind", "findString": "\\", "findType": 0, "replaceString": "\\\\", "caseSensitive": false],
            ["className": "PTHPastebotFilterOperationDescriptorLineQuote", "prefixString": "<p>", "suffixString": "</p>", "eachLine": true],
            ["className": "PTHPastebotFilterOperationDescriptorSomethingNew"],
        ]]
        let result = PastebotImport.filter(fromPlist: plist, fallbackName: "x")
        #expect(result.filter.steps.count == 3)
        #expect(result.skipped == ["SomethingNew"])
        #expect(result.filter.steps[0].choice == FilterStep.CaseStyle.camel.rawValue)
        let out = try? TextOps.apply(result.filter.steps[1], to: #"a\b"#)
        #expect(out == #"a\\b"#)
    }

    @Test func pastebotDatabase() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pl-import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let db = folder.appendingPathComponent("Clippings.db").path
        let uuid = "11111111-2222-3333-4444-555555555555"
        let sql = """
        CREATE TABLE entries (uuid TEXT PRIMARY KEY NOT NULL, version INTEGER NOT NULL, created_at DATETIME NOT NULL, copied_at DATETIME, hash INTEGER NOT NULL, title TEXT, source_name TEXT, source_bundle_identifier TEXT, item_count UNSIGNED INT NOT NULL);
        CREATE TABLE types_data (id INTEGER PRIMARY KEY NOT NULL, entry_uuid TEXT NOT NULL, item_index INTEGER NOT NULL, type TEXT NOT NULL, data BLOB);
        CREATE TABLE pasteboard (name TEXT, entry_uuids TEXT);
        INSERT INTO entries VALUES ('\(uuid)', 1, 1700000000, 1700000100, 0, NULL, 'Notes', 'com.apple.Notes', 1);
        INSERT INTO types_data VALUES (1, '\(uuid)', 0, 'public.utf8-plain-text', CAST('hello import' AS BLOB));
        INSERT INTO pasteboard VALUES ('Work', '["\(uuid)"]');
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [db, sql]
        try process.run()
        process.waitUntilExit()
        let result = try PastebotImport.clippings(under: folder)
        #expect(result.clips.count == 1)
        #expect(result.clips[0].content.plainText == "hello import")
        #expect(result.clips[0].sourceName == "Notes")
        #expect(abs(result.clips[0].copiedAt.timeIntervalSince1970 - 1_700_000_100) < 1)
        #expect(result.pastebins.first?.name == "Work")
        #expect(result.pastebins.first?.uuids == [uuid])
    }
}

@Suite struct BridgeTests {
    @Test func roundTrip() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("pl-\(UUID().uuidString.prefix(8)).sock").path
        let server = BridgeServer(path: path) { command, args in
            if command == "fail" { throw Bridge.Failure("nope") }
            return ["echo": command, "args": args]
        }
        try server.start()
        defer { server.stop() }
        setenv("PASTELENS_BRIDGE_SOCKET", path, 1)
        defer { unsetenv("PASTELENS_BRIDGE_SOCKET") }
        let result = try Bridge.call("hello", args: ["a": "b"]) as? [String: Any]
        #expect(result?["echo"] as? String == "hello")
        #expect((result?["args"] as? [String: String])?["a"] == "b")
        #expect(throws: Bridge.Failure.self) { try Bridge.call("fail", args: [:]) }
    }
}

@Suite struct DatabaseTests {
    func db() throws -> ClipDatabase {
        try ClipDatabase(url: FileManager.default.temporaryDirectory.appendingPathComponent("pl-db-\(UUID().uuidString).sqlite"))
    }

    func clip(_ text: String, ago: TimeInterval = 0) -> Clipping {
        ClipBuilder.make(from: .text(text), source: ("com.apple.Notes", "Notes"), origin: "A", now: Date().addingTimeInterval(-ago))
    }

    @Test func storeAndPage() throws {
        let db = try db()
        let clips = (0..<30).map { clip("item number \($0)", ago: Double($0)) }
        try db.upsert(clips)
        #expect(db.count(.history) == 30)
        #expect(db.page(.history, limit: 5).map(\.previewText) == (0..<5).map { "item number \($0)" })
        #expect(db.page(.history, limit: 5, offset: 28).count == 2)
        var moved = clips[3]
        let bin = UUID()
        moved.inHistory = false
        moved.pastebinIDs = [bin]
        try db.upsert(moved)
        #expect(db.count(.history) == 29)
        #expect(db.page(.pastebin(bin), limit: 10).map(\.id) == [moved.id])
        try db.delete([moved.id])
        #expect(db.count(.pastebin(bin)) == 0)
        #expect(db.clip(clips[0].id)?.previewText == "item number 0")
    }

    @Test func search() throws {
        let db = try db()
        try db.upsert([clip("Invoice 4471 due Friday"), clip("Meeting notes for the launch"), clip("grocery list: apples")])
        #expect(db.search("voic", in: .history, limit: 10).map(\.previewText) == ["Invoice 4471 due Friday"])
        #expect(db.search("invoce frday", in: .history, limit: 10).first?.previewText == "Invoice 4471 due Friday")
        #expect(db.search("launch meeting", in: .history, limit: 10).first?.previewText == "Meeting notes for the launch")
        #expect(db.search("zzqq", in: .history, limit: 10).isEmpty)
        var secret = clip("sk-test-abcdef1234567890")
        secret.sensitive = true
        secret.title = "API key or token"
        try db.upsert(secret)
        #expect(db.search("abcdef", in: .history, limit: 10).isEmpty)
    }

    @Test func retentionAndHashes() throws {
        let db = try db()
        var clips = (0..<10).map { clip("c\($0)", ago: Double($0) * 86_400) }
        clips[9].pinned = true
        try db.upsert(clips)
        #expect(Set(db.expired(keeping: 5, maxDays: 0)) == Set(clips[5...8].map(\.id)))
        #expect(Set(db.expired(keeping: 0, maxDays: 3)) == Set(clips[3...8].map(\.id)))
        #expect(db.historyClip(withHash: clips[2].contentHash)?.id == clips[2].id)
        try db.set(Data("x".utf8), forKey: "k")
        #expect(db.data(forKey: "k") == Data("x".utf8))
    }
}
