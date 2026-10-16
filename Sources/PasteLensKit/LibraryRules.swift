import Foundation

/// How long history is kept. Pinned clippings and those saved into a pastebin are kept regardless.
public struct RetentionPolicy: Equatable, Sendable {
    /// Keep at most this many clippings in history; 0 keeps them all.
    public var maxClippings: Int
    /// Forget history older than this many days; 0 keeps it forever.
    public var maxDays: Int

    public init(maxClippings: Int, maxDays: Int) {
        self.maxClippings = maxClippings
        self.maxDays = maxDays
    }

    /// The ids to drop from history, oldest first.
    public func expired(in clippings: [Clipping], now: Date = Date()) -> [UUID] {
        let history = clippings.filter(\.inHistory).sorted { $0.copiedAt > $1.copiedAt }
        var drop: [UUID] = []
        var kept = 0
        for clip in history {
            if clip.pinned { kept += 1; continue }
            let tooOld = maxDays > 0 && now.timeIntervalSince(clip.copiedAt) > Double(maxDays) * 86_400
            let tooMany = maxClippings > 0 && kept >= maxClippings
            if tooOld || tooMany { drop.append(clip.id) } else { kept += 1 }
        }
        return drop
    }

    /// Parses what someone typed into the "clippings to keep" field: a whole number, with
    /// separators allowed. Returns nil for anything else.
    public static func parseCount(_ text: String) -> Int? {
        let cleaned = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: "_", with: "").replacingOccurrences(of: " ", with: "")
        if cleaned.isEmpty { return nil }
        guard let n = Int(cleaned), n >= 0, n <= 1_000_000 else { return nil }
        return n
    }
}

/// Search that tolerates typos and skipped letters: every word typed must appear, either
/// as a substring or as an in-order subsequence of a word in the text.
public enum FuzzySearch {
    public static func score(_ query: String, in text: String) -> Double? {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return 1 }
        let haystack = text.lowercased()
        var total = 0.0
        for word in words {
            if let range = haystack.range(of: word) {
                // Earlier matches and word starts rank higher.
                let atStart = range.lowerBound == haystack.startIndex || !haystack[haystack.index(before: range.lowerBound)].isLetter
                total += atStart ? 3 : 2
            } else if word.count >= 3, subsequenceMatch(word, in: haystack) {
                total += 1
            } else {
                return nil
            }
        }
        return total
    }

    /// Whether `needle`'s letters appear in order within a single word-ish window of the text.
    static func subsequenceMatch(_ needle: String, in haystack: String) -> Bool {
        let maxSpan = needle.count * 3
        let chars = Array(haystack)
        let target = Array(needle)
        var start = 0
        while start < chars.count {
            guard let first = chars[start...].firstIndex(of: target[0]) else { return false }
            var i = first, j = 0
            while i < chars.count, j < target.count, i - first < maxSpan {
                if chars[i] == target[j] { j += 1 }
                i += 1
            }
            if j == target.count { return true }
            start = first + 1
        }
        return false
    }
}

/// Builds clipping metadata from content.
public enum ClipBuilder {
    public static let previewLimit = 2_048

    public static func make(from content: ClipContent, source: (bundleID: String?, name: String?), origin: String,
                            imageSize: (Int, Int)? = nil, now: Date = Date()) -> Clipping {
        let types = content.types
        let text = content.plainText
        var kind: ClipKind = .other
        var preferred = types.first ?? UTI.plainText
        var preview = ""

        let fileURLs = content.representations.filter { $0.type == UTI.fileURL }
            .compactMap { String(data: $0.data, encoding: .utf8).flatMap(URL.init(string:)) }
        if !fileURLs.isEmpty {
            kind = .file
            preferred = UTI.fileURL
            preview = fileURLs.map { $0.isFileURL ? $0.path : $0.absoluteString }.joined(separator: "\n")
        } else if let text, !text.isEmpty {
            preview = String(text.prefix(previewLimit))
            preferred = types.first { UTI.textTypes.contains($0) } ?? UTI.plainText
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if ColorText.parse(trimmed) != nil {
                kind = .color
            } else if isURL(trimmed) {
                kind = .url
            } else if types.contains(UTI.rtf) || types.contains(UTI.rtfd) || types.contains(UTI.html) {
                kind = .richText
                preferred = types.first { [UTI.rtfd, UTI.rtf, UTI.html].contains($0) } ?? preferred
            } else {
                kind = .text
            }
        } else if let image = types.first(where: { UTI.imageTypes.contains($0) }) {
            kind = .image
            preferred = image
        } else if types.contains(UTI.url), let data = content.data(for: UTI.url), let s = String(data: data, encoding: .utf8) {
            kind = .url
            preview = s
            preferred = UTI.url
        }

        var clip = Clipping(createdAt: now, kind: kind, types: types, preferredType: preferred, sizeBytes: content.sizeBytes,
                            previewText: preview, textLength: text?.count ?? preview.count,
                            contentHash: hash(content), origin: origin)
        clip.sourceBundleID = source.bundleID
        clip.sourceName = source.name
        if let imageSize { clip.imageWidth = imageSize.0; clip.imageHeight = imageSize.1 }
        return clip
    }

    static func isURL(_ s: String) -> Bool {
        guard !s.contains(where: \.isWhitespace), s.count < 4_000, let url = URL(string: s), let scheme = url.scheme?.lowercased() else { return false }
        return ["http", "https", "ftp", "mailto", "file", "ssh", "x-apple.systempreferences"].contains(scheme) && (url.host != nil || scheme == "mailto")
    }

    /// Hash of the content that matters for "is this the same thing again": text when there
    /// is text (so the same words from different apps match), otherwise every byte.
    public static func hash(_ content: ClipContent) -> String {
        if let text = content.plainText, !text.isEmpty { return SyncCrypto.sha256Hex(Data(text.utf8)) }
        var all = Data()
        for rep in content.representations.sorted(by: { $0.type < $1.type }) where rep.type != UTI.source {
            all.append(Data(rep.type.utf8))
            all.append(rep.data)
        }
        return SyncCrypto.sha256Hex(all)
    }
}
