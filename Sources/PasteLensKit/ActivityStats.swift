import Foundation

/// What the Activity graph counts.
public enum ActivityKind: String, CaseIterable, Codable, Sendable {
    /// Something copied and recorded in History (copying the same thing again counts too).
    case copy
    /// A paste PasteLens made: Quick Paste, the History window, the menu, Stack, snippets,
    /// typing text out, Shortcuts, the command-line tool and MCP.
    case paste
}

/// How far back the Activity graph looks. It widens as PasteLens collects more days:
/// a week at first, then 30, 90 and 180 days, then a year.
public enum StatsRange: Int, CaseIterable, Sendable {
    case week = 7, month = 30, quarter = 90, halfYear = 180, year = 365

    public var days: Int { rawValue }

    /// How the bars are grouped: a bar per day up to 30 days, per week for 90 and 180
    /// days, per month for a year.
    public var bucket: StatsBucket {
        switch self {
        case .week, .month: .day
        case .quarter, .halfYear: .week
        case .year: .month
        }
    }

    public var title: String {
        switch self {
        case .week: "last 7 days"
        case .month: "last 30 days"
        case .quarter: "last 90 days"
        case .halfYear: "last 180 days"
        case .year: "last year"
        }
    }

    /// The smallest range that covers `span` days of data (counting the first day and
    /// today); more than 180 days shows a year.
    public static func covering(span: Int) -> StatsRange {
        allCases.first { span <= $0.days } ?? .year
    }
}

public enum StatsBucket: Sendable { case day, week, month }

/// One bar on the Activity graph: a span of days and each Mac's count in it.
public struct StatsBar: Equatable, Identifiable, Sendable {
    public var start: Date
    /// Exclusive.
    public var end: Date
    /// Device ID → count, for the stacked segments.
    public var counts: [String: Int]
    public var id: Date { start }
    public var total: Int { counts.values.reduce(0, +) }

    public init(start: Date, end: Date, counts: [String: Int] = [:]) {
        self.start = start
        self.end = end
        self.counts = counts
    }
}

/// Turns per-day counts into the bars for the Activity graph.
public enum ActivityStats {
    /// The range to show, given the first day anything was recorded.
    public static func range(firstDay: Date?, today: Date, calendar: Calendar = .current) -> StatsRange {
        guard let firstDay else { return .week }
        let start = calendar.startOfDay(for: firstDay), end = calendar.startOfDay(for: today)
        let span = (calendar.dateComponents([.day], from: start, to: end).day ?? 0) + 1
        return StatsRange.covering(span: span)
    }

    /// The bar edges for `range`, ending today. Weeks are counted back from today so the
    /// last bar always includes it; months are calendar months, the current one partial.
    public static func edges(range: StatsRange, today: Date, calendar: Calendar = .current) -> [Date] {
        let todayStart = calendar.startOfDay(for: today)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: todayStart)!
        let firstDay = calendar.date(byAdding: .day, value: -(range.days - 1), to: todayStart)!
        switch range.bucket {
        case .day:
            return (0...range.days).map { calendar.date(byAdding: .day, value: $0, to: firstDay)! }
        case .week:
            let weeks = Int((Double(range.days) / 7).rounded(.up))
            return (0...weeks).reversed().map { calendar.date(byAdding: .day, value: -7 * $0, to: tomorrow)! }
        case .month:
            let thisMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: todayStart))!
            return (0...11).reversed().map { calendar.date(byAdding: .month, value: -$0, to: thisMonth)! } + [tomorrow]
        }
    }

    /// Bars covering `range` and ending today, each split by Mac.
    /// - Parameter logs: device ID → that Mac's log.
    public static func bars(logs: [String: ActivityLog], kind: ActivityKind, range: StatsRange, today: Date,
                            calendar: Calendar = .current) -> [StatsBar] {
        let edges = edges(range: range, today: today, calendar: calendar)
        var bars = zip(edges, edges.dropFirst()).map { StatsBar(start: $0, end: $1) }
        for (device, log) in logs {
            for (day, count) in log.counts(kind: kind, calendar: calendar) where count > 0 {
                let start = calendar.startOfDay(for: day)
                guard start >= edges.first!, start < edges.last! else { continue }
                if let index = bars.firstIndex(where: { start >= $0.start && start < $0.end }) {
                    bars[index].counts[device, default: 0] += count
                }
            }
        }
        return bars
    }
}

/// The per-day counts PasteLens keeps for the Activity graph: numbers only, never what was
/// copied or pasted. Days are stored as "yyyy-MM-dd" in the Mac's time zone.
public struct ActivityLog: Codable, Equatable, Sendable {
    /// The first day anything was recorded, even if that day has since been trimmed.
    public var firstDay: String?
    /// Day → kind (an `ActivityKind` raw value) → count.
    public var days: [String: [String: Int]]
    /// Kind → count since counting began, kept apart from `days` because old days are trimmed.
    public var lifetime: [String: Int]

    public init(firstDay: String? = nil, days: [String: [String: Int]] = [:], lifetime: [String: Int] = [:]) {
        self.firstDay = firstDay
        self.days = days
        self.lifetime = lifetime
    }

    public var isEmpty: Bool { firstDay == nil }

    public func lifetime(_ kind: ActivityKind) -> Int { lifetime[kind.rawValue] ?? 0 }

    public static func key(for date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    public static func date(for key: String, calendar: Calendar = .current) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    public mutating func record(_ kind: ActivityKind, count: Int = 1, at date: Date = Date(), calendar: Calendar = .current) {
        guard count > 0 else { return }
        let day = Self.key(for: date, calendar: calendar)
        lifetime[kind.rawValue, default: 0] += count
        days[day, default: [:]][kind.rawValue, default: 0] += count
        if firstDay.map({ day < $0 }) ?? true { firstDay = day }
    }

    /// Drops days older than `keepDays`, so the record stays small. `firstDay` and the
    /// lifetime totals are kept, so the graph's range still reflects how long PasteLens
    /// has been in use.
    public mutating func trim(keepDays: Int = 400, now: Date = Date(), calendar: Calendar = .current) {
        guard let cutoff = calendar.date(byAdding: .day, value: -keepDays, to: calendar.startOfDay(for: now)) else { return }
        let cutoffKey = Self.key(for: cutoff, calendar: calendar)
        days = days.filter { $0.key >= cutoffKey }
    }

    /// Counts per day for one kind.
    public func counts(kind: ActivityKind, calendar: Calendar = .current) -> [Date: Int] {
        var result: [Date: Int] = [:]
        for (key, perKind) in days {
            guard let count = perKind[kind.rawValue], count > 0, let date = Self.date(for: key, calendar: calendar) else { continue }
            result[date, default: 0] += count
        }
        return result
    }

    /// The earliest first day among several Macs, so the graph's range reflects the Mac that
    /// has used PasteLens longest.
    public static func earliestFirstDay(_ logs: some Sequence<ActivityLog>) -> String? {
        logs.compactMap(\.firstDay).min()
    }
}
