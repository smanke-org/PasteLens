import AppKit
import PasteLensKit

/// Answers the `pastelens` command-line tool and the MCP helper.
@MainActor
enum BridgeHandler {
    private static var server: BridgeServer?

    static func start() {
        // macOS only lets the system create a group container; asking for its URL does that.
        _ = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Bridge.appGroup)
        let server = BridgeServer { command, args in try await BridgeHandler.handle(command, args) }
        do {
            try server.start()
            self.server = server
        } catch {
            NSLog("PasteLens: command-line bridge unavailable: \(error.localizedDescription)")
        }
    }

    static func stop() { server?.stop() }

    static func handle(_ command: String, _ args: [String: String]) async throws -> Any {
        let store = ClipStore.shared
        func clip(_ key: String = "id") throws -> Clipping {
            guard let raw = args[key], let id = UUID(uuidString: raw), let clip = store.clip(id) else {
                throw Bridge.Failure("Clipping not found: \(args[key] ?? "(no id)")")
            }
            return clip
        }
        func scope() throws -> ClipStore.Scope {
            guard let scope = ClipStore.Scope(id: args["pastebin-id"]) else { throw Bridge.Failure("Pastebin not found: \(args["pastebin-id"] ?? "")") }
            return scope
        }

        switch Bridge.command(named: command)?.name ?? command {
        case "get-pastebins":
            let lib = store.library
            var bins: [[String: Any]] = [
                ["id": "history", "name": "History", "kind": "history", "count": store.count(.history) ?? 0],
                ["id": "pinned", "name": "Pinned", "kind": "pinned", "count": store.count(.pinned) ?? 0],
            ]
            bins += lib.pastebins.map { ["id": $0.id.uuidString, "name": $0.name, "kind": "pastebin",
                                          "count": store.count(.pastebin($0.id)) ?? 0] }
            bins += lib.smartPastebins.map { ["id": $0.id.uuidString, "name": $0.name, "kind": "smart",
                                               "count": store.clippings(in: .smart($0.id), limit: 10_000).count] }
            return bins

        case "get-clippings":
            let offset = max(Int(args["offset"] ?? "") ?? 0, 0)
            let limit = min(max(Int(args["limit"] ?? "") ?? 20, 1), 500)
            var items = store.clippings(in: try scope(), query: args["query"] ?? "", limit: args["since"] == nil ? offset + limit : 10_000)
            if let since = args["since"] {
                guard let date = ISO8601DateFormatter().date(from: since) ?? ISO8601DateFormatter.dateOnly.date(from: since) else {
                    throw Bridge.Failure("--since must be an ISO 8601 date")
                }
                items = items.filter { $0.copiedAt >= date }
            }
            return items.dropFirst(offset).prefix(limit).map(describe)

        case "get-clipping-by-index":
            guard let index = Int(args["index"] ?? ""), index >= 0 else { throw Bridge.Failure("--index must be a number from 0") }
            let items = store.clippings(in: try scope(), limit: index + 1)
            guard items.indices.contains(index) else { throw Bridge.Failure("No clipping at index \(index) (there are \(items.count)).") }
            return describe(items[index])

        case "get-clipping-text":
            let c = try clip()
            guard let text = store.text(of: c.id) ?? (c.ocrText?.isEmpty == false ? c.ocrText : nil) else {
                throw Bridge.Failure("This clipping has no text.")
            }
            return ["id": c.id.uuidString, "text": text]

        case "get-clipping-image":
            let c = try clip()
            guard let content = store.content(for: c.id) else { throw Bridge.Failure("The clipping's content isn't on this Mac yet.") }
            if let png = content.data(for: UTI.png) { return ["mime_type": "image/png", "data": png.base64EncodedString()] }
            if let jpeg = content.data(for: UTI.jpeg) { return ["mime_type": "image/jpeg", "data": jpeg.base64EncodedString()] }
            guard let image = Recognizer.cgImage(from: content),
                  let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
                throw Bridge.Failure("This clipping has no image.")
            }
            return ["mime_type": "image/png", "data": png.base64EncodedString()]

        case "get-clipping-data":
            let c = try clip()
            guard let type = args["type"], let data = store.content(for: c.id)?.data(for: type) else {
                throw Bridge.Failure("No \(args["type"] ?? "") data. Available types: \(c.types.joined(separator: ", "))")
            }
            return ["type": type, "size_bytes": data.count, "data": data.base64EncodedString()]

        case "list-filters":
            return store.library.filters.map {
                ["id": $0.id.uuidString, "name": $0.name, "group": $0.group, "description": $0.details,
                 "steps": $0.steps.map(\.summary)] as [String: Any]
            }

        case "apply-filter":
            guard let filter = store.filter(named: args["filter-id"] ?? "") else { throw Bridge.Failure("Filter not found: \(args["filter-id"] ?? "")") }
            let input: String
            if let text = args["text"] { input = text }
            else if args["id"] != nil {
                guard let t = FilterApplier.sourceText(for: try clip()) else { throw Bridge.Failure("This clipping has no text.") }
                input = t
            } else { throw Bridge.Failure("Give --id or --text.") }
            return ["text": try await FilterRunner.run(filter, on: input, services: AppFilterServices())]

        case "list-snippets":
            return store.library.snippets.map {
                ["id": $0.id.uuidString, "name": $0.name, "abbreviation": $0.abbreviation, "group": $0.group, "template": $0.template,
                 "fields": Template.fields(in: $0.template).map(\.name)] as [String: Any]
            }

        case "expand-snippet":
            let key = args["snippet-id"] ?? ""
            guard let snippet = store.library.snippets.first(where: { $0.id.uuidString.caseInsensitiveCompare(key) == .orderedSame || $0.name == key || $0.abbreviation == key }) else {
                throw Bridge.Failure("Snippet not found: \(key)")
            }
            var inputs: [String: String] = [:]
            if let raw = args["inputs"], let data = raw.data(using: .utf8), let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                inputs = dict.mapValues { "\($0)" }
            }
            return ["text": SnippetPaster.expand(snippet, inputs: inputs)]

        case "write-to-pasteboard":
            if args["id"] != nil {
                guard Paster.copy(try clip()) else { throw Bridge.Failure("The clipping's content isn't on this Mac yet.") }
                return ["ok": true]
            }
            if let text = args["text"] {
                let new = store.add(.text(text), source: (nil, "pastelens"))
                Paster.write(text: text)
                return ["ok": true, "id": new.id.uuidString]
            }
            if let base64 = args["image-base64"], let data = Data(base64Encoded: base64) {
                let mime = args["mime-type"] ?? "image/png"
                let type = mime.contains("jpeg") || mime.contains("jpg") ? UTI.jpeg : mime.contains("tiff") ? UTI.tiff : mime.contains("pdf") ? UTI.pdf : UTI.png
                let content = ClipContent(representations: [ClipRepresentation(type: type, data: data)])
                let new = store.add(content, source: (nil, "pastelens"))
                Paster.write(content)
                return ["ok": true, "id": new.id.uuidString]
            }
            throw Bridge.Failure("Give --id, --text or --image-file.")

        case "add-clipping":
            var bins: [UUID] = []
            if let raw = args["pastebin-id"] {
                guard let id = UUID(uuidString: raw), store.library.pastebins.contains(where: { $0.id == id }) else { throw Bridge.Failure("Pastebin not found: \(raw)") }
                bins = [id]
            }
            var source: (String?, String?) = (nil, "pastelens")
            #if DEBUG
            // Staging screenshots: pretend the clipping came from another app.
            if let bundle = args["source-bundle"], let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) {
                source = (bundle, FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: ""))
            }
            #endif
            var content = ClipContent.text(args["text"] ?? "")
            #if DEBUG
            if let path = args["image-path"], let data = try? Data(contentsOf: URL(fileURLWithPath: path)) {
                content = ClipContent(representations: [ClipRepresentation(type: UTI.png, data: data)])
            }
            #endif
            let new = store.add(content, title: args["title"], source: source, inHistory: bins.isEmpty, pastebins: bins)
            if let minutes = args["minutes-ago"].flatMap(Double.init) {
                store.update(new.id) { $0.copiedAt = Date().addingTimeInterval(-minutes * 60); $0.createdAt = $0.copiedAt }
            }
            if args["pin"] == "true" { store.setPinned([new.id], true) }
            if args["secret"] == "true" {
                store.update(new.id) { $0.sensitive = true; $0.title = "API key or token"; $0.expiresAt = Date().addingTimeInterval(120) }
            }
            return describe(store.clip(new.id) ?? new)

        #if DEBUG
        case "debug-sync-setup":
            try await SyncEngine.shared.setUp(passphrase: args["passphrase"] ?? "")
            return ["ok": true]
        case "debug-sync-status":
            let sync = SyncEngine.shared
            return ["status": sync.status.summary, "devices": sync.devices.map(\.name), "pending": sync.pendingContent,
                    "clippings": store.db.totalCount, "hasContent": store.db.ids(.all).filter { store.hasContent($0) }.count]
        case "debug-show":
            switch args["window"] ?? "" {
            case "quickpaste": QuickPastePanel.shared.show()
            case "quickpaste-filter":
                QuickPastePanel.shared.show()
                let model = QuickPastePanel.shared.model
                if let index = args["index"].flatMap(Int.init) { model.selection = index }
                model.filterMode = model.selectedClip
                // After the search field settles, since focusing it resets the selection.
                if let name = args["filter-name"], let i = model.filters.firstIndex(where: { $0.name == name }) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { model.selection = i }
                }
                return ["ok": true]
            case "quickpaste-source":
                QuickPastePanel.shared.show()
                if args["source"] == "snippets" { QuickPastePanel.shared.model.source = .snippets }
            case "main": MainWindow.shared.state.section = .clips(.history); MainWindow.shared.state.query = ""; MainWindow.shared.show()
            case "filters": MainWindow.shared.state.section = .filters; MainWindow.shared.state.query = ""; MainWindow.shared.show()
            case "snippets": MainWindow.shared.state.section = .snippets; MainWindow.shared.state.query = ""; MainWindow.shared.show()
            case "stack": StackWindow.shared.show()
            case "welcome": WelcomeWindow.shared.show()
            case "close": NSApp.windows.forEach { $0.orderOut(nil) }
            default: SettingsWindow.shared.show(tab: args["window"])
            }
            if let id = args["select"].flatMap(UUID.init(uuidString:)) { MainWindow.shared.state.selection = [id] }
            if let name = args["select-filter"], let f = store.filter(named: name) { MainWindow.shared.state.selection = [f.id] }
            if let name = args["select-snippet"], let sn = store.library.snippets.first(where: { $0.name == name }) { MainWindow.shared.state.selection = [sn.id] }
            if let q = args["query"] { MainWindow.shared.state.query = q }
            if let size = args["size"]?.split(separator: "x").compactMap({ Double($0) }), size.count == 2,
               let window = NSApp.windows.first(where: { $0.isVisible && $0.title != "" && !($0 is NSPanel) }) {
                var frame = window.frame
                frame.size = NSSize(width: size[0], height: size[1])
                window.setFrame(frame, display: true)
            }
            return ["ok": true]
        case "debug-generate":
            // Adds made-up text clippings, for measuring how PasteLens copes with a big history.
            let count = Int(args["count"] ?? "") ?? 1000
            let words = ["invoice", "meeting", "project", "launch", "budget", "design", "review", "harbor", "friday", "update",
                         "client", "report", "draft", "summary", "schedule", "travel", "receipt", "notes", "plan", "team"]
            var rng = SystemRandomNumberGenerator()
            let start = Date()
            var batch: [(ClipContent, Clipping)] = []
            for i in 0..<count {
                let text = (0..<Int.random(in: 20...120, using: &rng)).map { _ in words.randomElement(using: &rng)! }.joined(separator: " ") + " #\(i)"
                let content = ClipContent.text(text)
                var clip = ClipBuilder.make(from: content, source: ("com.apple.Notes", "Notes"), origin: DeviceIdentity.id,
                                            now: Date().addingTimeInterval(-Double(i) * 60))
                clip.updatedAt = Date()
                batch.append((content, clip))
                if batch.count == 2_000 { store.addQuietly(batch); batch = [] }
            }
            store.addQuietly(batch)
            return ["added": count, "seconds": Date().timeIntervalSince(start)]

        case "debug-bench":
            func time(_ work: () -> Void) -> Double { let t = Date(); work(); return Date().timeIntervalSince(t) * 1000 }
            var r: [String: Any] = ["clippings": store.db.totalCount]
            r["search_ms"] = ["harbr", "budget friday", "zzzz", "#4242"].map { q in time { _ = store.clippings(in: .history, query: q) } }
            r["list_page_ms"] = time { _ = store.clippings(in: .history, limit: 200) }
            r["count_ms"] = time { _ = store.count(.history) }
            if let first = store.recent(1).first { r["save_ms"] = time { store.update(first.id, sync: false) { $0.note = "bench" } } }
            r["db_bytes"] = (try? FileManager.default.attributesOfItem(atPath: store.folder.appendingPathComponent("PasteLens.sqlite").path)[.size] as? Int) ?? 0
            return r

        case "debug-sync-pull":
            SyncEngine.shared.pull()
            return ["ok": true]
        #endif

        case "paste-clipboard":
            guard Paster.trusted else {
                Paster.requestAccess()
                throw Bridge.Failure("PasteLens needs Accessibility permission to paste. Allow it in System Settings › Privacy & Security › Accessibility.")
            }
            Paster.pasteClipboard(after: 0.02)
            return ["ok": true]

        case "add-to-stack":
            let ids = (args["ids"] ?? "").split(separator: ",").compactMap { UUID(uuidString: $0.trimmingCharacters(in: .whitespaces)) }
                .filter { store.clip($0) != nil }
            guard !ids.isEmpty else { throw Bridge.Failure("No known clipping ids given.") }
            StackController.shared.add(ids)
            return ["ok": true, "stack_size": StackController.shared.items.count]

        case "move-to-pastebin":
            let ids = (args["ids"] ?? "").split(separator: ",").compactMap { UUID(uuidString: $0.trimmingCharacters(in: .whitespaces)) }
                .filter { store.clip($0) != nil }
            guard !ids.isEmpty else { throw Bridge.Failure("No known clipping ids given.") }
            let target = args["pastebin-id"] ?? ""
            if target.lowercased() == "history" {
                for id in ids { for bin in store.clip(id)?.pastebinIDs ?? [] { store.remove([id], from: bin) } }
            } else {
                guard let bin = UUID(uuidString: target), store.library.pastebins.contains(where: { $0.id == bin }) else {
                    throw Bridge.Failure("Pastebin not found: \(target)")
                }
                store.move(ids, to: bin)
            }
            return ["ok": true]

        case "pin-clipping":
            let c = try clip()
            store.setPinned([c.id], args["pinned"].map { $0 != "false" && $0 != "0" } ?? true)
            return ["ok": true]

        case "delete-clipping":
            store.delete([try clip().id])
            return ["ok": true]

        case "clear-pastebin":
            store.clearHistory()
            return ["ok": true]

        default:
            throw Bridge.Failure("Unknown command: \(command)")
        }
    }

    static func describe(_ clip: Clipping) -> [String: Any] {
        let iso = ISO8601DateFormatter()
        var out: [String: Any] = [
            "id": clip.id.uuidString,
            "pastebin_ids": (clip.inHistory ? ["history"] : []) + clip.pastebinIDs.map(\.uuidString),
            "size_bytes": clip.sizeBytes,
            "created_at": iso.string(from: clip.createdAt),
            "copied_at": iso.string(from: clip.copiedAt),
            "types": clip.types,
            "preferred_type": clip.preferredType,
            "kind": clip.kind.rawValue,
            "pinned": clip.pinned,
        ]
        if let note = clip.note { out["note"] = note }
        if let title = clip.title { out["title"] = title }
        if clip.sourceBundleID != nil || clip.sourceName != nil {
            out["source_app"] = ["bundle_id": clip.sourceBundleID ?? "", "name": clip.sourceName ?? ""]
        }
        if clip.sensitive {
            out["sensitive"] = true
            out["text"] = "(hidden: looks like a secret)"
            return out
        }
        switch clip.kind {
        case .image:
            out["image"] = ["mime_type": clip.preferredType == UTI.jpeg ? "image/jpeg" : "image/png", "width": clip.imageWidth ?? 0, "height": clip.imageHeight ?? 0]
            if let ocr = clip.ocrText, !ocr.isEmpty { out["recognized_text"] = String(ocr.prefix(2_048)) }
        case .file:
            out["url"] = clip.previewText.split(separator: "\n").first.map { URL(fileURLWithPath: String($0)).absoluteString } ?? ""
        default:
            if !clip.previewText.isEmpty {
                out["text"] = clip.previewText
                if clip.textLength > clip.previewText.count { out["text_truncated"] = true }
            }
        }
        return out
    }
}

extension ISO8601DateFormatter {
    static let dateOnly: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate]
        return f
    }()
}
