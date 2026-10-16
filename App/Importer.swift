import AppKit
import PasteLensKit

/// Brings in data from Pastebot: its filter files and its clipping history.
@MainActor
enum Importer {
    /// Imports .pastebotfilter and .pastelensfilter files. Returns a summary for the user.
    static func importFilters(_ urls: [URL]) -> String {
        var imported = 0
        var notes: [String] = []
        for url in urls {
            if url.pathExtension == "pastelensfilter" {
                guard let data = try? Data(contentsOf: url), var filter = try? SyncMerge.decode(Filter.self, from: data) else {
                    notes.append("\(url.lastPathComponent) couldn't be read.")
                    continue
                }
                filter.id = UUID()
                filter.builtInKey = nil
                ClipStore.shared.upsertFilter(filter)
                imported += 1
                continue
            }
            do {
                let result = try PastebotImport.filter(fromFile: url)
                ClipStore.shared.upsertFilter(result.filter)
                imported += 1
                if !result.skipped.isEmpty {
                    notes.append("“\(result.filter.name)”: left out \(result.skipped.joined(separator: ", ")), which PasteLens doesn't have.")
                }
            } catch {
                notes.append(error.localizedDescription)
            }
        }
        return (["Imported \(imported) filter\(imported == 1 ? "" : "s")."] + notes).joined(separator: "\n")
    }

    /// Where Pastebot keeps its data.
    static var pastebotFolders: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            "Library/Group Containers/group.9JTH7AWHE6.com.tapbots.Pastebot3Mac",
            "Library/Containers/com.tapbots.Pastebot3Mac/Data/Library/Application Support",
            "Library/Group Containers/9JTH7AWHE6.com.tapbots.Pastebot2Mac",
            "Library/Containers/com.tapbots.Pastebot2Mac/Data/Library/Application Support",
        ].map { home.appendingPathComponent($0) }
    }

    static var pastebotInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.tapbots.Pastebot3Mac") != nil
            || NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.tapbots.Pastebot2Mac") != nil
            || pastebotFolders.contains { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Imports Pastebot's clippings and pastebins. macOS asks once for permission to read
    /// another app's data; in the App Store build the folder is chosen in an Open panel.
    static func importPastebotHistory() {
        let alert = NSAlert()
        alert.messageText = "Import from Pastebot?"
        alert.informativeText = "PasteLens copies Pastebot's clippings and pastebins (Pastebot is left as it is). Quit Pastebot first so its data is complete. macOS may ask whether PasteLens can access Pastebot's data — choose Allow."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Import")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertSecondButtonReturn else { return }

        var folders: [URL] = []
        #if APPSTORE
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "Choose Pastebot's data folder (Library › Group Containers › group.9JTH7AWHE6.com.tapbots.Pastebot3Mac)."
        panel.directoryURL = pastebotFolders.first
        guard panel.runModal() == .OK, let url = panel.url else { return }
        folders = [url]
        #else
        folders = pastebotFolders.filter { FileManager.default.fileExists(atPath: $0.path) }
        #endif

        Task.detached {
            var result: PastebotImport.DatabaseResult?
            var errors: [String] = []
            for folder in folders {
                do {
                    let found = try PastebotImport.clippings(under: folder)
                    if result == nil { result = found } else {
                        result!.clips += found.clips
                        result!.pastebins += found.pastebins
                    }
                } catch {
                    errors.append(error.localizedDescription)
                }
            }
            await MainActor.run { finish(result, errors: errors) }
        }
    }

    private static func finish(_ result: PastebotImport.DatabaseResult?, errors: [String]) {
        let alert = NSAlert()
        guard let result, !result.clips.isEmpty else {
            alert.messageText = "Nothing to Import"
            alert.informativeText = errors.first ?? "No Pastebot clippings were found. If macOS asked for access, choose Allow and try again."
            alert.runModal()
            return
        }
        let store = ClipStore.shared
        // Pastebins first, so clippings can be filed into them.
        var binIDs: [String: UUID] = [:]
        var membership: [String: [UUID]] = [:]
        for (name, uuids) in result.pastebins where !["General", "Clipboard", "History"].contains(name) {
            let id = store.library.pastebins.first { $0.name == name }?.id ?? {
                let bin = Pastebin(name: name, symbol: "tray.full", colorName: "orange")
                store.upsertPastebin(bin)
                return bin.id
            }()
            binIDs[name] = id
            for uuid in uuids { membership[uuid, default: []].append(id) }
        }
        let existing = Set(store.library.clippings.map(\.contentHash))
        var added = 0
        for clip in result.clips {
            let hash = ClipBuilder.hash(clip.content)
            if existing.contains(hash) { continue }
            let bins = membership[clip.uuid] ?? []
            // Each clipping lives in one place: a pastebin if it was saved in one, otherwise History.
            let inHistory = bins.isEmpty
            store.add(clip.content, title: clip.title, source: (clip.sourceBundleID, clip.sourceName), createdAt: clip.createdAt,
                      copiedAt: clip.copiedAt, inHistory: inHistory, pastebins: bins)
            added += 1
        }
        alert.messageText = "Imported \(added) Clipping\(added == 1 ? "" : "s")"
        alert.informativeText = "\(binIDs.count) pastebin\(binIDs.count == 1 ? "" : "s") came along. Clippings already in PasteLens were skipped. History limits apply from now on, so raise “Clippings to keep” if you imported more than it allows."
        alert.runModal()
    }
}
