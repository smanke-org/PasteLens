import Foundation

/// The filter steps that are plain text transformations.
public enum TextOps {
    public static func apply(_ step: FilterStep, to text: String) throws -> String {
        switch step.kind {
        case .changeCase: return changeCase(text, FilterStep.CaseStyle(rawValue: step.choice) ?? .lower)
        case .encode: return try encode(text, FilterStep.Encoding(rawValue: step.choice) ?? .base64, decode: step.flag1)
        case .findReplace: return try findReplace(text, find: step.text1, replace: step.text2, regex: step.flag1,
                                                  caseSensitive: step.flag2, firstOnly: step.choice == 1)
        case .extract: return try extract(text, FilterStep.ExtractKind(rawValue: step.choice) ?? .urls,
                                          pattern: step.text1, template: step.text2)
        case .lines: return lines(text, FilterStep.LinesOp(rawValue: step.choice) ?? .trim, separator: step.text1)
        case .sort: return sort(text, FilterStep.SortOrder(rawValue: step.choice) ?? .ascending, caseSensitive: step.flag1)
        case .quote: return quote(text, prefix: step.text1, suffix: step.text2, eachLine: step.flag1)
        case .wrap: return step.flag1 ? unwrap(text) : wrap(text, column: step.number > 0 ? step.number : 72)
        case .lineEnds: return lineEnds(text, FilterStep.LineEnding(rawValue: step.choice) ?? .lf)
        case .punctuation: return step.flag1 ? straightPunctuation(text) : smartPunctuation(text)
        case .plainText: return text
        case .json: return try json(text, FilterStep.JSONOp(rawValue: step.choice) ?? .pretty)
        case .markdownToHTML: return Markdown.html(from: text)
        case .stripHTML: return stripHTML(text)
        case .template: return Template.expand(step.text1, text: text, clipboard: "").text
        case .translate, .ai, .javascript, .shell, .appScript:
            throw FilterError("\(step.kind.label) needs the app.")
        }
    }

    // MARK: Case

    static let smallWords: Set<String> = ["a", "an", "and", "as", "at", "but", "by", "for", "in", "nor", "of", "on",
                                          "or", "so", "the", "to", "up", "yet", "via", "vs"]

    public static func changeCase(_ text: String, _ style: FilterStep.CaseStyle) -> String {
        switch style {
        case .upper: return text.uppercased()
        case .lower: return text.lowercased()
        case .title: return titleCase(text)
        case .sentence: return sentenceCase(text)
        case .camel, .pascal, .snake, .kebab, .constant:
            return text.components(separatedBy: "\n").map { line in
                let words = identifierWords(line)
                switch style {
                case .camel: return words.enumerated().map { $0 == 0 ? $1.lowercased() : $1.lowercased().capitalizedFirst }.joined()
                case .pascal: return words.map { $0.lowercased().capitalizedFirst }.joined()
                case .snake: return words.map { $0.lowercased() }.joined(separator: "_")
                case .kebab: return words.map { $0.lowercased() }.joined(separator: "-")
                default: return words.map { $0.uppercased() }.joined(separator: "_")
                }
            }.joined(separator: "\n")
        }
    }

    /// Splits "someHTTPValue_two-three" into ["some", "HTTP", "Value", "two", "three"].
    static func identifierWords(_ text: String) -> [String] {
        var words: [String] = []
        var current = ""
        let chars = Array(text)
        for (i, c) in chars.enumerated() {
            guard c.isLetter || c.isNumber else {
                if !current.isEmpty { words.append(current); current = "" }
                continue
            }
            if !current.isEmpty, c.isUppercase {
                let prev = chars[i - 1]
                let nextLower = i + 1 < chars.count && chars[i + 1].isLowercase
                if prev.isLowercase || prev.isNumber || (prev.isUppercase && nextLower) {
                    words.append(current)
                    current = ""
                }
            }
            current.append(c)
        }
        if !current.isEmpty { words.append(current) }
        return words
    }

