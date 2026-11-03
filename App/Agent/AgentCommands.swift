import AppKit
import PasteLensKit

/// Everything an agent can do in PasteLens. Add a command here and the CLI, `help`, and the
/// MCP tools all get it. Each `run` is on the main actor and calls the same ClipStore,
/// Paster and window code as the History window, the menu bar menu and pastelens:// links,
/// so the windows update live.
///
/// Privacy: clippings that look like secrets (`sensitive`) are listed by title only; their
/// text is never returned. Copies an app marks as concealed are never recorded at all.
enum AgentCommands {
    static let all: [AgentCommand] = [
        AgentCommand(name: "status", summary: "Show the version, whether recording is paused, how many clippings History, Pinned and the library hold, the stack's size, sync status, and whether pasting into apps is allowed.",
                     example: "pastelens status --json", readOnly: true) { _ in
            let store = ClipStore.shared
            let sync = SyncEngine.shared
            return ["app": AppInfo.name, "version": AppInfo.version, "testCopy": AgentSocket.isTestRun,
                    "paused": Preferences.shared.paused,
                    "clippings": store.db.totalCount, "history": store.count(.history) ?? 0, "pinned": store.count(.pinned) ?? 0,
                    "pastebins": store.library.pastebins.count, "smartPastebins": store.library.smartPastebins.count,
                    "filters": store.library.filters.count, "snippets": store.library.snippets.count,
                    "stack": StackController.shared.items.count,
                    "sync": sync.enabled ? sync.status.summary : "Off",
                    "pasteAllowed": Paster.trusted,
                    "historyWindowOpen": NSApp.windows.contains { $0.isVisible && $0.title == "PasteLens" && !($0 is NSPanel) }]
        },

        // MARK: Clippings

        AgentCommand(name: "clips list", summary: "List clippings in History (or another pastebin), newest first, or best match first with --search, which forgives typos as Quick Paste does. Returns `clips` (id, title, kind, copied in UTC, app, pinned, pastebins, sensitive), `total` and `nextOffset` when there are more.",
                     params: [.init(name: "search", help: "words to look for in the text, title, note or app"),
                              .init(name: "pastebin", help: "history (default), pinned, all, or a pastebin or smart pastebin's name or id (see `pastelens pastebins list`)"),
                              .init(name: "since", help: "only clippings copied on or after this ISO 8601 date, like 2026-11-01"),
                              .init(name: "limit", kind: .integer, help: "at most this many (default 50, at most 500)"),
                              .init(name: "offset", kind: .integer, help: "skip this many, for the next page")],
                     example: "pastelens clips list --search invoice --limit 10 --json", readOnly: true) { args in
            let store = ClipStore.shared
            let scope = try findScope(args.string("pastebin"))
            let limit = try args.int("limit", default: 50), offset = try args.int("offset", default: 0)
            guard (1...500).contains(limit) else { throw AgentError.usage("--limit must be 1 to 500") }
            guard offset >= 0 else { throw AgentError.usage("--offset can't be negative") }
            let search = args.string("search")?.trimmingCharacters(in: .whitespaces) ?? ""
            var since: Date?
            if let raw = args.string("since") {
                guard let date = ISO8601DateFormatter().date(from: raw) ?? ISO8601DateFormatter.dateOnly.date(from: raw) else {
                    throw AgentError.usage("--since must be an ISO 8601 date, like 2026-11-01 or 2026-11-01T09:30:00Z")
                }
                since = date
            }
            let items: [Clipping], total: Int
            if search.isEmpty && since == nil {
                items = store.clippings(in: scope, limit: limit, offset: offset)
                total = store.count(scope) ?? (offset + items.count)
            } else {
                // Searches and date limits: the matches, up to 5,000, then a page of them.
                var matches = store.clippings(in: scope, query: search, limit: 5_000)
                if let since { matches = matches.filter { $0.copiedAt >= since } }
                items = Array(matches.dropFirst(offset).prefix(limit))
                total = matches.count
            }
            var result: JSONObject = ["clips": items.map(summary), "total": total]
            if offset + items.count < total { result["nextOffset"] = offset + items.count }
            return result
        },
        AgentCommand(name: "clips show", summary: "Show one clipping: its full text (or the text read from an image), title, note, app, size, types and pastebins. A clipping that looks like a secret shows its title only.",
                     params: [idParam],
                     example: "pastelens clips show 3f2a9c1e --json", readOnly: true) { args in
            let clip = try findClip(args.required("id"))
            var result = summary(clip)
            result["created"] = JSON.date(clip.createdAt)
            result["types"] = clip.types
            result["bytes"] = clip.sizeBytes
            if let note = clip.note { result["note"] = note }
            if let expires = clip.expiresAt { result["expires"] = JSON.date(expires) }
            if let width = clip.imageWidth, let height = clip.imageHeight { result["width"] = width; result["height"] = height }
            if clip.sensitive {
                result["text"] = NSNull()
                result["hidden"] = "looks like a secret, so its text isn't shown. The person can see it in PasteLens"
            } else if let text = ClipStore.shared.text(of: clip.id) {
                result["text"] = text
            } else if let ocr = clip.ocrText, !ocr.isEmpty {
                result["recognizedText"] = ocr
            } else {
                result["text"] = clip.previewText.isEmpty ? NSNull() : clip.previewText
                if !ClipStore.shared.hasContent(clip.id) { result["contentOnThisMac"] = false }
            }
            return result
        },
        AgentCommand(name: "clips add", summary: "Save text as a new clipping, without touching the clipboard. It goes into History, or into a pastebin with --pastebin.",
                     params: [.init(name: "text", required: true, help: "the text to save"),
                              .init(name: "title", help: "a title to show instead of the first line"),
                              .init(name: "pastebin", help: "a pastebin's name or id to keep it in instead of History")],
                     example: "pastelens clips add --text \"Meeting notes\" --pastebin Work --json") { args in
            let store = ClipStore.shared
            let text = try args.required("text")
            var bins: [UUID] = []
            if let raw = args.string("pastebin") {
                guard case .pastebin(let id) = try findScope(raw) else {
                    throw AgentError.invalid("--pastebin must be one of your own pastebins, not History, Pinned or a smart pastebin")
                }
                bins = [id]
            }
            let title = args.string("title").flatMap { $0.isEmpty ? nil : $0 }
            let clip = store.add(.text(text), title: title, source: (nil, "pastelens"), inHistory: bins.isEmpty, pastebins: bins)
            return summary(store.clip(clip.id) ?? clip)
        },
        AgentCommand(name: "clips update", summary: "Change a clipping's note or pin. Pinned clippings are never removed by History limits or Clear History. Only the options you give change.",
                     params: [idParam,
                              .init(name: "note", help: "a new note, replacing the old one (\"\" clears it)"),
                              .init(name: "pinned", kind: .boolean, help: "true or false")],
                     example: "pastelens clips update 3f2a9c1e --pinned --note \"For the report\" --json") { args in
            let store = ClipStore.shared
            let before = try findClip(args.required("id"))
            guard args.string("note") != nil || args.string("pinned") != nil else {
                throw AgentError.usage("nothing to change. Give --note or --pinned. Example: pastelens clips update 3f2a9c1e --pinned")
            }
            if let note = args.string("note") {
                let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed != (before.note ?? "") { store.update(before.id) { $0.note = trimmed.isEmpty ? nil : trimmed } }
            }
            if let pinned = try args.bool("pinned"), pinned != before.pinned { store.setPinned([before.id], pinned) }
            let after = store.clip(before.id) ?? before
            var result = summary(after)
            result["note"] = after.note ?? NSNull()
            result["changed"] = after.note != before.note || after.pinned != before.pinned
            return result
        },
        AgentCommand(name: "clips move", summary: "Move clippings into a pastebin, as dragging them there does. They leave History, so clearing History won't remove them. --to history moves them back.",
                     params: [.init(name: "ids", required: true, positional: true, help: "clipping ids, separated by commas"),
                              .init(name: "to", required: true, help: "a pastebin's name or id, or history")],
                     example: "pastelens clips move 3f2a9c1e,8b01d2c4 --to Work --json") { args in
            let store = ClipStore.shared
            let clips = try findClips(args.required("ids"))
            let ids = clips.map(\.id)
            let target = try findScope(args.required("to"))
            switch target {
            case .history:
                // As "Move Back to History" does, from every pastebin the clipping is in.
                for clip in clips { for bin in clip.pastebinIDs { store.remove([clip.id], from: bin) } }
            case .pastebin(let bin):
                store.move(ids, to: bin)
            default:
                throw AgentError.invalid("--to must be one of your own pastebins or history. Use `pastelens clips update <id> --pinned` to pin")
            }
            return ["moved": ids.map(short), "to": scopeName(target), "clips": store.db.clips(ids).map(summary)]
        },
        AgentCommand(name: "clips copy", summary: "Put a clipping on the clipboard, as choosing it in the menu bar menu does, and move it to the top of History. It doesn't paste.",
                     params: [idParam,
                              .init(name: "plain", kind: .boolean, help: "copy only the text, without formatting")],
                     example: "pastelens clips copy 3f2a9c1e --json") { args in
            let clip = try findClip(args.required("id"))
            #if DEBUG
            // A test copy leaves the real clipboard (and the installed PasteLens watching it) alone.
            if AgentSocket.isTestRun { throw AgentError.invalid("a test copy (APP_STORE) doesn't copy to the real clipboard") }
            #endif
            guard Paster.copy(clip, plain: try args.bool("plain") == true) else {
                throw AgentError.invalid("the clipping's content isn't on this Mac yet. Try again once sync has brought it over")
            }
            return ["copied": short(clip.id), "title": title(clip)]
        },
        AgentCommand(name: "clips delete", summary: "Delete clippings, on every Mac that syncs, as Delete in the History window does. Without --yes it only shows what it would delete.",
                     params: [.init(name: "ids", required: true, positional: true, help: "clipping ids, separated by commas")],
                     example: "pastelens clips delete 3f2a9c1e --yes --json", destructive: true) { args in
            let clips = try findClips(args.required("ids"))
            guard args.confirmed else {
                return ["wouldDelete": clips.map(summary),
                        "hint": "add --yes to delete \(clips.count == 1 ? "it" : "them"). It can't be undone, and it goes from every Mac that syncs"]
            }
            ClipStore.shared.delete(clips.map(\.id), sound: false)
            return ["deleted": clips.map { short($0.id) }]
        },
        AgentCommand(name: "history clear", summary: "Clear History, as the History window's Clear History does: pinned clippings and those in pastebins stay. Without --yes it only shows how many would go.",
                     example: "pastelens history clear --yes --json", destructive: true) { args in
            let store = ClipStore.shared
            let history = store.db.page(.history, limit: Int.max)
            let kept = history.filter(\.isKept).count
            guard args.confirmed else {
                return ["wouldDelete": history.count - kept, "wouldKeep": kept,
                        "hint": "add --yes to clear History. It can't be undone, and it clears it on every Mac that syncs"]
            }
            store.clearHistory()
            return ["deleted": history.count - kept, "kept": kept]
        },

        // MARK: Pastebins, filters, snippets

        AgentCommand(name: "pastebins list", summary: "List History, Pinned, your pastebins and smart pastebins, with how many clippings each holds. Use a name or id with --pastebin and --to.",
                     example: "pastelens pastebins list --json", readOnly: true) { _ in
            let store = ClipStore.shared
            var bins: [JSONObject] = [["id": "history", "name": "History", "kind": "history", "count": store.count(.history) ?? 0],
                                      ["id": "pinned", "name": "Pinned", "kind": "pinned", "count": store.count(.pinned) ?? 0]]
            bins += store.library.pastebins.sorted { $0.order < $1.order }.map {
                ["id": short($0.id), "name": $0.name, "kind": "pastebin", "count": store.count(.pastebin($0.id)) ?? 0]
            }
            bins += store.library.smartPastebins.map {
                ["id": short($0.id), "name": $0.name, "kind": "smart", "count": store.count(.smart($0.id)) ?? store.clippings(in: .smart($0.id), limit: 10_000).count]
            }
            return ["pastebins": bins]
        },
        AgentCommand(name: "filters list", summary: "List filters, built-in and your own, pinned ones first, with their steps.",
                     example: "pastelens filters list --json", readOnly: true) { _ in
            let filters = ClipStore.shared.library.filters
            let ordered = filters.pinned + filters.filter { !$0.isPinned }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            return ["filters": ordered.map { filter -> JSONObject in
                ["id": short(filter.id), "name": filter.name, "group": filter.group, "details": filter.details,
                 "pinned": filter.isPinned, "steps": filter.steps.map(\.summary)]
            }]
        },
        AgentCommand(name: "filters run", summary: "Run a filter on a clipping's text or on --text and return the result, as Quick Paste's filters do. Nothing is copied or saved. A filter with a script, JavaScript or AI step runs that step too.",
                     params: [.init(name: "filter", required: true, positional: true, help: "the filter's name (like \"Title Case\") or id"),
                              .init(name: "clip", help: "a clipping id to filter"),
                              .init(name: "text", help: "text to filter, instead of a clipping")],
                     example: "pastelens filters run \"Title Case\" --text \"the quick brown fox\" --json") { args in
            let store = ClipStore.shared
            let key = try args.required("filter")
            guard let filter = store.filter(named: key) ?? uniquePrefix(key, in: store.library.filters, id: \.id) else {
                throw AgentError.notFound("no filter called \"\(key)\". Run `pastelens filters list`")
            }
            let input: String
            if let text = args.string("text") {
                input = text
            } else if let raw = args.string("clip") {
                let clip = try findClip(raw)
                guard !clip.sensitive else { throw AgentError.invalid("that clipping looks like a secret, so its text isn't given to filters here") }
                guard let text = FilterApplier.sourceText(for: clip) else { throw AgentError.invalid("that clipping has no text") }
                input = text
            } else {
                throw AgentError.usage("give --clip or --text. Example: pastelens filters run \"Title Case\" --text \"the quick brown fox\"")
            }
            do {
                return ["filter": filter.name, "text": try await FilterRunner.run(filter, on: input, services: AppFilterServices())]
            } catch {
                throw AgentError.invalid("the filter failed: \(error.localizedDescription)")
            }
        },
        AgentCommand(name: "snippets list", summary: "List snippets with their abbreviations, groups, templates and the {input:…} fields they ask for.",
                     example: "pastelens snippets list --json", readOnly: true) { _ in
            ["snippets": ClipStore.shared.library.snippets.map { snippet -> JSONObject in
                ["id": short(snippet.id), "name": snippet.name, "abbreviation": snippet.abbreviation, "group": snippet.group,
                 "template": snippet.template, "fields": Template.fields(in: snippet.template).map(\.name)]
            }]
        },
        AgentCommand(name: "snippets expand", summary: "Fill in a snippet's placeholders (date, clipboard, {input:…} fields) and return the text, without pasting it.",
                     params: [.init(name: "snippet", required: true, positional: true, help: "the snippet's name, abbreviation or id"),
                              .init(name: "inputs", help: "a JSON object of values for its {input:Name} fields, like {\"Name\":\"Alex\"}")],
                     example: "pastelens snippets expand sig --inputs '{\"Name\":\"Alex\"}' --json", readOnly: true) { args in
            let snippets = ClipStore.shared.library.snippets
            let key = try args.required("snippet")
            guard let snippet = snippets.first(where: { $0.name.caseInsensitiveCompare(key) == .orderedSame || (!$0.abbreviation.isEmpty && $0.abbreviation == key) })
                    ?? uniquePrefix(key, in: snippets, id: \.id) else {
                throw AgentError.notFound("no snippet called \"\(key)\". Run `pastelens snippets list`")
            }
            var inputs: [String: String] = [:]
            if let raw = args.string("inputs") {
                guard let object = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? JSONObject else {
                    throw AgentError.usage("--inputs must be a JSON object, like {\"Name\":\"Alex\"}")
                }
                inputs = object.mapValues { "\($0)" }
            }
            return ["snippet": snippet.name, "text": SnippetPaster.expand(snippet, inputs: inputs)]
        },

        // MARK: Recording and windows

        AgentCommand(name: "recording pause", summary: "Stop recording what's copied, as Pause Recording in the menu bar menu does, until `pastelens recording resume`.",
                     example: "pastelens recording pause --json") { _ in
            let changed = !Preferences.shared.paused
            if changed { Preferences.shared.paused = true }
            return ["paused": true, "changed": changed]
        },
        AgentCommand(name: "recording resume", summary: "Start recording what's copied again, as Resume Recording in the menu bar menu does.",
                     example: "pastelens recording resume --json") { _ in
            let changed = Preferences.shared.paused
            if changed { Preferences.shared.paused = false }
            return ["paused": false, "changed": changed]
        },
        AgentCommand(name: "open", summary: "Show a PasteLens window for the person: quickpaste, history, filters, snippets, activity, stack, settings or help.",
                     params: [.init(name: "page", required: true, positional: true, help: "quickpaste, history, filters, snippets, activity, stack, settings or help"),
                              .init(name: "clip", help: "with history: a clipping id to select"),
                              .init(name: "tab", help: "with settings: a tab name, like Sync; with help: a topic id, like automation")],
                     example: "pastelens open history --clip 3f2a9c1e") { args in
            let page = try args.required("page").lowercased()
            let state = MainWindow.shared.state
            switch page {
            case "quickpaste", "quick-paste": QuickPastePanel.shared.show()
            case "history":
                let clip = try args.string("clip").map { try findClip($0) }
                state.section = .clips(.history)
                state.query = ""
                MainWindow.shared.show(selecting: clip?.id)
            case "filters", "snippets", "activity":
                state.section = page == "filters" ? .filters : page == "snippets" ? .snippets : .activity
                state.query = ""
                MainWindow.shared.show()
            case "stack": StackWindow.shared.show()
            case "settings": SettingsWindow.shared.show(tab: args.string("tab"))
            case "help": HelpWindow.shared.show(topic: args.string("tab"))
            default:
                throw AgentError.notFound("no page \"\(page)\". Pages: quickpaste, history, filters, snippets, activity, stack, settings, help")
            }
            return ["opened": page]
        },
    ]

