import AppKit
import PasteLensKit
import SwiftUI
import Translation
import UniformTypeIdentifiers

// MARK: - Filters

struct FilterList: View {
    @Bindable var state: MainState
    @State private var store = ClipStore.shared
    @State private var importReport: String?

    var groups: [(String, [Filter])] { Self.groups(store.library.filters, query: state.query) }

    /// The filters shown for a search, grouped and in list order; the arrow keys walk them too.
    static func groups(_ filters: [Filter], query: String) -> [(String, [Filter])] {
        let filtered = filters.filter { query.isEmpty || FuzzySearch.score(query, in: "\($0.name) \($0.group)") != nil }
        return Dictionary(grouping: filtered) { $0.group.isEmpty ? "My Filters" : $0.group }
            .sorted { $0.key < $1.key }.map { ($0.key, $0.value.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) }
    }

    var body: some View {
        ScrollViewReader { proxy in
            List(selection: $state.selection) {
                ForEach(groups, id: \.0) { group, filters in
                    Section(group) {
                        ForEach(filters) { filter in
                            HStack {
                                Text(filter.name)
                                Spacer()
                                if let key = filter.hotKey { Text(key.display).font(.caption).foregroundStyle(.secondary) }
                            }
                            .tag(filter.id)
                            .contextMenu {
                                Button("Duplicate") { duplicate(filter) }
                                Button("Export…") { export(filter) }
                                Button("Delete", role: .destructive) { store.deleteFilter(filter.id) }
                            }
                        }
                    }
                }
            }
            .revealing(state.reveal, with: proxy)
        }
        .searchable(text: $state.query, placement: .toolbar, prompt: "Search Filters")
        .onDeleteCommand { for id in state.selection { store.deleteFilter(id) } }
        .toolbar {
            ToolbarItemGroup {
                Button { add() } label: { Label("New Filter", systemImage: "plus") }
                Menu {
                    Button("Import Filter Files…") { importFiles() }
                    Button("Restore Built-in Filters") { store.restoreDefaultFilters() }
                    Button("Open Application Scripts Folder") { ApplicationScripts.reveal() }
                } label: { Label("More", systemImage: "ellipsis.circle") }
            }
        }
        .alert("Import", isPresented: Binding(get: { importReport != nil }, set: { if !$0 { importReport = nil } })) {
            Button("OK") {}
        } message: { Text(importReport ?? "") }
        .navigationTitle("Filters")
    }

    func add() {
        let filter = Filter(name: "New Filter", steps: [FilterStep(.findReplace)])
        store.upsertFilter(filter)
        state.selection = [filter.id]
    }

    func duplicate(_ filter: Filter) {
        var copy = filter
        copy.id = UUID()
        copy.name += " Copy"
        copy.builtInKey = nil
        copy.hotKey = nil
        store.upsertFilter(copy)
        state.selection = [copy.id]
    }

    func export(_ filter: Filter) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = filter.name + ".pastelensfilter"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var clean = filter
        clean.hotKey = nil
        try? SyncMerge.encode(clean).write(to: url)
    }

    func importFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [UTType(filenameExtension: "pastebotfilter") ?? .data, UTType(filenameExtension: "pastelensfilter") ?? .data]
        guard panel.runModal() == .OK else { return }
        importReport = Importer.importFilters(panel.urls)
    }
}

struct FilterEditor: View {
    @State var filter: Filter
    @State private var store = ClipStore.shared
    @State private var sample = ""
    @State private var output = ""
    @State private var error: String?
    @State private var key: HotKey?
    @State private var runTask: Task<Void, Never>?

