import Foundation

/// A named chain of steps that turns one text into another before it is pasted.
public struct Filter: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var details: String
    public var group: String
    public var steps: [FilterStep]
    public var showInQuickPaste: Bool
    public var hotKey: StoredHotKey?
    public var updatedAt: Date
    /// Stable key for filters PasteLens ships, so an update can tell them apart from yours.
    public var builtInKey: String?

    public init(id: UUID = UUID(), name: String, details: String = "", group: String = "", steps: [FilterStep],
                builtInKey: String? = nil) {
        self.id = id
        self.name = name
        self.details = details
        self.group = group
        self.steps = steps
        self.showInQuickPaste = true
        self.updatedAt = Date()
        self.builtInKey = builtInKey
    }

    /// Whether every step runs on its own, without the app's services (translation, AI, scripts).
    public var isLocal: Bool { steps.allSatisfy(\.kind.isLocal) }
}

/// One operation in a filter. Options are generic slots whose meaning depends on `kind`,
/// which keeps the stored form flat and the editor simple.
public struct FilterStep: Codable, Hashable, Identifiable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case changeCase, encode, findReplace, extract, lines, sort, quote, template, wrap, lineEnds,
             punctuation, plainText, json, markdownToHTML, stripHTML, translate, ai, javascript, shell, appScript

        public var label: String {
            switch self {
            case .changeCase: "Change Case"
            case .encode: "Encode / Decode"
            case .findReplace: "Find and Replace"
            case .extract: "Extract"
            case .lines: "Line Operations"
            case .sort: "Sort"
            case .quote: "Add Prefix / Suffix"
            case .template: "Template"
            case .wrap: "Wrap / Unwrap Lines"
            case .lineEnds: "Line Endings"
            case .punctuation: "Smart / Straight Punctuation"
            case .plainText: "Plain Text"
            case .json: "JSON"
            case .markdownToHTML: "Markdown to HTML"
            case .stripHTML: "Strip HTML"
            case .translate: "Translate"
            case .ai: "Apple Intelligence"
            case .javascript: "JavaScript"
            case .shell: "Shell Script"
            case .appScript: "Script from Application Scripts"
            }
        }

        public var help: String {
            switch self {
            case .changeCase: "UPPERCASE, lowercase, Title Case, Sentence case, or programmer styles like camelCase and snake_case."
            case .encode: "Base64, hexadecimal, HTML entities or URL percent encoding, in either direction."
            case .findReplace: "Replace text, optionally with a regular expression. Use $1, $2 for captured groups."
            case .extract: "Keep only the links, email addresses, phone numbers or regular-expression matches, one per line."
            case .lines: "Work a line at a time: trim, remove empty or duplicate lines, reverse, number, or join."
            case .sort: "Sort lines alphabetically, numerically, by length, or the words within each line."
            case .quote: "Put text before and after the clipping, or each line."
            case .template: "Place the text into a template. {text} is the text; {date}, {time} and {clipboard} work too."
            case .wrap: "Hard-wrap lines at a column, or unwrap hard-wrapped paragraphs."
            case .lineEnds: "Convert to Unix/macOS (LF), Windows (CR LF) or classic Mac (CR) line endings."
            case .punctuation: "Curly quotes, dashes and ellipses, or back to straight ASCII."
            case .plainText: "Drop styling, so only the text is pasted."
            case .json: "Pretty-print, minify, or escape text for use inside a JSON string."
            case .markdownToHTML: "Convert Markdown (headings, emphasis, links, lists, code) to HTML."
            case .stripHTML: "Remove HTML tags and decode entities."
            case .translate: "Translate on this Mac with Apple's Translation. The language pair must be downloaded."
            case .ai: "Summarize, rewrite or fix with Apple Intelligence's on-device model."
            case .javascript: "Run JavaScript. `text` holds the input; return the result."
            case .shell: "Run a shell script. The text arrives on standard input; standard output is the result."
            case .appScript: "Run a script you placed in PasteLens's Application Scripts folder, outside the sandbox."
            }
        }

        /// Runs inside PasteLensKit with no help from the app.
        public var isLocal: Bool { ![.translate, .ai, .appScript].contains(self) }
    }

    public enum CaseStyle: Int, CaseIterable, Sendable {
        case upper, lower, title, sentence, camel, pascal, snake, kebab, constant
        public var label: String {
            ["UPPERCASE", "lowercase", "Title Case", "Sentence case", "camelCase", "PascalCase", "snake_case", "kebab-case", "CONSTANT_CASE"][rawValue]
        }
    }

    public enum Encoding: Int, CaseIterable, Sendable {
        case base64, hex, htmlEntities, url
        public var label: String { ["Base64", "Hex", "HTML Entities", "URL"][rawValue] }
    }

    public enum ExtractKind: Int, CaseIterable, Sendable {
        case urls, emails, phoneNumbers, regex
        public var label: String { ["Links", "Email Addresses", "Phone Numbers", "Regular Expression"][rawValue] }
    }

    public enum LinesOp: Int, CaseIterable, Sendable {
        case trim, removeEmpty, removeDuplicates, reverse, number, removeNumbering, join, trimLeading, trimTrailing, collapseSpaces
        public var label: String {
            ["Trim Whitespace", "Remove Empty Lines", "Remove Duplicate Lines", "Reverse Order", "Number Lines",
             "Remove List Numbering", "Join Lines", "Trim Leading Whitespace", "Trim Trailing Whitespace", "Collapse Spaces"][rawValue]
        }
    }

    public enum SortOrder: Int, CaseIterable, Sendable {
        case ascending, descending, numeric, length, wordsInLine, shuffle
        public var label: String { ["A to Z", "Z to A", "Numeric", "By Length", "Words Within Each Line", "Shuffle"][rawValue] }
    }

    public enum LineEnding: Int, CaseIterable, Sendable {
        case lf, crlf, cr
        public var label: String { ["Unix / macOS (LF)", "Windows (CR LF)", "Classic Mac (CR)"][rawValue] }
        var string: String { ["\n", "\r\n", "\r"][rawValue] }
    }

    public enum JSONOp: Int, CaseIterable, Sendable {
        case pretty, minify, escape, unescape
        public var label: String { ["Pretty-Print", "Minify", "Escape as String", "Unescape String"][rawValue] }
    }

    public enum AIPreset: Int, CaseIterable, Sendable {
        case summarize, fixGrammar, rewrite, professional, friendly, shorter, longer, bullets, custom
        public var label: String {
            ["Summarize", "Fix Spelling and Grammar", "Rewrite", "Make Professional", "Make Friendly",
             "Make Shorter", "Make Longer", "Bullet Points", "Custom Prompt"][rawValue]
        }
        public var instruction: String {
            switch self {
            case .summarize: "Summarize the text in a few sentences."
            case .fixGrammar: "Fix spelling, grammar and punctuation. Keep the wording and meaning otherwise unchanged."
            case .rewrite: "Rewrite the text so it reads clearly and naturally. Keep its meaning."
            case .professional: "Rewrite the text in a concise, professional tone."
            case .friendly: "Rewrite the text in a warm, friendly tone."
            case .shorter: "Make the text noticeably shorter while keeping the key points."
            case .longer: "Expand the text with more detail while keeping its meaning and tone."
            case .bullets: "Turn the text into a list of short bullet points, one per line, each starting with \"- \"."
            case .custom: ""
            }
        }
    }

    public var id = UUID()
    public var kind: Kind
    /// Which variant (case style, encoding, line operation…).
    public var choice: Int = 0
    public var text1: String = ""
    public var text2: String = ""
    public var flag1: Bool = false
    public var flag2: Bool = false
    public var number: Int = 0

    public init(_ kind: Kind, choice: Int = 0, text1: String = "", text2: String = "", flag1: Bool = false,
                flag2: Bool = false, number: Int = 0) {
        self.kind = kind
        self.choice = choice
        self.text1 = text1
        self.text2 = text2
        self.flag1 = flag1
        self.flag2 = flag2
        self.number = number
    }

    enum CodingKeys: String, CodingKey { case id, kind, choice, text1, text2, flag1, flag2, number }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        kind = try c.decode(Kind.self, forKey: .kind)
        choice = try c.decodeIfPresent(Int.self, forKey: .choice) ?? 0
        text1 = try c.decodeIfPresent(String.self, forKey: .text1) ?? ""
        text2 = try c.decodeIfPresent(String.self, forKey: .text2) ?? ""
        flag1 = try c.decodeIfPresent(Bool.self, forKey: .flag1) ?? false
        flag2 = try c.decodeIfPresent(Bool.self, forKey: .flag2) ?? false
        number = try c.decodeIfPresent(Int.self, forKey: .number) ?? 0
    }

    /// A one-line description for lists.
    public var summary: String {
        switch kind {
        case .changeCase: return CaseStyle(rawValue: choice)?.label ?? kind.label
        case .encode: return "\(flag1 ? "Decode" : "Encode") \(Encoding(rawValue: choice)?.label ?? "")"
        case .findReplace: return "Replace \(flag1 ? "/\(text1)/" : "“\(text1)”") with “\(text2)”"
        case .extract: return "Extract \(ExtractKind(rawValue: choice)?.label ?? "")"
        case .lines: return LinesOp(rawValue: choice)?.label ?? kind.label
        case .sort: return "Sort \(SortOrder(rawValue: choice)?.label ?? "")"
        case .quote: return "Wrap \(flag1 ? "each line " : "")in “\(text1)…\(text2)”"
        case .template: return "Template “\(text1.prefix(30))”"
        case .wrap: return flag1 ? "Unwrap lines" : "Wrap at \(max(number, 1)) columns"
        case .lineEnds: return LineEnding(rawValue: choice)?.label ?? kind.label
        case .punctuation: return flag1 ? "Straight punctuation" : "Smart punctuation"
        case .json: return "JSON: \(JSONOp(rawValue: choice)?.label ?? "")"
        case .translate: return "Translate to \(Locale.current.localizedString(forLanguageCode: text1) ?? text1)"
        case .ai: return choice == AIPreset.custom.rawValue ? "AI: \(text1.prefix(40))" : "AI: \(AIPreset(rawValue: choice)?.label ?? "")"
        case .appScript: return "Run \(text1)"
        default: return kind.label
        }
    }
}

