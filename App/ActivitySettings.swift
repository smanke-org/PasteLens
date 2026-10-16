import Charts
import PasteLensKit
import SwiftUI

/// One Mac on the Activity graphs.
struct ActivityMac: Identifiable {
    var id: String
    var name: String
    var status: String
    var log: ActivityLog
    var color: Color

    private static let palette: [Color] = [.blue, .orange, .green, .purple, .pink, .teal, .yellow, .brown, .indigo, .mint, .red, .cyan]

    /// This Mac first, then the others by name, each in its own color. Other Macs appear
    /// only while sync is on, once they run a version that shares its counts.
    @MainActor
    static func all() -> [ActivityMac] {
        let sync = SyncEngine.shared
        let others = sync.enabled ? sync.devices.filter { $0.activity != nil && $0.id != DeviceIdentity.id } : []
        var result = [ActivityMac(id: DeviceIdentity.id, name: DeviceIdentity.name, status: "This Mac",
                                  log: ActivityStore.shared.log, color: palette[0])]
        for (index, device) in others.enumerated() {
            result.append(ActivityMac(id: device.id, name: device.name,
                                      status: "Synced \(device.lastSeen.formatted(.relative(presentation: .named)))",
                                      log: device.activity ?? ActivityLog(), color: palette[(index + 1) % palette.count]))
        }
        return result
    }
}

/// Settings › Activity: how many times PasteLens copied and pasted over time, as two graphs.
/// They start at a week and widen to 30, 90 and 180 days, then a year, as days of data build
/// up. With sync on, each bar is split by Mac, one color per Mac.
struct ActivitySettings: View {
    @State private var store = ActivityStore.shared
    @State private var sync = SyncEngine.shared
    /// Kept on each Mac, not synced.
    @AppStorage("activity.showAllMacs", store: AppDefaults.store) private var showAllMacs = true

    var body: some View {
        let everyMac = ActivityMac.all()
        let allMacs = showAllMacs && everyMac.count > 1
        let shown = allMacs ? everyMac : Array(everyMac.prefix(1))

        Form {
            if everyMac.count > 1 {
                Section {
                    Picker("Show", selection: $showAllMacs) {
                        Text("This Mac").tag(false)
                        Text("All Macs").tag(true)
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                    .frame(maxWidth: .infinity)
                    if allMacs { ActivityLegend(macs: shown) }
                }
            }
            Section { ActivityGraph(kind: .copy, macs: shown, place: allMacs ? "on \(shown.count) Macs" : nil) }
            Section {
                ActivityGraph(kind: .paste, macs: shown, place: allMacs ? "on \(shown.count) Macs" : nil)
            } footer: {
                Text(ActivityGraph.explanation).font(.caption).foregroundStyle(.secondary)
            }
            ActivityMacsSection(macs: everyMac, syncOn: sync.enabled)
        }
        .formStyle(.grouped)
        .onAppear { if sync.enabled { sync.pull() } }
    }
}

/// History window › Activity, middle column: All Macs and each Mac, to choose what the graphs show.
struct ActivityMacList: View {
    @Bindable var state: MainState
    @State private var store = ActivityStore.shared
    @State private var sync = SyncEngine.shared

