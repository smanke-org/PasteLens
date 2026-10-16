import AppIntents
import AppKit
import PasteLensKit

/// Shortcuts actions.

struct PastebinEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Pastebin"
    static let defaultQuery = PastebinQuery()
    var id: String
    var name: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

struct PastebinQuery: EntityQuery {
    @MainActor func all() -> [PastebinEntity] {
        let lib = ClipStore.shared.library
        return [PastebinEntity(id: "history", name: "History"), PastebinEntity(id: "pinned", name: "Pinned")]
            + lib.pastebins.map { PastebinEntity(id: $0.id.uuidString, name: $0.name) }
            + lib.smartPastebins.map { PastebinEntity(id: $0.id.uuidString, name: $0.name) }
    }
    func entities(for identifiers: [String]) async throws -> [PastebinEntity] {
        await all().filter { identifiers.contains($0.id) }
    }
    func suggestedEntities() async throws -> [PastebinEntity] { await all() }
}

struct FilterEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Filter"
    static let defaultQuery = FilterQuery()
    var id: UUID
    var name: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

struct FilterQuery: EntityStringQuery {
    @MainActor func all() -> [FilterEntity] {
        ClipStore.shared.library.filters.sorted { $0.name < $1.name }.map { FilterEntity(id: $0.id, name: $0.name) }
    }
    func entities(for identifiers: [UUID]) async throws -> [FilterEntity] { await all().filter { identifiers.contains($0.id) } }
    func entities(matching string: String) async throws -> [FilterEntity] {
        await all().filter { $0.name.localizedCaseInsensitiveContains(string) }
    }
    func suggestedEntities() async throws -> [FilterEntity] { await all() }
}

struct ClippingEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Clipping"
    static let defaultQuery = ClippingQuery()
    var id: UUID
    @Property(title: "Text") var text: String
    @Property(title: "Kind") var kind: String
    @Property(title: "Copied") var copiedAt: Date
    @Property(title: "Source App") var sourceApp: String

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(String(text.prefix(80)))", subtitle: "\(kind)") }

    @MainActor init(_ clip: Clipping) {
        id = clip.id
        text = clip.sensitive ? "(hidden)" : (ClipStore.shared.text(of: clip.id) ?? clip.ocrText ?? clip.previewText)
        kind = clip.kind.label
        copiedAt = clip.copiedAt
        sourceApp = clip.sourceName ?? ""
    }
}

struct ClippingQuery: EntityStringQuery {
    func entities(for identifiers: [UUID]) async throws -> [ClippingEntity] {
        await MainActor.run { identifiers.compactMap { ClipStore.shared.clip($0) }.map(ClippingEntity.init) }
    }
    func entities(matching string: String) async throws -> [ClippingEntity] {
        await MainActor.run { ClipStore.shared.clippings(in: .history, query: string).prefix(30).map(ClippingEntity.init) }
    }
    func suggestedEntities() async throws -> [ClippingEntity] {
        await MainActor.run { ClipStore.shared.recent(20).map(ClippingEntity.init) }
    }
}

struct GetClippingsIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Clippings"
    static let description = IntentDescription("Gets recent clippings from a pastebin, optionally matching a search.")
    @Parameter(title: "Pastebin") var pastebin: PastebinEntity?
    @Parameter(title: "Search") var query: String?
    @Parameter(title: "Limit", default: 10, inclusiveRange: (1, 500)) var limit: Int

    static var parameterSummary: some ParameterSummary { Summary("Get \(\.$limit) clippings from \(\.$pastebin)") { \.$query } }

    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<[ClippingEntity]> {
        let scope = ClipStore.Scope(id: pastebin?.id) ?? .history
        return .result(value: ClipStore.shared.clippings(in: scope, query: query ?? "", limit: limit).map(ClippingEntity.init))
    }
}

