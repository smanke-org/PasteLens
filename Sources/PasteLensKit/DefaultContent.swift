import Foundation

/// The filters, pastebins and snippets a new library starts with. Their ids are derived from
/// a fixed key, so the copies each Mac seeds are the same records and sync merges them
/// instead of showing two of everything.
public enum DefaultContent {
    public static func stableID(_ key: String) -> UUID {
        let hash = Array(SyncCrypto.sha256Hex(Data("PasteLens default \(key)".utf8)).prefix(32))
        let s = String(hash)
        let parts = [s.prefix(8), s.dropFirst(8).prefix(4), s.dropFirst(12).prefix(4), s.dropFirst(16).prefix(4), s.dropFirst(20)]
        return UUID(uuidString: parts.map(String.init).joined(separator: "-"))!
    }

    public static func filters() -> [Filter] {
        typealias S = FilterStep
        func f(_ key: String, _ name: String, _ group: String, _ details: String, _ steps: [S]) -> Filter {
            Filter(id: stableID("filter." + key), name: name, details: details, group: group, steps: steps, builtInKey: key)
        }
        return [
            f("plain", "Plain Text", "Formatting", "Paste without styling.", [S(.plainText)]),
            f("clean", "Clean Paste", "Formatting", "Plain text with curly quotes, real dashes and trimmed lines.",
              [S(.plainText), S(.lines, choice: S.LinesOp.trimTrailing.rawValue), S(.punctuation)]),
            f("smart", "Smart Punctuation", "Formatting", "Curly quotes, em dashes and ellipses.", [S(.punctuation)]),
            f("straight", "Straight Punctuation", "Formatting", "Plain ASCII quotes and dashes.", [S(.punctuation, flag1: true)]),

            f("upper", "UPPERCASE", "Case", "", [S(.changeCase, choice: S.CaseStyle.upper.rawValue)]),
            f("lower", "lowercase", "Case", "", [S(.changeCase, choice: S.CaseStyle.lower.rawValue)]),
            f("title", "Title Case", "Case", "", [S(.changeCase, choice: S.CaseStyle.title.rawValue)]),
            f("sentence", "Sentence case", "Case", "", [S(.changeCase, choice: S.CaseStyle.sentence.rawValue)]),
            f("camel", "camelCase", "Case", "", [S(.changeCase, choice: S.CaseStyle.camel.rawValue)]),
            f("snake", "snake_case", "Case", "", [S(.changeCase, choice: S.CaseStyle.snake.rawValue)]),
            f("kebab", "kebab-case", "Case", "", [S(.changeCase, choice: S.CaseStyle.kebab.rawValue)]),
            f("slug", "Slug", "Case", "Lowercase words joined by hyphens, for URLs.",
              [S(.plainText), S(.changeCase, choice: S.CaseStyle.lower.rawValue), S(.findReplace, text1: "'", text2: ""),
               S(.findReplace, text1: "[^a-z0-9]+", text2: "-", flag1: true), S(.findReplace, text1: "^-+|-+$", text2: "", flag1: true)]),

            f("trim", "Trim Whitespace", "Lines", "Remove spaces at the start and end of each line.", [S(.lines, choice: S.LinesOp.trim.rawValue)]),
            f("noempty", "Remove Empty Lines", "Lines", "", [S(.lines, choice: S.LinesOp.removeEmpty.rawValue)]),
            f("dedupe", "Remove Duplicate Lines", "Lines", "", [S(.lines, choice: S.LinesOp.removeDuplicates.rawValue)]),
            f("sort", "Sort Lines", "Lines", "", [S(.sort)]),
            f("reverse", "Reverse Lines", "Lines", "", [S(.lines, choice: S.LinesOp.reverse.rawValue)]),
            f("number", "Number Lines", "Lines", "", [S(.lines, choice: S.LinesOp.number.rawValue)]),
            f("unnumber", "Remove List Numbering", "Lines", "Strips 1. 2. and bullets from the start of lines.", [S(.lines, choice: S.LinesOp.removeNumbering.rawValue)]),
            f("oneline", "Single Line", "Lines", "Join everything into one line.",
              [S(.plainText), S(.lines, choice: S.LinesOp.trim.rawValue), S(.lines, choice: S.LinesOp.join.rawValue, text1: " ")]),
            f("unwrap", "Unwrap Paragraphs", "Lines", "Join hard-wrapped lines back into paragraphs.", [S(.wrap, flag1: true)]),
            f("wrap72", "Wrap at 72 Columns", "Lines", "", [S(.wrap, number: 72)]),
            f("whitespace", "Normalize Whitespace", "Lines", "Collapse runs of spaces, trim lines and drop empty ones.",
              [S(.lines, choice: S.LinesOp.collapseSpaces.rawValue), S(.lines, choice: S.LinesOp.trim.rawValue), S(.lines, choice: S.LinesOp.removeEmpty.rawValue)]),

            f("urls", "Extract Links", "Extract", "", [S(.extract, choice: S.ExtractKind.urls.rawValue)]),
            f("emails", "Extract Email Addresses", "Extract", "", [S(.extract, choice: S.ExtractKind.emails.rawValue)]),
            f("phones", "Extract Phone Numbers", "Extract", "", [S(.extract, choice: S.ExtractKind.phoneNumbers.rawValue)]),

            f("b64e", "Base64 Encode", "Encode", "", [S(.encode, choice: S.Encoding.base64.rawValue)]),
            f("b64d", "Base64 Decode", "Encode", "", [S(.encode, choice: S.Encoding.base64.rawValue, flag1: true)]),
            f("urle", "URL Encode", "Encode", "", [S(.encode, choice: S.Encoding.url.rawValue)]),
            f("urld", "URL Decode", "Encode", "", [S(.encode, choice: S.Encoding.url.rawValue, flag1: true)]),
            f("htmle", "HTML Entities Encode", "Encode", "", [S(.encode, choice: S.Encoding.htmlEntities.rawValue)]),
            f("htmld", "HTML Entities Decode", "Encode", "", [S(.encode, choice: S.Encoding.htmlEntities.rawValue, flag1: true)]),
            f("hexe", "Hex Encode", "Encode", "", [S(.encode, choice: S.Encoding.hex.rawValue)]),
            f("hexd", "Hex Decode", "Encode", "", [S(.encode, choice: S.Encoding.hex.rawValue, flag1: true)]),

            f("jsonpretty", "Format JSON", "Code", "", [S(.json, choice: S.JSONOp.pretty.rawValue)]),
            f("jsonmin", "Minify JSON", "Code", "", [S(.json, choice: S.JSONOp.minify.rawValue)]),
            f("jsonesc", "Escape for JSON String", "Code", "", [S(.json, choice: S.JSONOp.escape.rawValue)]),
            f("md2html", "Markdown to HTML", "Code", "", [S(.markdownToHTML)]),
            f("striphtml", "Strip HTML", "Code", "", [S(.stripHTML)]),
            f("mdquote", "Markdown Quote", "Code", "", [S(.quote, text1: "> ", flag1: true)]),
            f("mdlink", "Markdown Link", "Code", "Turn a URL into [url](url).", [S(.template, text1: "[{text}]({text})")]),
            f("mdlist", "Bulleted List", "Code", "", [S(.lines, choice: S.LinesOp.removeEmpty.rawValue), S(.quote, text1: "- ", flag1: true)]),
            f("htmllist", "HTML List", "Code", "",
              [S(.lines, choice: S.LinesOp.removeEmpty.rawValue), S(.quote, text1: "\\t<li>", text2: "</li>", flag1: true), S(.quote, text1: "<ul>\\n", text2: "\\n</ul>")]),
            f("codeblock", "Code Block", "Code", "Wrap in a fenced Markdown code block.", [S(.quote, text1: "```\\n", text2: "\\n```")]),
            f("wordcount", "Word Count", "Code", "Replace the text with its word, line and character counts.",
              [S(.javascript, text1: """
                const words = text.trim() ? text.trim().split(/\\s+/).length : 0;
                return `${words} words, ${text.split(/\\n/).length} lines, ${text.length} characters`;
                """)]),

            f("noemoji", "Remove Emoji", "Text", "",
              [S(.findReplace, text1: "[\\p{Extended_Pictographic}\\p{Emoji_Modifier}\\x{FE0F}\\x{200D}]+", text2: "", flag1: true)]),
            f("smileys", "Smileys to Emoji", "Text", "", [
                S(.findReplace, text1: ":-)", text2: "🙂"), S(.findReplace, text1: ":)", text2: "🙂"), S(.findReplace, text1: ":-(", text2: "🙁"),
                S(.findReplace, text1: ":(", text2: "🙁"), S(.findReplace, text1: ":D", text2: "😀", flag2: true), S(.findReplace, text1: ";)", text2: "😉"),
                S(.findReplace, text1: ":P", text2: "😛", flag2: true), S(.findReplace, text1: "<3", text2: "❤️"),
            ]),
            f("en", "Translate to English", "Language", "On-device translation.", [S(.translate, text1: "en")]),
            f("ai-sum", "Summarize", "Apple Intelligence", "", [S(.ai, choice: S.AIPreset.summarize.rawValue)]),
            f("ai-fix", "Fix Spelling and Grammar", "Apple Intelligence", "", [S(.ai, choice: S.AIPreset.fixGrammar.rawValue)]),
            f("ai-pro", "Make Professional", "Apple Intelligence", "", [S(.ai, choice: S.AIPreset.professional.rawValue)]),
            f("ai-short", "Make Shorter", "Apple Intelligence", "", [S(.ai, choice: S.AIPreset.shorter.rawValue)]),
            f("ai-bullets", "Bullet Points", "Apple Intelligence", "", [S(.ai, choice: S.AIPreset.bullets.rawValue)]),
        ]
    }

    public static func snippets() -> [Snippet] {
        let list = [
            Snippet(name: "Today's Date", abbreviation: ";date", template: "{date:yyyy-MM-dd}", group: "Dates"),
            Snippet(name: "Timestamp", abbreviation: ";now", template: "{date:yyyy-MM-dd HH:mm}", group: "Dates"),
            Snippet(name: "Email Signature", abbreviation: ";sig", template: "Best regards,\n{input:Your Name}", group: "Email"),
            Snippet(name: "Meeting Follow-up", template: "Hi {input:Name},\n\nThanks for meeting on {weekday}. As discussed, {cursor}\n\nBest,", group: "Email"),
        ]
        return list.map { var s = $0; s.id = stableID("snippet." + s.name); return s }
    }

    public static func pastebins() -> [Pastebin] {
        [Pastebin(id: stableID("pastebin.saved"), name: "Saved", symbol: "star", colorName: "yellow", order: 1)]
    }
}