    var body: some View {
        let macs = ActivityMac.all()
        List(selection: Binding(get: { state.activityMac ?? "" }, set: { state.activityMac = ($0?.isEmpty ?? true) ? nil : $0 })) {
            if macs.count > 1 {
                row("All Macs", status: "\(macs.count) Macs", color: nil,
                    copies: macs.map { $0.log.lifetime(.copy) }.reduce(0, +), pastes: macs.map { $0.log.lifetime(.paste) }.reduce(0, +))
                    .tag("")
            }
            ForEach(macs) { mac in
                row(mac.name, status: mac.status, color: mac.color, copies: mac.log.lifetime(.copy), pastes: mac.log.lifetime(.paste))
                    .tag(macs.count > 1 ? mac.id : "")
            }
            if !sync.enabled {
                Text("Turn on sync to see your other Macs here.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .onAppear { if sync.enabled { sync.pull() } }
    }

    private func row(_ name: String, status: String, color: Color?, copies: Int, pastes: Int) -> some View {
        HStack(spacing: 8) {
            if let color { Circle().fill(color).frame(width: 9, height: 9) } else { Image(systemName: "desktopcomputer").foregroundStyle(.secondary) }
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                Text(status).font(.caption).foregroundStyle(.secondary)
                Text("\(copies.formatted()) copied · \(pastes.formatted()) pasted").font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .padding(.vertical, 2)
    }
}

/// History window › Activity, right column: both graphs for the Mac chosen in the middle.
struct ActivityDetail: View {
    @Bindable var state: MainState
    @State private var store = ActivityStore.shared
    @State private var sync = SyncEngine.shared

    var body: some View {
        let macs = ActivityMac.all()
        let shown = state.activityMac.flatMap { id in macs.first { $0.id == id } }.map { [$0] } ?? macs
        let place = shown.count > 1 ? "on \(shown.count) Macs" : macs.count > 1 ? "on \(shown[0].name)" : nil
        Form {
            if shown.count > 1 { Section { ActivityLegend(macs: shown) } }
            Section { ActivityGraph(kind: .copy, macs: shown, place: place) }
            Section {
                ActivityGraph(kind: .paste, macs: shown, place: place)
            } footer: {
                Text(ActivityGraph.explanation).font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// Every Mac's copies and pastes since it started counting.
struct ActivityMacsSection: View {
    var macs: [ActivityMac]
    var syncOn: Bool

    var body: some View {
        Section {
            ForEach(macs) { mac in
                LabeledContent {
                    Text("\(mac.log.lifetime(.copy).formatted()) copied · \(mac.log.lifetime(.paste).formatted()) pasted")
                        .monospacedDigit()
                } label: {
                    HStack(spacing: 6) {
                        Circle().fill(mac.color).frame(width: 9, height: 9)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(mac.name)
                            Text(mac.status).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        } header: {
            HStack {
                Text(macs.count > 1 ? "All Macs" : "This Mac")
                Spacer()
                if macs.count > 1 {
                    let copies = macs.map { $0.log.lifetime(.copy) }.reduce(0, +)
                    let pastes = macs.map { $0.log.lifetime(.paste) }.reduce(0, +)
                    Text("\(copies.formatted()) copied · \(pastes.formatted()) pasted").monospacedDigit()
                }
            }
        } footer: {
            Group {
                if !syncOn {
                    Text("Turn on sync to see copies and pastes from every Mac that uses PasteLens, each in its own color.")
                } else if macs.count == 1 {
                    Text("Your other Macs appear here once they run PasteLens 1.0.14 or later with sync on.")
                } else {
                    Text("Each Mac's totals since PasteLens started counting there. Counts travel encrypted with the rest of your synced data.")
                }
            }
            .font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct ActivityLegend: View {
    var macs: [ActivityMac]

    var body: some View {
        HStack(spacing: 14) {
            ForEach(macs) { mac in
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 2).fill(mac.color).frame(width: 10, height: 10)
                    Text(mac.name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// One graph (copies or pastes), with each bar split by Mac.
struct ActivityGraph: View {
    var kind: ActivityKind
    var macs: [ActivityMac]
    /// "on 3 Macs", "on MacBook Air", or nil when there's only this Mac.
    var place: String?
    @State private var hovered: Date?

    static let explanation = "The graphs widen as you use PasteLens: 7 days at first, then 30, 90 and 180 days, then a year. Pastes are the ones PasteLens makes, from Quick Paste, History, the menu, Stack, snippets, Shortcuts and the command line. Only the numbers are kept, never what you copied, and clearing History doesn't reset them."

    var body: some View {
        let now = Date()
        let firstDay = ActivityLog.earliestFirstDay(macs.map(\.log)).flatMap { ActivityLog.date(for: $0) }
        let range = ActivityStats.range(firstDay: firstDay, today: now)
        let bars = ActivityStats.bars(logs: Dictionary(uniqueKeysWithValues: macs.map { ($0.id, $0.log) }), kind: kind,
                                      range: range, today: now)
        let total = bars.map(\.total).reduce(0, +)
        let hoveredBar = hovered.flatMap { date in bars.first { date >= $0.start && date < $0.end } }

        VStack(alignment: .leading, spacing: 6) {
            Text(kind == .copy ? "Copies" : "Pastes").font(.headline)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(total, format: .number)
                    .font(.system(size: 30, weight: .semibold))
                    .monospacedDigit()
                Text("\(noun(total)) in the \(range.title)\(place.map { " \($0)" } ?? "")")
                    .foregroundStyle(.secondary)
            }
            chart(bars, range: range, hovered: hoveredBar)
                .frame(height: 170)
                .padding(.top, 8)
            Text(hoveredBar.map { readout($0, range: range) } ?? "Hover over a bar to see its count.")
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(hoveredBar == nil ? .tertiary : .primary)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(.vertical, 4)
    }

    /// One segment of a stacked bar.
    private struct Segment: Identifiable {
        var bar: StatsBar
        var mac: ActivityMac
        var from: Int
        var to: Int
        var isTop: Bool
        var id: String { "\(bar.start.timeIntervalSince1970)-\(mac.id)" }
    }

    private func segments(_ bars: [StatsBar]) -> [Segment] {
        var result: [Segment] = []
        for bar in bars {
            var base = 0
            let present = macs.filter { (bar.counts[$0.id] ?? 0) > 0 }
            for (index, mac) in present.enumerated() {
                let count = bar.counts[mac.id] ?? 0
                result.append(Segment(bar: bar, mac: mac, from: base, to: base + count, isTop: index == present.count - 1))
                base += count
            }
        }
        return result
    }

    @ViewBuilder
    private func chart(_ bars: [StatsBar], range: StatsRange, hovered: StatsBar?) -> some View {
        let peak = bars.map(\.total).max() ?? 0
        Chart(segments(bars)) { segment in
            // A ranged bar spans exactly its days; trimming each end leaves a gap between bars.
            let gap = segment.bar.end.timeIntervalSince(segment.bar.start) * 0.12
            RectangleMark(xStart: .value("From", segment.bar.start.addingTimeInterval(gap)),
                          xEnd: .value("To", segment.bar.end.addingTimeInterval(-gap)),
                          yStart: .value("Count", segment.from), yEnd: .value("Count", segment.to))
                .foregroundStyle(segment.mac.color.opacity(hovered == nil || hovered == segment.bar ? 1 : 0.4))
                .clipShape(UnevenRoundedRectangle(topLeadingRadius: segment.isTop ? 4 : 0, topTrailingRadius: segment.isTop ? 4 : 0))
                .accessibilityLabel(readout(segment.bar, range: range))
        }
        .chartXScale(domain: (bars.first?.start ?? Date())...(bars.last?.end ?? Date()))
        .chartXSelection(value: $hovered)
        .chartYScale(domain: 0...max(peak, 4))
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine().foregroundStyle(Color.secondary.opacity(0.25))
                AxisValueLabel().foregroundStyle(Color.secondary)
            }
        }
        .chartXAxis {
            AxisMarks(values: xTicks(bars, range: range)) { value in
                AxisValueLabel(centered: false) {
                    if let date = value.as(Date.self) { Text(axisLabel(date, range: range)) }
                }
                .foregroundStyle(Color.secondary)
            }
        }
        .overlay {
            if peak == 0 {
                Text(kind == .copy ? "Nothing copied yet." : "Nothing pasted yet. Press \(Preferences.shared.hotKey(.quickPaste)?.display ?? "the Quick Paste shortcut") to paste from History.")
                    .font(.callout).foregroundStyle(.secondary)
                    .padding(8)
                    .background(.background, in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    /// Where the x-axis labels go: every day for a week, then about six evenly spaced ticks.
    private func xTicks(_ bars: [StatsBar], range: StatsRange) -> [Date] {
        guard !bars.isEmpty else { return [] }
        let step: Int
        switch range {
        case .week: step = 1
        case .month: step = 5
        case .quarter: step = 2
        case .halfYear: step = 4
        case .year: step = 2
        }
        // Counted from the left, and never on the last bar, whose label would run off the edge.
        let last = range == .week ? bars.count - 1 : bars.count - 2
        return stride(from: 0, through: last, by: step).map { bars[$0].start }
    }

    private func axisLabel(_ date: Date, range: StatsRange) -> String {
        switch range {
        case .week: date.formatted(.dateTime.weekday(.abbreviated))
        case .month, .quarter, .halfYear: date.formatted(.dateTime.month(.abbreviated).day())
        case .year: date.formatted(.dateTime.month(.abbreviated))
        }
    }

    private func noun(_ count: Int) -> String {
        switch kind {
        case .copy: count == 1 ? "copy" : "copies"
        case .paste: count == 1 ? "paste" : "pastes"
        }
    }

    private func readout(_ bar: StatsBar, range: StatsRange) -> String {
        let lastDay = bar.end.addingTimeInterval(-1)
        let when: String
        switch range.bucket {
        case .day: when = bar.start.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
        case .week: when = "\(bar.start.formatted(.dateTime.month(.abbreviated).day())) – \(lastDay.formatted(.dateTime.month(.abbreviated).day()))"
        case .month: when = bar.start.formatted(.dateTime.month(.wide).year())
        }
        var text = "\(when): \(bar.total.formatted()) \(noun(bar.total))"
        if macs.count > 1, bar.total > 0 {
            let parts = macs.compactMap { mac in (bar.counts[mac.id] ?? 0) > 0 ? "\(mac.name) \(bar.counts[mac.id]!.formatted())" : nil }
            text += " (\(parts.joined(separator: ", ")))"
        }
        return text
    }
}