    var body: some View {
        HSplitView {
            Form {
                Section {
                    TextField("Name", text: $filter.name)
                    TextField("Group", text: $filter.group, prompt: Text("My Filters"))
                    TextField("Description", text: $filter.details, axis: .vertical).lineLimit(1...3)
                    Toggle("Show in Quick Paste", isOn: $filter.showInQuickPaste)
                    Toggle("Show in Menu Bar Menu", isOn: $filter.showInMenu)
                        .help("List this filter under Filters in PasteLens's menu bar menu. Choosing it there filters the clipboard and pastes the result.")
                    LabeledContent("Shortcut") { ShortcutRecorder(hotKey: $key) }
                }
                Section {
                    ForEach($filter.steps) { $step in
                        StepEditor(step: $step, sample: sample, onDelete: { filter.steps.removeAll { $0.id == step.id } },
                                   onMove: { move(step.id, $0) })
                    }
                    Menu {
                        ForEach(FilterStep.Kind.allCases, id: \.self) { kind in
                            Button(kind.label) { filter.steps.append(FilterStep(kind)) }
                        }
                    } label: { Label("Add Step", systemImage: "plus") }
                } header: {
                    Text("Steps run in order, each on the result of the one before.")
                }
            }
            .formStyle(.grouped)
            .frame(minWidth: 360)

            VStack(alignment: .leading, spacing: 6) {
                Text("Try It").font(.headline)
                Text("Before").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $sample).font(.body.monospaced()).frame(minHeight: 100).border(.separator)
                Text("After").font(.caption).foregroundStyle(.secondary)
                ScrollView {
                    Text(error ?? output).font(.body.monospaced()).foregroundStyle(error == nil ? .primary : Color.red)
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 100).padding(4).border(.separator)
            }
            .padding()
            .frame(minWidth: 240)
        }
        .onAppear {
            key = filter.hotKey.map(HotKey.init)
            sample = ClipStore.shared.recent(1).first.flatMap { FilterApplier.sourceText(for: $0) }.map { String($0.prefix(2000)) } ?? "Sample text"
            run()
        }
        .onChange(of: filter) { save(); run() }
        .onChange(of: sample) { run() }
        .onChange(of: key) { filter.hotKey = key?.stored }
    }

    func move(_ id: UUID, _ delta: Int) {
        guard let i = filter.steps.firstIndex(where: { $0.id == id }) else { return }
        let j = i + delta
        guard filter.steps.indices.contains(j) else { return }
        filter.steps.swapAt(i, j)
    }

    func save() {
        if store.library.filters.first(where: { $0.id == filter.id }) != filter { store.upsertFilter(filter) }
    }

    func run() {
        runTask?.cancel()
        let steps = filter.steps, input = sample
        runTask = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            do {
                let out = try await FilterRunner.run(steps, on: input, services: AppFilterServices())
                guard !Task.isCancelled else { return }
                output = out
                error = nil
            } catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription
            }
        }
    }
}

