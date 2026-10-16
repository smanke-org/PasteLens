import Foundation

/// Spots copied text that looks like a secret: API keys and tokens, private keys,
/// payment card numbers, and one-time codes. Such clippings are masked, never synced,
/// and deleted after a short while.
public enum SensitiveScanner {
    public enum Finding: String, CaseIterable, Sendable {
        case privateKey, apiKey, jwt, cardNumber, oneTimeCode, password
        public var label: String {
            switch self {
            case .privateKey: "Private key"
            case .apiKey: "API key or token"
            case .jwt: "Web token"
            case .cardNumber: "Card number"
            case .oneTimeCode: "One-time code"
            case .password: "Password"
            }
        }
    }

    static let patterns: [(Finding, NSRegularExpression)] = ([
        (.privateKey, #"-----BEGIN (?:[A-Z]+ )?PRIVATE KEY-----"#),
        (.apiKey, #"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b"#),                         // AWS access key id
        (.apiKey, #"\bgh[pousr]_[A-Za-z0-9]{36,}\b"#),                         // GitHub
        (.apiKey, #"\bgithub_pat_[A-Za-z0-9_]{50,}\b"#),
        (.apiKey, #"\bsk-(?:ant-|proj-|live-|test-)?[A-Za-z0-9_\-]{20,}\b"#),   // Anthropic, OpenAI, Stripe-style
        (.apiKey, #"\b[rp]k_(?:live|test)_[A-Za-z0-9]{20,}\b"#),               // Stripe
        (.apiKey, #"\bxox[abprs]-[A-Za-z0-9\-]{10,}\b"#),                      // Slack
        (.apiKey, #"\bAIza[0-9A-Za-z_\-]{35}\b"#),                             // Google
        (.apiKey, #"\bglpat-[A-Za-z0-9_\-]{20,}\b"#),                          // GitLab
        (.apiKey, #"\bnpm_[A-Za-z0-9]{36}\b"#),
        (.apiKey, #"(?i)\b(?:api[_-]?key|secret|token|passwd|password)\s*[:=]\s*['"]?[A-Za-z0-9_\-/+=]{12,}"#),
        (.jwt, #"\beyJ[A-Za-z0-9_\-]{10,}\.eyJ[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}\b"#),
    ] as [(Finding, String)]).map { ($0.0, try! NSRegularExpression(pattern: $0.1)) }

    /// What kind of secret the text holds, if it looks like one. Only short-ish text is
    /// judged as a whole (a code or card number alone); longer text only by the patterns.
    public static func scan(_ text: String) -> Finding? {
        let range = NSRange(text.startIndex..., in: text)
        for (finding, re) in patterns where re.firstMatch(in: text, range: range) != nil { return finding }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count <= 40, !trimmed.contains("\n") else { return nil }
        let digits = trimmed.filter(\.isNumber)
        let onlyDigitsAndSeparators = trimmed.allSatisfy { $0.isNumber || $0 == " " || $0 == "-" }
        if onlyDigitsAndSeparators, (13...19).contains(digits.count), luhn(digits) { return .cardNumber }
        if onlyDigitsAndSeparators, (6...8).contains(digits.count), digits.count == trimmed.filter({ !$0.isWhitespace && $0 != "-" }).count,
           trimmed.count <= 9 { return .oneTimeCode }
        if looksLikePassword(trimmed) { return .password }
        return nil
    }

    static func luhn(_ digits: String) -> Bool {
        var sum = 0
        for (i, c) in digits.reversed().enumerated() {
            guard var d = c.wholeNumberValue else { return false }
            if i % 2 == 1 { d *= 2; if d > 9 { d -= 9 } }
            sum += d
        }
        return sum % 10 == 0
    }

    /// A single token of 12–64 characters with a symbol and at least two of upper, lower and digits, with
    /// enough entropy that it's unlikely to be a word, path or URL.
    static func looksLikePassword(_ s: String) -> Bool {
        guard (12...64).contains(s.count), !s.contains(" "), !s.contains("/"), !s.contains("@"), !s.contains("."),
              !s.hasPrefix("#") else { return false }
        let classes = [s.contains(where: \.isUppercase), s.contains(where: \.isLowercase), s.contains(where: \.isNumber),
                       s.contains(where: { !$0.isLetter && !$0.isNumber })].filter { $0 }.count
        // A symbol is required: CamelCaseNames2026 and other identifiers would match otherwise.
        guard classes >= 3, s.contains(where: { !$0.isLetter && !$0.isNumber && $0 != "_" && $0 != "-" }) else { return false }
        return entropyBits(s) >= 3.5
    }

    static func entropyBits(_ s: String) -> Double {
        var counts: [Character: Int] = [:]
        for c in s { counts[c, default: 0] += 1 }
        let n = Double(s.count)
        return counts.values.reduce(0) { $0 - (Double($1) / n) * log2(Double($1) / n) }
    }

    /// Text to show in place of a secret.
    public static func mask(_ text: String, finding: Finding?) -> String {
        let label = finding?.label ?? "Sensitive"
        let tail = text.trimmingCharacters(in: .whitespacesAndNewlines).suffix(4)
        return "\(label) ••••\(tail.count == 4 && text.count > 12 ? String(tail) : "")"
    }
}

/// Recognizes colors written as text: #rgb, #rrggbb, #rrggbbaa, rgb()/rgba(), hsl()/hsla().
public enum ColorText {
    public struct RGBA: Equatable, Sendable {
        public var r, g, b, a: Double
    }

    public static func parse(_ text: String) -> RGBA? {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard s.count <= 40 else { return nil }
        if s.hasPrefix("#") || (s.count == 6 && s.allSatisfy(\.isHexDigit) && s.contains(where: \.isNumber) && s.contains(where: \.isLetter)) {
            let hex = s.hasPrefix("#") ? String(s.dropFirst()) : s
            guard hex.allSatisfy(\.isHexDigit) else { return nil }
            func comp(_ str: Substring) -> Double { Double(Int(str, radix: 16) ?? 0) / 255 }
            switch hex.count {
            case 3, 4:
                let chars = Array(hex).map { String(repeating: $0, count: 2) }
                return RGBA(r: comp(Substring(chars[0])), g: comp(Substring(chars[1])), b: comp(Substring(chars[2])),
                            a: chars.count == 4 ? comp(Substring(chars[3])) : 1)
            case 6, 8:
                let a = Array(hex)
                func pair(_ i: Int) -> Substring { Substring(String(a[i...i + 1])) }
                return RGBA(r: comp(pair(0)), g: comp(pair(2)), b: comp(pair(4)), a: hex.count == 8 ? comp(pair(6)) : 1)
            default: return nil
            }
        }
        let re = try! NSRegularExpression(pattern: #"^(rgba?|hsla?)\(\s*([\d.]+)(%?)\s*[, ]\s*([\d.]+)(%?)\s*[, ]\s*([\d.]+)(%?)\s*(?:[,/]\s*([\d.]+)(%?))?\s*\)$"#)
        guard let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
        func g(_ i: Int) -> String? { Range(m.range(at: i), in: s).map { String(s[$0]) } }
        guard let fn = g(1), let v1 = Double(g(2) ?? ""), let v2 = Double(g(4) ?? ""), let v3 = Double(g(6) ?? "") else { return nil }
        var alpha = 1.0
        if let av = g(8).flatMap(Double.init) { alpha = g(9) == "%" ? av / 100 : av }
        if fn.hasPrefix("rgb") {
            func c(_ v: Double, _ pct: String?) -> Double { pct == "%" ? v / 100 : v / 255 }
            let rgba = RGBA(r: c(v1, g(3)), g: c(v2, g(5)), b: c(v3, g(7)), a: alpha)
            return [rgba.r, rgba.g, rgba.b].allSatisfy { (0...1).contains($0) } ? rgba : nil
        }
        let h = v1.truncatingRemainder(dividingBy: 360) / 360, sat = v2 / 100, l = v3 / 100
        let q = l < 0.5 ? l * (1 + sat) : l + sat - l * sat, p = 2 * l - q
        func hue(_ t0: Double) -> Double {
            var t = t0
            if t < 0 { t += 1 }
            if t > 1 { t -= 1 }
            if t < 1.0 / 6 { return p + (q - p) * 6 * t }
            if t < 0.5 { return q }
            if t < 2.0 / 3 { return p + (q - p) * (2.0 / 3 - t) * 6 }
            return p
        }
        return RGBA(r: hue(h + 1.0 / 3), g: hue(h), b: hue(h - 1.0 / 3), a: alpha)
    }
}
