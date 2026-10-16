import AppKit
import PasteLensKit

/// Answers the `pastelens` command-line tool and the MCP helper.
@MainActor
enum BridgeHandler {
    private static var server: BridgeServer?

    static func start() {
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
                ["id": "history", "name": "History", "kind": "history", "count": store.history.count],
                ["id": "pinned", "name": "Pinned", "kind": "pinned", "count": lib.clippings.filter(\.pinned).count],
            ]
            bins += lib.pastebins.map { ["id": $0.id.uuidString, "name": $0.name, "kind": "pastebin",
                                          "count": store.clippings(in: .pastebin($0.id)).count] }
            bins += lib.smartPastebins.map { ["id": $0.id.uuidString, "name": $0.name, "kind": "smart",
                                               "count": store.clippings(in: .smart($0.id)).count] }
            return bins

        case "get-clippings":
            var items = store.clippings(in: try scope(), query: args["query"] ?? "")
            if let since = args["since"] {
                guard let date = ISO8601DateFormatter().date(from: since) ?? ISO8601DateFormatter.dateOnly.date(from: since) else {
                    throw Bridge.Failure("--since must be an ISO 8601 date")
                }
                items = items.filter { $0.copiedAt >= date }
            }
            let offset = max(Int(args["offset"] ?? "") ?? 0, 0)
            let limit = min(max(Int(args["limit"] ?? "") ?? 20, 1), 500)
            return items.dropFirst(offset).prefix(limit).map(describe)

        case "get-clipping-by-index":
            guard let index = Int(args["index"] ?? ""), index >= 0 else { throw Bridge.Failure("--index must be a number from 0") }
            let items = store.clippings(in: try scope())
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