/// Options for one step, shown according to its kind.
struct StepEditor: View {
    @Binding var step: FilterStep
    let sample: String
    let onDelete: () -> Void
    let onMove: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(step.kind.label).font(.headline)
                Spacer()
                Button { onMove(-1) } label: { Image(systemName: "chevron.up") }.buttonStyle(.borderless)
                Button { onMove(1) } label: { Image(systemName: "chevron.down") }.buttonStyle(.borderless)
                Button(action: onDelete) { Image(systemName: "trash") }.buttonStyle(.borderless)
            }
            Text(step.kind.help).font(.caption).foregroundStyle(.secondary)
            options
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder var options: some View {
        switch step.kind {
        case .changeCase:
            Picker("Style", selection: $step.choice) { ForEach(FilterStep.CaseStyle.allCases, id: \.rawValue) { Text($0.label).tag($0.rawValue) } }
        case .encode:
            Picker("Format", selection: $step.choice) { ForEach(FilterStep.Encoding.allCases, id: \.rawValue) { Text($0.label).tag($0.rawValue) } }
            Picker("Direction", selection: $step.flag1) { Text("Encode").tag(false); Text("Decode").tag(true) }.pickerStyle(.segmented)
        case .findReplace:
            TextField("Find", text: $step.text1).font(.body.monospaced())
            TextField("Replace with", text: $step.text2).font(.body.monospaced())
            HStack {
                Toggle("Regular expression", isOn: $step.flag1)
                Toggle("Match case", isOn: $step.flag2)
                Picker("", selection: $step.choice) { Text("All").tag(0); Text("First only").tag(1) }.labelsHidden().fixedSize()
            }
            if step.flag1 { RegexTester(pattern: step.text1, caseSensitive: step.flag2, sample: sample) }
        case .extract:
            Picker("Keep", selection: $step.choice) { ForEach(FilterStep.ExtractKind.allCases, id: \.rawValue) { Text($0.label).tag($0.rawValue) } }
            if step.choice == FilterStep.ExtractKind.regex.rawValue {
                TextField("Pattern", text: $step.text1).font(.body.monospaced())
                TextField("Each match as", text: $step.text2, prompt: Text("$0")).font(.body.monospaced())
                RegexTester(pattern: step.text1, caseSensitive: true, sample: sample)
            }
        case .lines:
            Picker("Operation", selection: $step.choice) { ForEach(FilterStep.LinesOp.allCases, id: \.rawValue) { Text($0.label).tag($0.rawValue) } }
            if step.choice == FilterStep.LinesOp.join.rawValue { TextField("Separator", text: $step.text1, prompt: Text("space")) }
        case .sort:
            Picker("Order", selection: $step.choice) { ForEach(FilterStep.SortOrder.allCases, id: \.rawValue) { Text($0.label).tag($0.rawValue) } }
            Toggle("Case sensitive", isOn: $step.flag1)
        case .quote:
            TextField("Before", text: $step.text1).font(.body.monospaced())
            TextField("After", text: $step.text2).font(.body.monospaced())
            Toggle("Apply to each line", isOn: $step.flag1)
        case .template:
            TextField("Template", text: $step.text1, prompt: Text("[{text}]({clipboard})"), axis: .vertical).font(.body.monospaced()).lineLimit(1...6)
        case .wrap:
            Picker("", selection: $step.flag1) { Text("Wrap").tag(false); Text("Unwrap").tag(true) }.pickerStyle(.segmented).labelsHidden()
            if !step.flag1 {
                Stepper("At \(step.number > 0 ? step.number : 72) columns", value: Binding(get: { step.number > 0 ? step.number : 72 }, set: { step.number = $0 }), in: 10...400)
            }
        case .lineEnds:
            Picker("Convert to", selection: $step.choice) { ForEach(FilterStep.LineEnding.allCases, id: \.rawValue) { Text($0.label).tag($0.rawValue) } }
        case .punctuation:
            Picker("", selection: $step.flag1) { Text("Smart “curly”").tag(false); Text("Straight \"ASCII\"").tag(true) }.pickerStyle(.segmented).labelsHidden()
        case .json:
            Picker("Operation", selection: $step.choice) { ForEach(FilterStep.JSONOp.allCases, id: \.rawValue) { Text($0.label).tag($0.rawValue) } }
        case .translate:
            Picker("Into", selection: Binding(get: { step.text1.isEmpty ? "en" : step.text1 }, set: { step.text1 = $0 })) {
                ForEach(Languages.common, id: \.0) { code, name in Text(name).tag(code) }
            }
        case .ai:
            Picker("Task", selection: $step.choice) { ForEach(FilterStep.AIPreset.allCases, id: \.rawValue) { Text($0.label).tag($0.rawValue) } }
            if step.choice == FilterStep.AIPreset.custom.rawValue {
                TextField("Instruction", text: $step.text1, prompt: Text("Translate into pirate speak."), axis: .vertical).lineLimit(2...6)
            }
        case .javascript:
            CodeField(text: $step.text1, placeholder: "return text.split('\\n').reverse().join('\\n');")
        case .shell:
            CodeField(text: $step.text1, placeholder: "#!/bin/zsh\ntr '[:lower:]' '[:upper:]'")
        case .appScript:
            let scripts = ApplicationScripts.scripts()
            HStack {
                if scripts.isEmpty {
                    Text("No scripts yet.").foregroundStyle(.secondary)
                } else {
                    Picker("Script", selection: $step.text1) {
                        Text("Choose…").tag("")
                        ForEach(scripts, id: \.self) { Text($0).tag($0) }
                    }
                }
                Button("Open Folder") { ApplicationScripts.reveal() }
            }
        case .plainText, .markdownToHTML, .stripHTML:
            EmptyView()
        }
    }
}

struct CodeField: View {
    @Binding var text: String
    let placeholder: String
    var body: some View {
        TextEditor(text: $text)
            .font(.body.monospaced())
            .frame(minHeight: 90)
            .overlay(alignment: .topLeading) {
                if text.isEmpty { Text(placeholder).font(.body.monospaced()).foregroundStyle(.tertiary).padding(5).allowsHitTesting(false) }
            }
            .border(.separator)
    }
}

/// Shows what a regular expression matches in the sample text, live.
struct RegexTester: View {
    let pattern: String
    let caseSensitive: Bool
    let sample: String

    var body: some View {
        switch TextOps.regexMatches(pattern, in: sample, caseSensitive: caseSensitive) {
        case .failure(let error):
            Label(error.message, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.red)
        case .success(let ranges):
            VStack(alignment: .leading, spacing: 2) {
                Text("\(ranges.count) match\(ranges.count == 1 ? "" : "es") in the sample").font(.caption).foregroundStyle(.secondary)
                if !ranges.isEmpty {
                    Text(highlighted(ranges)).font(.caption.monospaced()).lineLimit(4)
                }
            }
        }
    }

