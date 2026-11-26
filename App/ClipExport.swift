import AppKit
import UniformTypeIdentifiers
import PasteLensKit

/// Turns clippings into files: dragging them to Finder, the Export… command and `pastelens clips export`.
///
/// Each clipping becomes a file of its own: text as .txt, rich text as .rtf, images as .png (PDFs
/// stay .pdf), links as .webloc, and copied files as copies of the originals. Combined, they become
/// one .txt with a divider between clippings.
enum ClipExport {
    /// One clipping's bytes, read on the main actor so the writing can happen anywhere.
    struct Job: Sendable {
        let name: String
        let kind: ClipKind
        let content: ClipContent
        let fallbackText: String
    }

    /// Above this many clippings, a drag lands in a folder of its own instead of loose files.
    static let folderThreshold = 1

    @MainActor static func jobs(_ ids: [UUID]) -> [Job] {
        let store = ClipStore.shared
        return ids.compactMap { id in
            guard let clip = store.clip(id) else { return nil }
            let content = store.content(for: id) ?? .text(clip.previewText)
            return Job(name: baseName(clip), kind: clip.kind, content: content, fallbackText: clip.previewText)
        }
    }

    /// The first ~40 characters of the title or text, then the date: "Meeting notes… 2026-11-26 14.03".
    static func baseName(_ clip: Clipping) -> String {
        let source = (clip.title?.isEmpty == false ? clip.title! : clip.previewText)
        var words = source.components(separatedBy: .newlines).first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
        if clip.kind == .file { words = URL(fileURLWithPath: words).deletingPathExtension().lastPathComponent }
        words = sanitize(words)
        if words.count > 40 { words = String(words.prefix(40)).trimmingCharacters(in: .whitespaces) + "…" }
        if words.isEmpty { words = clip.kind.label }
        return "\(words) \(stamp.string(from: clip.copiedAt))"
    }