    static func titleCase(_ text: String) -> String {
        text.components(separatedBy: "\n").map { line in
            let parts = line.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
            let lastIndex = parts.lastIndex { !$0.isEmpty } ?? 0
            return parts.enumerated().map { index, word in
                let lower = word.lowercased()
                if index != 0 && index != lastIndex && smallWords.contains(lower) { return lower }
                // Leave words that already mix case (iPhone, McDonald) alone.
                if word.dropFirst().contains(where: \.isUppercase) && word.contains(where: \.isLowercase) { return word }
                return lower.capitalizedFirst
            }.joined(separator: " ")
        }.joined(separator: "\n")
    }

    static func sentenceCase(_ text: String) -> String {
        var result = ""
        var capitalizeNext = true
        for c in text.lowercased() {
            if capitalizeNext, c.isLetter {
                result += c.uppercased()
                capitalizeNext = false
            } else {
                result.append(c)
            }
            if ".!?\n".contains(c) { capitalizeNext = true }
        }
        return result.replacingOccurrences(of: " i ", with: " I ")
    }

    // MARK: Encoding

    public static func encode(_ text: String, _ encoding: FilterStep.Encoding, decode: Bool) throws -> String {
        switch (encoding, decode) {
        case (.base64, false): return Data(text.utf8).base64EncodedString()
        case (.base64, true):
            let cleaned = text.filter { !$0.isWhitespace }
            var padded = cleaned.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            while padded.count % 4 != 0 { padded += "=" }
            guard let data = Data(base64Encoded: padded) else { throw FilterError("That isn't valid Base64.") }
            guard let s = String(data: data, encoding: .utf8) else { throw FilterError("The decoded bytes aren't text.") }
            return s
        case (.hex, false): return Data(text.utf8).map { String(format: "%02x", $0) }.joined()
        case (.hex, true):
            let digits = text.filter(\.isHexDigit)
            guard digits.count % 2 == 0 else { throw FilterError("Odd number of hex digits.") }
            var bytes: [UInt8] = []
            var index = digits.startIndex
            while index < digits.endIndex {
                let next = digits.index(index, offsetBy: 2)
                bytes.append(UInt8(digits[index..<next], radix: 16)!)
                index = next
            }
            guard let s = String(bytes: bytes, encoding: .utf8) else { throw FilterError("The decoded bytes aren't text.") }
            return s
        case (.htmlEntities, false): return HTMLEntities.encode(text)
        case (.htmlEntities, true): return HTMLEntities.decode(text)
        case (.url, false):
            var allowed = CharacterSet.alphanumerics
            allowed.insert(charactersIn: "-._~")
            return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
        case (.url, true):
            return text.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? text
        }
    }

    // MARK: Find and extract

