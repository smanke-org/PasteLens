import Foundation

/// A saved search that collects clippings automatically.
public struct SmartPastebin: Codable, Identifiable, Hashable, Sendable {
    public enum Match: String, Codable, CaseIterable, Sendable { case all, any }

    public var id: UUID
    public var name: String
    public var symbol: String
    public var colorName: String
    public var match: Match
    public var rules: [SmartRule]
    public var order: Double
    public var showInQuickPaste: Bool
    public var updatedAt: Date

    public init(id: UUID = UUID(), name: String, symbol: String = "sparkles.rectangle.stack", colorName: String = "purple",
                match: Match = .all, rules: [SmartRule], order: Double = 0) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.colorName = colorName
        self.match = match
        self.rules = rules
        self.order = order
        self.showInQuickPaste = true
        self.updatedAt = Date()
    }

    public func matches(_ clip: Clipping, now: Date = Date()) -> Bool {
        guard !rules.isEmpty else { return false }
        switch match {
        case .all: return rules.allSatisfy { $0.matches(clip, now: now) }
        case .any: return rules.contains { $0.matches(clip, now: now) }
        }
    }

    public static let defaults: [SmartPastebin] = [
        SmartPastebin(name: "Links", symbol: "link", colorName: "teal", rules: [SmartRule(field: .kind, op: .is, value: ClipKind.url.rawValue)], order: 1),
        SmartPastebin(name: "Images", symbol: "photo", colorName: "green", rules: [SmartRule(field: .kind, op: .is, value: ClipKind.image.rawValue)], order: 2),
        SmartPastebin(name: "Colors", symbol: "paintpalette", colorName: "pink", rules: [SmartRule(field: .kind, op: .is, value: ClipKind.color.rawValue)], order: 3),
        SmartPastebin(name: "Today", symbol: "calendar", colorName: "orange", rules: [SmartRule(field: .age, op: .lessThan, value: "1")], order: 4),
    ]
}

public struct SmartRule: Codable, Hashable, Identifiable, Sendable {
    public enum Field: String, Codable, CaseIterable, Sendable {
        case text, kind, sourceApp, note, size, length, age, type
        public var label: String {
            switch self {
            case .text: "Text"
            case .kind: "Kind"
            case .sourceApp: "Source App"
            case .note: "Note"
            case .size: "Size (KB)"
            case .length: "Text Length"
            case .age: "Age (days)"
            case .type: "Pasteboard Type"
            }
        }
        public var isNumeric: Bool { [.size, .length, .age].contains(self) }
        public var ops: [Op] {
            switch self {
            case .kind: [.is, .isNot]
            case .size, .length, .age: [.lessThan, .greaterThan, .is]
            default: [.contains, .doesNotContain, .beginsWith, .endsWith, .is, .isNot, .matchesRegex]
            }
        }
    }

    public enum Op: String, Codable, CaseIterable, Sendable {
        case contains, doesNotContain, beginsWith, endsWith, `is`, isNot, matchesRegex, lessThan, greaterThan
        public var label: String {
            switch self {
            case .contains: "contains"
            case .doesNotContain: "does not contain"
            case .beginsWith: "begins with"
            case .endsWith: "ends with"
            case .is: "is"
            case .isNot: "is not"
            case .matchesRegex: "matches regex"
            case .lessThan: "is less than"
            case .greaterThan: "is greater than"
            }
        }
    }

    public var id = UUID()
    public var field: Field
    public var op: Op
    public var value: String

    public init(field: Field, op: Op, value: String) {
        self.field = field
        self.op = op
        self.value = value
    }

    public func matches(_ clip: Clipping, now: Date = Date()) -> Bool {
        switch field {
        case .size: return compare(Double(clip.sizeBytes) / 1024)
        case .length: return compare(Double(clip.textLength))
        case .age: return compare(now.timeIntervalSince(clip.copiedAt) / 86_400)
        case .kind: return op == .isNot ? clip.kind.rawValue != value : clip.kind.rawValue == value
        case .text: return compare(clip.previewText + "\n" + (clip.ocrText ?? ""))
        case .sourceApp:
            // Matches the app's name or bundle id; a negative rule has to hold for both.
            let byName = compare(clip.sourceName ?? ""), byID = compare(clip.sourceBundleID ?? "")
            return op == .doesNotContain || op == .isNot ? byName && byID : byName || byID
        case .note: return compare(clip.note ?? "")
        case .type: return op == .doesNotContain || op == .isNot
            ? clip.types.allSatisfy { compare($0) }
            : clip.types.contains { compare($0) }
        }
    }

    private func compare(_ number: Double) -> Bool {
        guard let target = Double(value.trimmingCharacters(in: .whitespaces)) else { return false }
        switch op {
        case .lessThan: return number < target
        case .greaterThan: return number > target
        default: return abs(number - target) < 0.5
        }
    }

    private func compare(_ text: String) -> Bool {
        let t = text.lowercased(), v = value.lowercased()
        switch op {
        case .contains: return t.contains(v)
        case .doesNotContain: return !t.contains(v)
        case .beginsWith: return t.hasPrefix(v)
        case .endsWith: return t.hasSuffix(v)
        case .is: return t == v
        case .isNot: return t != v
        case .matchesRegex:
            guard let re = try? NSRegularExpression(pattern: value, options: [.caseInsensitive]) else { return false }
            return re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
        case .lessThan, .greaterThan: return false
        }
    }
}