    static func sanitize(_ s: String) -> String {
        let bad = CharacterSet(charactersIn: "/:\\\0").union(.controlCharacters)
        return s.unicodeScalars.map { bad.contains($0) ? " " : String($0) }.joined()
            .replacingOccurrences(of: " {2,}", with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ".")))
    }

    nonisolated(unsafe) private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH.mm"
        return f
    }()

    static func folderName(_ date: Date = Date()) -> String { "PasteLens Export \(stamp.string(from: date))" }

    // MARK: Writing

    /// Writes each job as its own file into `folder`. Returns the files written.
    @discardableResult
    static func write(_ jobs: [Job], into folder: URL) throws -> [URL] {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var used = Set<String>()
        var written: [URL] = []
        for job in jobs {
            written += try write(job, into: folder, used: &used)
        }
        return written
    }

    /// All jobs' text in one .txt.
    static func writeCombined(_ jobs: [Job], to url: URL) throws {
        let text = jobs.map { text(of: $0) }.joined(separator: "\n\n----------\n\n")
        try Data(text.utf8).write(to: url, options: .atomic)
    }

    static func text(of job: Job) -> String {
        if let t = job.content.plainText { return t }
        if let urls = fileURLs(job), !urls.isEmpty { return urls.map(\.path).joined(separator: "\n") }
        if let rtf = job.content.data(for: UTI.rtf),
           let s = NSAttributedString(rtf: rtf, documentAttributes: nil) { return s.string }
        return job.fallbackText
    }

    private static func fileURLs(_ job: Job) -> [URL]? {
        let urls = job.content.representations.filter { $0.type == UTI.fileURL }
            .compactMap { String(data: $0.data, encoding: .utf8).flatMap(URL.init(string:)) }
        return urls.isEmpty ? nil : urls
    }

    private static func unique(_ name: String, _ ext: String, in folder: URL, used: inout Set<String>) -> URL {
        var n = 1
        while true {
            let candidate = (n == 1 ? name : "\(name) \(n)") + (ext.isEmpty ? "" : ".\(ext)")
            let url = folder.appendingPathComponent(candidate)
            if !used.contains(candidate.lowercased()) && !FileManager.default.fileExists(atPath: url.path) {
                used.insert(candidate.lowercased())
                return url
            }
            n += 1
        }
    }

    private static func write(_ job: Job, into folder: URL, used: inout Set<String>) throws -> [URL] {
        let c = job.content
        // Copied files: copies of the originals, under their own names.
        if let urls = fileURLs(job) {
            var out: [URL] = []
            for src in urls where FileManager.default.fileExists(atPath: src.path) {
                let dest = unique(src.deletingPathExtension().lastPathComponent, src.pathExtension, in: folder, used: &used)
                try FileManager.default.copyItem(at: src, to: dest)
                out.append(dest)
            }
            if !out.isEmpty { return out }
            // The originals are gone: fall back to the list of paths.
        }
        func put(_ data: Data, _ ext: String) throws -> [URL] {
            let url = unique(job.name, ext, in: folder, used: &used)
            try data.write(to: url, options: .atomic)
            return [url]
        }
        switch job.kind {
        case .image:
            if let png = c.data(for: UTI.png) { return try put(png, "png") }
            if let pdf = c.data(for: UTI.pdf), c.data(for: UTI.tiff) == nil { return try put(pdf, "pdf") }
            for type in [UTI.tiff, UTI.jpeg, UTI.heic] {
                if let data = c.data(for: type), let rep = NSBitmapImageRep(data: data),
                   let png = rep.representation(using: .png, properties: [:]) { return try put(png, "png") }
            }
        case .richText:
            if let rtf = c.data(for: UTI.rtf) { return try put(rtf, "rtf") }
            if let rtfd = c.data(for: UTI.rtfd), let s = NSAttributedString(rtfd: rtfd, documentAttributes: nil),
               let rtf = s.rtf(from: NSRange(location: 0, length: s.length), documentAttributes: [:]) { return try put(rtf, "rtf") }
            if let html = c.data(for: UTI.html) { return try put(html, "html") }
        case .url:
            let link = c.data(for: UTI.url).flatMap { String(data: $0, encoding: .utf8) } ?? text(of: job)
            if let url = URL(string: link.trimmingCharacters(in: .whitespacesAndNewlines)), url.scheme != nil {
                let plist = try PropertyListSerialization.data(fromPropertyList: ["URL": url.absoluteString], format: .xml, options: 0)
                return try put(plist, "webloc")
            }
        default: break
        }
        return try put(Data(text(of: job).utf8), "txt")
    }

    // MARK: Drag

    /// A file representation for a drag to Finder. Nothing is written until the drop: then one
    /// clipping becomes one file, and several become a "PasteLens Export …" folder. Holding ⌥
    /// at the drop makes one combined .txt instead.
    @MainActor static func register(_ ids: [UUID], on provider: NSItemProvider) {
        let jobs = jobs(ids)
        guard !jobs.isEmpty else { return }
        let folder = jobs.count > folderThreshold
        provider.suggestedName = folder ? folderName() : jobs[0].name
        let type: UTType = folder ? .folder : .data
        provider.registerFileRepresentation(forTypeIdentifier: type.identifier, fileOptions: [], visibility: .all) { done in
            let combined = NSEvent.modifierFlags.contains(.option)
            let progress = Progress(totalUnitCount: Int64(jobs.count))
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let temp = FileManager.default.temporaryDirectory
                        .appendingPathComponent("PasteLensExport-\(UUID().uuidString)", isDirectory: true)
                    try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
                    let result: URL
                    if combined {
                        result = temp.appendingPathComponent((jobs.count == 1 ? jobs[0].name : folderName()) + ".txt")
                        try writeCombined(jobs, to: result)
                    } else if folder {
                        result = temp.appendingPathComponent(folderName(), isDirectory: true)
                        try write(jobs, into: result)
                    } else {
                        result = try write(jobs, into: temp).first ?? temp
                    }
                    progress.completedUnitCount = progress.totalUnitCount
                    done(result, false, nil)
                } catch {
                    done(nil, false, error)
                }
            }
            return progress
        }
    }

    // MARK: Export…

    /// Asks for a folder and writes the clippings into it.
    @MainActor static func exportWithPanel(_ ids: [UUID]) {
        guard !ids.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Export"
        panel.message = ids.count == 1 ? "Choose where to save the clipping." : "Choose where to save \(ids.count) clippings."
        NSApp.activate()
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        let jobs = jobs(ids)
        Task.detached {
            do {
                let files = try write(jobs, into: dest)
                await MainActor.run { NSWorkspace.shared.activateFileViewerSelecting(Array(files.prefix(50))) }
            } catch {
                await MainActor.run { presentError(error) }
            }
        }
    }
}
