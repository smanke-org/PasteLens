import Foundation

/// Placeholders in snippets and filter templates.
///
///     {text}               the text a filter is working on
///     {clipboard}          what's on the clipboard now
///     {date} {time} {datetime} {weekday} {uuid}
///     {date:yyyy-MM-dd}    any date format
///     {date+3}             three days from today (also {date-1}, with or without a format after a colon)
///     {input:Name}         ask for a value before pasting; {input:Name=default} pre-fills it
///     {cursor}             where the insertion point ends up after pasting
///     {{ and }}            literal braces
public enum Template {
    public struct Expansion: Equatable, Sendable {
        public var text: String
        /// How many characters before the end the insertion point should sit, for {cursor}.
        public var cursorFromEnd: Int?
    }

    public struct Field: Hashable, Sendable {
        public var name: String
        public var defaultValue: String
    }

    static let placeholder = try! NSRegularExpression(pattern: #"\{\{|\}\}|\{([a-zA-Z]+)([+-]\d+)?(?::([^}]*))?\}"#)

    /// The {input:…} fields a template asks for, in order, without repeats.
    public static func fields(in template: String) -> [Field] {
        var fields: [Field] = []
        for match in placeholder.matches(in: template, range: NSRange(template.startIndex..., in: template)) {
            guard let nameRange = Range(match.range(at: 1), in: template), template[nameRange] == "input",
                  let argRange = Range(match.range(at: 3), in: template) else { continue }
            let arg = String(template[argRange])
            let parts = arg.split(separator: "=", maxSplits: 1).map(String.init)
            let field = Field(name: parts.first ?? arg, defaultValue: parts.count > 1 ? parts[1] : "")
            if !fields.contains(where: { $0.name == field.name }) { fields.append(field) }
        }
        return fields
    }

    public static func expand(_ template: String, text: String = "", clipboard: String = "", inputs: [String: String] = [:],
                              now: Date = Date()) -> Expansion {
        var out = ""
        var cursorAt: Int?
        var last = template.startIndex
        for match in placeholder.matches(in: template, range: NSRange(template.startIndex..., in: template)) {
            guard let whole = Range(match.range, in: template) else { continue }
            out += template[last..<whole.lowerBound]
            last = whole.upperBound
            let token = String(template[whole])
            if token == "{{" { out += "{"; continue }
            if token == "}}" { out += "}"; continue }
            let name = Range(match.range(at: 1), in: template).map { String(template[$0]).lowercased() } ?? ""
            let offset = Range(match.range(at: 2), in: template).flatMap { Int(template[$0]) } ?? 0
            let arg = Range(match.range(at: 3), in: template).map { String(template[$0]) }
            let day = Calendar.current.date(byAdding: .day, value: offset, to: now) ?? now
            switch name {
            case "text": out += text
            case "clipboard": out += clipboard
            case "date": out += arg.map { format(day, $0) } ?? day.formatted(date: .abbreviated, time: .omitted)
            case "time": out += arg.map { format(day, $0) } ?? day.formatted(date: .omitted, time: .shortened)
            case "datetime": out += day.formatted(date: .abbreviated, time: .shortened)
            case "weekday": out += format(day, "EEEE")
            case "iso": out += ISO8601DateFormatter().string(from: day)
            case "uuid": out += UUID().uuidString
            case "cursor": cursorAt = out.count
            case "input":
                let parts = (arg ?? "").split(separator: "=", maxSplits: 1).map(String.init)
                let key = parts.first ?? ""
                out += inputs[key] ?? (parts.count > 1 ? parts[1] : "")
            default: out += token // Unknown placeholders stay as typed.
            }
        }
        out += template[last...]
        return Expansion(text: out, cursorFromEnd: cursorAt.map { out.count - $0 })
    }

    static func format(_ date: Date, _ pattern: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }
}