struct GetClippingByIndexIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Clipping by Position"
    static let description = IntentDescription("Gets one clipping by its position in a pastebin; 1 is the most recent.")
    @Parameter(title: "Position", default: 1, inclusiveRange: (1, 10_000)) var position: Int
    @Parameter(title: "Pastebin") var pastebin: PastebinEntity?

    static var parameterSummary: some ParameterSummary { Summary("Get clipping \(\.$position) from \(\.$pastebin)") }

    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<ClippingEntity> {
        let items = ClipStore.shared.clippings(in: ClipStore.Scope(id: pastebin?.id) ?? .history, limit: position)
        guard items.indices.contains(position - 1) else { throw Bridge.Failure("There's no clipping at position \(position).") }
        return .result(value: ClippingEntity(items[position - 1]))
    }
}

struct CopyClippingIntent: AppIntent {
    static let title: LocalizedStringResource = "Copy Clipping"
    static let description = IntentDescription("Puts a clipping on the clipboard.")
    @Parameter(title: "Clipping") var clipping: ClippingEntity

    @MainActor func perform() async throws -> some IntentResult {
        guard let clip = ClipStore.shared.clip(clipping.id), Paster.copy(clip) else { throw Bridge.Failure("Clipping not found.") }
        return .result()
    }
}

struct PasteClippingIntent: AppIntent {
    static let title: LocalizedStringResource = "Paste Clipping"
    static let description = IntentDescription("Pastes a clipping into the frontmost app. Needs Accessibility permission.")
    @Parameter(title: "Clipping") var clipping: ClippingEntity

    @MainActor func perform() async throws -> some IntentResult {
        guard let clip = ClipStore.shared.clip(clipping.id) else { throw Bridge.Failure("Clipping not found.") }
        Paster.paste(clip)
        return .result()
    }
}

struct ApplyFilterIntent: AppIntent {
    static let title: LocalizedStringResource = "Apply Filter"
    static let description = IntentDescription("Runs a PasteLens filter on text and returns the result.")
    @Parameter(title: "Filter") var filter: FilterEntity
    @Parameter(title: "Text") var text: String

    static var parameterSummary: some ParameterSummary { Summary("Apply \(\.$filter) to \(\.$text)") }

    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<String> {
        guard let f = ClipStore.shared.library.filters.first(where: { $0.id == filter.id }) else { throw Bridge.Failure("Filter not found.") }
        return .result(value: try await FilterRunner.run(f, on: text, services: AppFilterServices()))
    }
}

struct AddClippingIntent: AppIntent {
    static let title: LocalizedStringResource = "Add Clipping"
    static let description = IntentDescription("Saves text as a new clipping, optionally into a pastebin.")
    @Parameter(title: "Text") var text: String
    @Parameter(title: "Pastebin") var pastebin: PastebinEntity?

    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<ClippingEntity> {
        var bins: [UUID] = []
        if let id = pastebin.flatMap({ UUID(uuidString: $0.id) }), ClipStore.shared.library.pastebins.contains(where: { $0.id == id }) { bins = [id] }
        return .result(value: ClippingEntity(ClipStore.shared.add(.text(text), source: (nil, "Shortcuts"), inHistory: bins.isEmpty, pastebins: bins)))
    }
}

struct ClearHistoryIntent: AppIntent {
    static let title: LocalizedStringResource = "Clear History"
    static let description = IntentDescription("Deletes everything in History except pinned and saved clippings.")

    @MainActor func perform() async throws -> some IntentResult {
        try await requestConfirmation(actionName: .go, dialog: "Delete every clipping in History?")
        ClipStore.shared.clearHistory()
        return .result()
    }
}

struct OpenQuickPasteIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Quick Paste"
    static let openAppWhenRun = false

    @MainActor func perform() async throws -> some IntentResult {
        QuickPastePanel.shared.show()
        return .result()
    }
}

struct PasteLensShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: GetClippingsIntent(), phrases: ["Get clippings from \(.applicationName)"], shortTitle: "Get Clippings", systemImageName: "doc.on.clipboard")
        AppShortcut(intent: ApplyFilterIntent(), phrases: ["Apply a \(.applicationName) filter"], shortTitle: "Apply Filter", systemImageName: "camera.filters")
        AppShortcut(intent: OpenQuickPasteIntent(), phrases: ["Open \(.applicationName) Quick Paste"], shortTitle: "Quick Paste", systemImageName: "magnifyingglass")
    }
}