    static let idParam = AgentCommand.Param(name: "id", required: true, positional: true, help: "the clipping's id (any unique start of it)")

    // MARK: Finding things

    /// The first 8 characters of a UUID, lowercased. Any unique start finds it again.
    static func short(_ id: UUID) -> String { String(id.uuidString.prefix(8)).lowercased() }

    @MainActor
    static func findClip(_ raw: String) throws -> Clipping {
        let store = ClipStore.shared
        let key = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if let id = UUID(uuidString: key), let clip = store.clip(id) { return clip }
        guard key.count >= 4 else { throw AgentError.usage("\"\(raw)\" is too short for an id: give at least 4 characters") }
        let matches = store.db.ids(.all).filter { $0.uuidString.lowercased().hasPrefix(key) }
        guard let first = matches.first else { throw AgentError.notFound("no clipping with id \(raw). Run `pastelens clips list`") }
        guard matches.count == 1 else { throw AgentError.usage("more than one clipping starts with \(raw). Give more of the id") }
        guard let clip = store.clip(first) else { throw AgentError.notFound("no clipping with id \(raw). Run `pastelens clips list`") }
        return clip
    }

    @MainActor
    static func findClips(_ raw: String) throws -> [Clipping] {
        let keys = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !keys.isEmpty else { throw AgentError.usage("give at least one clipping id") }
        var seen = Set<UUID>()
        return try keys.map(findClip).filter { seen.insert($0.id).inserted }
    }

