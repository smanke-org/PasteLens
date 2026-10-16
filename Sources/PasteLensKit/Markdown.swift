import Foundation

/// A small Markdown to HTML converter: headings, paragraphs, emphasis, inline and fenced
/// code, links, images, block quotes, ordered and unordered lists, and rules.
public enum Markdown {
    public static func html(from markdown: String) -> String {
        var html: [String] = []
        var paragraph: [String] = []
        var listTag: String?
        var quote: [String] = []
        var fence: [String]?

        func flushParagraph() {
            if !paragraph.isEmpty { html.append("<p>\(inline(paragraph.joined(separator: "\n")))</p>"); paragraph = [] }
        }
        func closeList() {
            if let tag = listTag { html.append("</\(tag)>"); listTag = nil }
        }
        func flushQuote() {
            if !quote.isEmpty { html.append("<blockquote>\n\(Markdown.html(from: quote.joined(separator: "\n")))\n</blockquote>"); quote = [] }
        }

        let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        for line in lines {
            if var code = fence {
                if line.hasPrefix("```") {
                    html.append("<pre><code>\(HTMLEntities.encode(code.joined(separator: "\n")))</code></pre>")
                    fence = nil
                } else {
                    code.append(line)
                    fence = code
                }
                continue
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") { flushParagraph(); closeList(); flushQuote(); fence = []; continue }
            if trimmed.hasPrefix(">") {
                flushParagraph(); closeList()
                quote.append(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces))
                continue
            }
            flushQuote()
            if trimmed.isEmpty { flushParagraph(); closeList(); continue }
            if let level = headingLevel(trimmed) {
                flushParagraph(); closeList()
                let content = trimmed.dropFirst(level).trimmingCharacters(in: .whitespaces)
                html.append("<h\(level)>\(inline(content))</h\(level)>")
                continue
            }
            if ["---", "***", "___"].contains(trimmed.replacingOccurrences(of: " ", with: "")) {
                flushParagraph(); closeList(); html.append("<hr>"); continue
            }
            if let item = listItem(trimmed) {
                flushParagraph()
                if listTag != item.tag { closeList(); html.append("<\(item.tag)>"); listTag = item.tag }
                html.append("<li>\(inline(item.text))</li>")
                continue
            }
            closeList()
            paragraph.append(trimmed)
        }
        if let code = fence { html.append("<pre><code>\(HTMLEntities.encode(code.joined(separator: "\n")))</code></pre>") }
        flushParagraph(); closeList(); flushQuote()
        return html.joined(separator: "\n")
    }

    static func headingLevel(_ line: String) -> Int? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        return hashes
    }

    static func listItem(_ line: String) -> (tag: String, text: String)? {
        if let first = line.first, "-*+".contains(first), line.dropFirst().first == " " {
            return ("ul", String(line.dropFirst(2)))
        }
        let digits = line.prefix(while: \.isNumber)
        if !digits.isEmpty, line.dropFirst(digits.count).hasPrefix(". ") {
            return ("ol", String(line.dropFirst(digits.count + 2)))
        }
        return nil
    }

    static func inline(_ text: String) -> String {
        // Code spans first, so nothing inside them is touched.
        var codes: [String] = []
        var s = replace(#"`([^`]+)`"#, in: text) { groups in
            codes.append("<code>\(HTMLEntities.encode(groups[1]))</code>")
            return "\u{0}\(codes.count - 1)\u{0}"
        }
        s = s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        s = replace(#"!\[([^\]]*)\]\(([^)\s]+)\)"#, in: s) { "<img src=\"\($0[2])\" alt=\"\($0[1])\">" }
        s = replace(#"\[([^\]]+)\]\(([^)\s]+)\)"#, in: s) { "<a href=\"\($0[2])\">\($0[1])</a>" }
        s = replace(#"(\*\*|__)(.+?)\1"#, in: s) { "<strong>\($0[2])</strong>" }
        s = replace(#"(?<![*\w])([*_])(?!\s)(.+?)(?<!\s)\1(?![*\w])"#, in: s) { "<em>\($0[2])</em>" }
        s = replace(#"~~(.+?)~~"#, in: s) { "<del>\($0[1])</del>" }
        s = s.replacingOccurrences(of: "  \n", with: "<br>\n")
        s = replace("\u{0}(\\d+)\u{0}", in: s) { codes[Int($0[1])!] }
        return s
    }

    static func replace(_ pattern: String, in text: String, with transform: ([String]) -> String) -> String {
        let re = try! NSRegularExpression(pattern: pattern)
        var result = ""
        var last = text.startIndex
        for match in re.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let whole = Range(match.range, in: text) else { continue }
            result += text[last..<whole.lowerBound]
            let groups = (0..<match.numberOfRanges).map { i in Range(match.range(at: i), in: text).map { String(text[$0]) } ?? "" }
            result += transform(groups)
            last = whole.upperBound
        }
        result += text[last...]
        return result
    }
}