    public static func findReplace(_ text: String, find: String, replace: String, regex: Bool, caseSensitive: Bool,
                                   firstOnly: Bool = false) throws -> String {
        guard !find.isEmpty else { return text }
        let replacement = unescape(replace)
        if regex {
            var options: NSRegularExpression.Options = [.anchorsMatchLines]
            if !caseSensitive { options.insert(.caseInsensitive) }
            let re: NSRegularExpression
            do { re = try NSRegularExpression(pattern: find, options: options) } catch {
                throw FilterError("The regular expression isn't valid.")
            }
            let range = firstOnly ? (re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))?.range ?? NSRange(location: NSNotFound, length: 0))
                : NSRange(text.startIndex..., in: text)
            guard range.location != NSNotFound else { return text }
            return re.stringByReplacingMatches(in: text, range: range, withTemplate: replacement)
        }
        let needle = unescape(find)
        let options: String.CompareOptions = caseSensitive ? [] : [.caseInsensitive]
        if firstOnly {
            guard let r = text.range(of: needle, options: options) else { return text }
            return text.replacingCharacters(in: r, with: replacement)
        }
        return text.replacingOccurrences(of: needle, with: replacement, options: options)
    }

    /// Lets plain find and replace fields say \n, \t and \\.
    static func unescape(_ s: String) -> String {
        guard s.contains("\\") else { return s }
        var out = ""
        var escaping = false
        for c in s {
            if escaping {
                switch c {
                case "n": out += "\n"
                case "t": out += "\t"
                case "r": out += "\r"
                case "\\": out += "\\"
                case "$": out += "\\$"
                default: out += "\\" + String(c)
                }
                escaping = false
            } else if c == "\\" {
                escaping = true
            } else {
                out.append(c)
            }
        }
        if escaping { out += "\\" }
        return out
    }

    public static func extract(_ text: String, _ kind: FilterStep.ExtractKind, pattern: String, template: String) throws -> String {
        let range = NSRange(text.startIndex..., in: text)
        switch kind {
        case .urls, .phoneNumbers:
            let type: NSTextCheckingResult.CheckingType = kind == .urls ? .link : .phoneNumber
            let detector = try NSDataDetector(types: type.rawValue)
            return detector.matches(in: text, range: range).compactMap { match -> String? in
                if kind == .urls {
                    guard let url = match.url, url.scheme != "mailto" else { return nil }
                    return Range(match.range, in: text).map { String(text[$0]) }
                }
                return match.phoneNumber
            }.uniqued().joined(separator: "\n")
        case .emails:
            let re = try NSRegularExpression(pattern: #"[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}"#, options: .caseInsensitive)
            return re.matches(in: text, range: range).compactMap { Range($0.range, in: text).map { String(text[$0]) } }
                .uniqued().joined(separator: "\n")
        case .regex:
            guard !pattern.isEmpty else { return "" }
            let re: NSRegularExpression
            do { re = try NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) } catch {
                throw FilterError("The regular expression isn't valid.")
            }
            let tmpl = template.isEmpty ? "$0" : unescape(template)
            return re.matches(in: text, range: range).map { re.replacementString(for: $0, in: text, offset: 0, template: tmpl) }
                .joined(separator: "\n")
        }
    }

    /// Matches for the editor's regex tester.
    public static func regexMatches(_ pattern: String, in text: String, caseSensitive: Bool) -> Result<[Range<String.Index>], FilterError> {
        guard !pattern.isEmpty else { return .success([]) }
        guard let re = try? NSRegularExpression(pattern: pattern, options: caseSensitive ? [.anchorsMatchLines] : [.anchorsMatchLines, .caseInsensitive]) else {
            return .failure(FilterError("Invalid regular expression"))
        }
        return .success(re.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { Range($0.range, in: text) })
    }

    // MARK: Lines

    static func splitLines(_ text: String) -> [String] {
        text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
    }

    public static func lines(_ text: String, _ op: FilterStep.LinesOp, separator: String) -> String {
        let lines = splitLines(text)
        switch op {
        case .trim: return lines.map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: "\n")
        case .trimLeading: return lines.map { String($0.drop(while: { $0 == " " || $0 == "\t" })) }.joined(separator: "\n")
        case .trimTrailing: return lines.map { String($0.reversed().drop(while: { $0 == " " || $0 == "\t" }).reversed()) }.joined(separator: "\n")
        case .removeEmpty: return lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.joined(separator: "\n")
        case .removeDuplicates: return lines.uniqued().joined(separator: "\n")
        case .reverse: return lines.reversed().joined(separator: "\n")
        case .number:
            let width = String(lines.count).count
            return lines.enumerated().map { String(repeating: " ", count: width - String($0 + 1).count) + "\($0 + 1). \($1)" }.joined(separator: "\n")
        case .removeNumbering:
            let re = try! NSRegularExpression(pattern: #"^\s*(\d+[.)]|[-*•])[ \t]+"#)
            return lines.map { re.stringByReplacingMatches(in: $0, range: NSRange($0.startIndex..., in: $0), withTemplate: "") }.joined(separator: "\n")
        case .join: return lines.filter { !$0.isEmpty }.joined(separator: unescape(separator.isEmpty ? " " : separator))
        case .collapseSpaces:
            let re = try! NSRegularExpression(pattern: #"[ \t\x{00A0}]{2,}"#)
            return re.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: " ")
        }
    }

    public static func sort(_ text: String, _ order: FilterStep.SortOrder, caseSensitive: Bool) -> String {
        let lines = splitLines(text)
        let compare: (String, String) -> Bool = { a, b in
            caseSensitive ? a < b : a.localizedStandardCompare(b) == .orderedAscending
        }
        switch order {
        case .ascending: return lines.sorted(by: compare).joined(separator: "\n")
        case .descending: return lines.sorted(by: compare).reversed().joined(separator: "\n")
        case .numeric:
            func value(_ s: String) -> Double {
                let digits = s.drop { !$0.isNumber && $0 != "-" && $0 != "." }.prefix { $0.isNumber || $0 == "." || $0 == "-" }
                return Double(digits) ?? .infinity
            }
            return lines.sorted { value($0) < value($1) }.joined(separator: "\n")
        case .length: return lines.sorted { $0.count < $1.count }.joined(separator: "\n")
        case .wordsInLine:
            return lines.map { $0.split(separator: " ").map(String.init).sorted(by: compare).joined(separator: " ") }.joined(separator: "\n")
        case .shuffle: return lines.shuffled().joined(separator: "\n")
        }
    }

    public static func quote(_ text: String, prefix: String, suffix: String, eachLine: Bool) -> String {
        let p = unescape(prefix), s = unescape(suffix)
        guard eachLine else { return p + text + s }
        return splitLines(text).map { p + $0 + s }.joined(separator: "\n")
    }

    public static func wrap(_ text: String, column: Int) -> String {
        splitLines(text).map { line -> String in
            guard line.count > column else { return line }
            var out: [String] = []
            var current = ""
            for word in line.split(separator: " ", omittingEmptySubsequences: false) {
                if !current.isEmpty && current.count + 1 + word.count > column {
                    out.append(current)
                    current = String(word)
                } else {
                    current += current.isEmpty ? String(word) : " " + word
                }
            }
            out.append(current)
            return out.joined(separator: "\n")
        }.joined(separator: "\n")
    }

    /// Joins hard-wrapped lines into paragraphs; blank lines and list items stay breaks.
    public static func unwrap(_ text: String) -> String {
        var paragraphs: [String] = []
        var current: [String] = []
        let listItem = try! NSRegularExpression(pattern: #"^\s*([-*•>]|\d+[.)])\s"#)
        for line in splitLines(text) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                if !current.isEmpty { paragraphs.append(current.joined(separator: " ")); current = [] }
                paragraphs.append("")
            } else if listItem.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil {
                if !current.isEmpty { paragraphs.append(current.joined(separator: " ")) }
                current = [line]
            } else {
                current.append(current.isEmpty ? line : trimmed)
            }
        }
        if !current.isEmpty { paragraphs.append(current.joined(separator: " ")) }
        return paragraphs.joined(separator: "\n")
    }

    public static func lineEnds(_ text: String, _ ending: FilterStep.LineEnding) -> String {
        splitLines(text).joined(separator: ending.string)
    }

    // MARK: Punctuation

    public static func smartPunctuation(_ text: String) -> String {
        var out = ""
        let chars = Array(text)
        for (i, c) in chars.enumerated() {
            let prev: Character? = i > 0 ? chars[i - 1] : nil
            let opening = prev == nil || prev!.isWhitespace || "([{<—–-".contains(prev!)
            switch c {
            case "\"": out += opening ? "\u{201C}" : "\u{201D}"
            case "'": out += opening ? "\u{2018}" : "\u{2019}"
            default: out.append(c)
            }
        }
        return out.replacingOccurrences(of: "---", with: "\u{2014}")
            .replacingOccurrences(of: "--", with: "\u{2014}")
            .replacingOccurrences(of: "...", with: "\u{2026}")
    }

    public static func straightPunctuation(_ text: String) -> String {
        var s = text
        for (from, to) in [("\u{201C}", "\""), ("\u{201D}", "\""), ("\u{201E}", "\""), ("\u{00AB}", "\""), ("\u{00BB}", "\""),
                           ("\u{2018}", "'"), ("\u{2019}", "'"), ("\u{201A}", "'"), ("\u{2014}", "--"), ("\u{2013}", "-"),
                           ("\u{2026}", "..."), ("\u{00A0}", " ")] {
            s = s.replacingOccurrences(of: from, with: to)
        }
        return s
    }

    // MARK: JSON and HTML

    public static func json(_ text: String, _ op: FilterStep.JSONOp) throws -> String {
        switch op {
        case .pretty, .minify:
            guard let data = text.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
                throw FilterError("That isn't valid JSON.")
            }
            var options: JSONSerialization.WritingOptions = [.fragmentsAllowed, .withoutEscapingSlashes]
            if op == .pretty { options.formUnion([.prettyPrinted, .sortedKeys]) }
            let out = try JSONSerialization.data(withJSONObject: object, options: options)
            return String(decoding: out, as: UTF8.self)
        case .escape:
            let data = try JSONSerialization.data(withJSONObject: text, options: [.fragmentsAllowed, .withoutEscapingSlashes])
            return String(String(decoding: data, as: UTF8.self).dropFirst().dropLast())
        case .unescape:
            let wrapped = text.hasPrefix("\"") ? text : "\"\(text)\""
            guard let data = wrapped.data(using: .utf8),
                  let s = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? String else {
                throw FilterError("That isn't a valid JSON string.")
            }
            return s
        }
    }

    public static func stripHTML(_ text: String) -> String {
        var s = text
        for pattern in [#"(?is)<(script|style)\b.*?</\1>"#, #"(?i)<br\s*/?>"#, #"(?i)</(p|div|li|h[1-6]|tr)>"#] {
            let re = try! NSRegularExpression(pattern: pattern)
            s = re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: pattern.contains("script") ? "" : "\n")
        }
        let tags = try! NSRegularExpression(pattern: "<[^>]+>")
        s = tags.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "")
        s = HTMLEntities.decode(s)
        let blank = try! NSRegularExpression(pattern: #"\n{3,}"#)
        s = blank.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "\n\n")
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public enum HTMLEntities {
    static let named: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}", "copy": "©", "reg": "®",
        "trade": "™", "hellip": "…", "mdash": "—", "ndash": "–", "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”",
        "bull": "•", "middot": "·", "deg": "°", "euro": "€", "pound": "£", "yen": "¥", "cent": "¢", "sect": "§",
        "para": "¶", "times": "×", "divide": "÷", "laquo": "«", "raquo": "»",
    ]

    public static func encode(_ text: String) -> String {
        var out = ""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&#39;"
            default:
                if scalar.value > 127 { out += "&#\(scalar.value);" } else { out.unicodeScalars.append(scalar) }
            }
        }
        return out
    }

    public static func decode(_ text: String) -> String {
        guard text.contains("&") else { return text }
        let re = try! NSRegularExpression(pattern: "&(#[0-9]+|#[xX][0-9a-fA-F]+|[a-zA-Z]+);")
        var result = ""
        var last = text.startIndex
        for match in re.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let whole = Range(match.range, in: text), let name = Range(match.range(at: 1), in: text) else { continue }
            result += text[last..<whole.lowerBound]
            let entity = String(text[name])
            var replacement: String?
            if entity.hasPrefix("#x") || entity.hasPrefix("#X") {
                replacement = UInt32(entity.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String($0) }
            } else if entity.hasPrefix("#") {
                replacement = UInt32(entity.dropFirst()).flatMap(Unicode.Scalar.init).map { String($0) }
            } else {
                replacement = named[entity]
            }
            result += replacement ?? String(text[whole])
            last = whole.upperBound
        }
        result += text[last...]
        return result
    }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