    /// A pastebin by keyword (history, pinned, all), name, or id.
    @MainActor
    static func findScope(_ raw: String?) throws -> ClipStore.Scope {
        guard let raw, !raw.isEmpty else { return .history }
        let library = ClipStore.shared.library
        switch raw.lowercased() {
        case "history": return .history
        case "pinned": return .pinned
        case "all": return .all
        default: break
        }
        if let bin = library.pastebins.first(where: { $0.name.caseInsensitiveCompare(raw) == .orderedSame }) { return .pastebin(bin.id) }
        if let bin = library.smartPastebins.first(where: { $0.name.caseInsensitiveCompare(raw) == .orderedSame }) { return .smart(bin.id) }
        if let bin = uniquePrefix(raw, in: library.pastebins, id: \.id) { return .pastebin(bin.id) }
        if let bin = uniquePrefix(raw, in: library.smartPastebins, id: \.id) { return .smart(bin.id) }
        throw AgentError.notFound("no pastebin called \"\(raw)\". Run `pastelens pastebins list`")
    }

    static func uniquePrefix<T>(_ raw: String, in items: [T], id: KeyPath<T, UUID>) -> T? {
        let key = raw.lowercased()
        guard key.count >= 4 else { return nil }
        let matches = items.filter { $0[keyPath: id].uuidString.lowercased().hasPrefix(key) }
        return matches.count == 1 ? matches[0] : nil
    }