    func highlighted(_ ranges: [Range<String.Index>]) -> AttributedString {
        let shown = String(sample.prefix(600))
        var attributed = AttributedString(shown)
        for range in ranges {
            guard range.upperBound <= shown.endIndex,
                  let lower = AttributedString.Index(range.lowerBound, within: attributed),
                  let upper = AttributedString.Index(range.upperBound, within: attributed) else { continue }
            attributed[lower..<upper].backgroundColor = .yellow.opacity(0.5)
        }
        return attributed
    }
}

enum Languages {
    static let common: [(String, String)] = ["en", "es", "fr", "de", "it", "pt", "nl", "ja", "ko", "zh-Hans", "zh-Hant", "ru", "ar", "hi", "pl", "tr", "uk", "vi", "th", "id"]
        .map { ($0, Locale.current.localizedString(forIdentifier: $0) ?? $0) }
}

// MARK: - Snippets

struct SnippetList: View {
    @Bindable var state: MainState
    @State private var store = ClipStore.shared

    var groups: [(String, [Snippet])] { Self.groups(store.library.snippets, query: state.query) }

    /// The snippets shown for a search, grouped and in list order; the arrow keys walk them too.
    static func groups(_ snippets: [Snippet], query: String) -> [(String, [Snippet])] {
        let filtered = snippets.filter { query.isEmpty || FuzzySearch.score(query, in: "\($0.name) \($0.abbreviation) \($0.template)") != nil }
        return Dictionary(grouping: filtered) { $0.group.isEmpty ? "Snippets" : $0.group }
            .sorted { $0.key < $1.key }.map { ($0.key, $0.value.sorted { $0.name < $1.name }) }
    }

    var body: some View {
        ScrollViewReader { proxy in
            List(selection: $state.selection) {
                ForEach(groups, id: \.0) { group, snippets in
                    Section(group) {
                        ForEach(snippets) { snippet in
                            HStack {
                                Text(snippet.name)
                                Spacer()
                                if !snippet.abbreviation.isEmpty { Text(snippet.abbreviation).font(.caption.monospaced()).foregroundStyle(.secondary) }
                            }
                            .tag(snippet.id)
                            .contextMenu {
                                Button("Copy") { Paster.write(text: SnippetPaster.expand(snippet, inputs: [:])) }
                                Button("Delete", role: .destructive) { store.deleteSnippet(snippet.id) }
                            }
                        }
                    }
                }
            }
            .revealing(state.reveal, with: proxy)
        }
        .searchable(text: $state.query, placement: .toolbar, prompt: "Search Snippets")
        .onDeleteCommand { for id in state.selection { store.deleteSnippet(id) } }
        .toolbar {
            Button {
                let snippet = Snippet(name: "New Snippet", template: "")
                store.upsertSnippet(snippet)
                state.selection = [snippet.id]
            } label: { Label("New Snippet", systemImage: "plus") }
        }
        .navigationTitle("Snippets")
    }
}

struct SnippetEditor: View {
    @State var snippet: Snippet
    @State private var store = ClipStore.shared
    @State private var prefs = Preferences.shared

    var preview: String { Template.expand(snippet.template, clipboard: NSPasteboard.general.string(forType: .string) ?? "").text }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $snippet.name)
                TextField("Group", text: $snippet.group, prompt: Text("Snippets"))
                TextField("Abbreviation", text: $snippet.abbreviation, prompt: Text(";sig"))
                if !snippet.abbreviation.isEmpty && !prefs.expansion {
                    Text("Typing abbreviations is off. Turn it on in Settings › Snippets.").font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Text") {
                CodeField(text: $snippet.template, placeholder: "Hi {input:Name},\n\n{cursor}\n\nSent {date:EEEE}")
                    .frame(minHeight: 160)
            }
            Section {
                Text(preview).font(.body.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            } header: { Text("Preview") } footer: {
                Text("Placeholders: {date}, {date:yyyy-MM-dd}, {date+7}, {time}, {weekday}, {clipboard}, {uuid}, {input:Name}, {input:Name=default}, {cursor}. Write {{ and }} for literal braces.")
                    .font(.caption)
            }
            Section {
                Button("Paste into Front App") { SnippetPaster.paste(snippet, delay: 0.3); NSApp.hide(nil) }
            }
        }
        .formStyle(.grouped)
        .onChange(of: snippet) {
            if store.library.snippets.first(where: { $0.id == snippet.id }) != snippet { store.upsertSnippet(snippet) }
        }
    }
}