/// What the app supplies for the steps PasteLensKit can't run by itself.
public protocol FilterServices: Sendable {
    func translate(_ text: String, to language: String) async throws -> String
    func generate(_ text: String, instruction: String) async throws -> String
    func runApplicationScript(named name: String, input: String) async throws -> String
    /// Current clipboard text, for {clipboard} in templates.
    func clipboardText() async -> String
}

public struct FilterError: LocalizedError, Sendable {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public enum FilterRunner {
    /// Runs every step in order. Throws the first failure, naming its step.
    public static func run(_ filter: Filter, on text: String, services: FilterServices?) async throws -> String {
        try await run(filter.steps, on: text, services: services)
    }

    public static func run(_ steps: [FilterStep], on text: String, services: FilterServices?) async throws -> String {
        var current = text
        for (index, step) in steps.enumerated() {
            do {
                current = try await apply(step, to: current, services: services)
            } catch {
                throw FilterError("Step \(index + 1) (\(step.kind.label)): \(error.localizedDescription)")
            }
        }
        return current
    }

    public static func apply(_ step: FilterStep, to text: String, services: FilterServices?) async throws -> String {
        switch step.kind {
        case .translate:
            guard let services else { throw FilterError("Translation isn't available here.") }
            return try await services.translate(text, to: step.text1.isEmpty ? "en" : step.text1)
        case .ai:
            guard let services else { throw FilterError("Apple Intelligence isn't available here.") }
            let preset = FilterStep.AIPreset(rawValue: step.choice) ?? .rewrite
            let instruction = preset == .custom ? step.text1 : preset.instruction
            guard !instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw FilterError("The prompt is empty.") }
            return try await services.generate(text, instruction: instruction)
        case .appScript:
            guard let services else { throw FilterError("Application scripts aren't available here.") }
            return try await services.runApplicationScript(named: step.text1, input: text)
        case .shell:
            return try await ScriptRunner.shell(step.text1, input: text)
        case .javascript:
            return try ScriptRunner.javascript(step.text1, input: text)
        case .template:
            let clipboard = step.text1.contains("{clipboard}") ? await services?.clipboardText() ?? "" : ""
            return Template.expand(step.text1, text: text, clipboard: clipboard).text
        default:
            return try TextOps.apply(step, to: text)
        }
    }
}