    @MainActor
    static func scopeName(_ scope: ClipStore.Scope) -> String {
        let library = ClipStore.shared.library
        switch scope {
        case .history: return "History"
        case .pinned: return "Pinned"
        case .all: return "All"
        case .pastebin(let id): return library.pastebins.first { $0.id == id }?.name ?? short(id)
        case .smart(let id): return library.smartPastebins.first { $0.id == id }?.name ?? short(id)
        }
    }

    // MARK: Results

    /// The title the lists show; a secret shows its title and dots, never its text.
    static func title(_ clip: Clipping) -> String {
        clip.sensitive ? (clip.title ?? "Sensitive") + " ••••" : String(clip.displayTitle.prefix(120))
    }

    @MainActor
    static func summary(_ clip: Clipping) -> JSONObject {
        let names = ClipStore.shared.library.pastebins
        var result: JSONObject = ["id": short(clip.id), "title": title(clip), "kind": clip.kind.rawValue,
                                  "copied": JSON.date(clip.copiedAt), "pinned": clip.pinned, "inHistory": clip.inHistory,
                                  "pastebins": clip.pastebinIDs.map { id in names.first { $0.id == id }?.name ?? short(id) }]
        if let app = clip.sourceName { result["app"] = app }
        if clip.sensitive { result["sensitive"] = true }
        return result
    }
}
