import AppKit
import FoundationModels
import NaturalLanguage
import Observation
import PasteLensKit
import Translation

/// What filters get from the app: translation, Apple Intelligence, user scripts, the clipboard.
struct AppFilterServices: FilterServices {
    func translate(_ text: String, to language: String) async throws -> String {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let detected = recognizer.dominantLanguage?.rawValue else { throw FilterError("Couldn't tell what language the text is in.") }
        let source = Locale.Language(identifier: detected)
        let target = Locale.Language(identifier: language)
        if source.minimalIdentifier == target.minimalIdentifier { return text }
        let status = await LanguageAvailability().status(from: source, to: target)
        switch status {
        case .installed: break
        case .supported:
            let names = [source, target].map { Locale.current.localizedString(forIdentifier: $0.minimalIdentifier) ?? $0.minimalIdentifier }
            throw FilterError("Download \(names[0]) and \(names[1]) in System Settings › General › Language & Region › Translation Languages, then try again.")
        default:
            throw FilterError("Translation from \(detected) to \(language) isn't available.")
        }
        let session = TranslationSession(installedSource: source, target: target)
        return try await session.translate(text).targetText
    }

    func generate(_ text: String, instruction: String) async throws -> String {
        let model = SystemLanguageModel.default
        switch model.availability {
        case .available: break
        case .unavailable(.appleIntelligenceNotEnabled): throw FilterError("Turn on Apple Intelligence in System Settings to use this filter.")
        case .unavailable(.modelNotReady): throw FilterError("Apple Intelligence is still downloading its model. Try again later.")
        case .unavailable(.deviceNotEligible): throw FilterError("This Mac doesn't support Apple Intelligence.")
        default: throw FilterError("Apple Intelligence isn't available right now.")
        }
        let session = LanguageModelSession(instructions: """
            You transform text the user copied. Follow the instruction exactly and reply with only the transformed text: \
            no preamble, no quotes around it, no explanation.
            """)
        do {
            let response = try await session.respond(to: "Instruction: \(instruction)\n\nText:\n\(text)")
            return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch let error as LanguageModelSession.GenerationError {
            switch error {
            case .exceededContextWindowSize: throw FilterError("The text is too long for the on-device model.")
            case .guardrailViolation: throw FilterError("The on-device model declined to process this text.")
            default: throw FilterError(error.localizedDescription)
            }
        }
    }

    func runApplicationScript(named name: String, input: String) async throws -> String {
        let folder = ApplicationScripts.folder
        let url = folder.appendingPathComponent(name)
        guard !name.isEmpty, FileManager.default.fileExists(atPath: url.path) else {
            throw FilterError("No script named “\(name)” in \(folder.path).")
        }
        #if APPSTORE
        // Scripts there run outside the sandbox, through NSUserUnixTask.
        let task = try NSUserUnixTask(url: url)
        let stdin = Pipe(), stdout = Pipe()
        task.standardInput = stdin.fileHandleForReading
        task.standardOutput = stdout.fileHandleForWriting
        stdin.fileHandleForWriting.write(Data(input.utf8))
        try stdin.fileHandleForWriting.close()
        try await task.execute(withArguments: [])
        try stdout.fileHandleForWriting.close()
        return String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #else
        return try await ScriptRunner.run(executable: url, arguments: [], input: input)
        #endif
    }

    func clipboardText() async -> String {
        await MainActor.run { NSPasteboard.general.string(forType: .string) ?? "" }
    }
}

enum ApplicationScripts {
    /// ~/Library/Application Scripts/com.smanke.PasteLens
    static var folder: URL {
        if let url = try? FileManager.default.url(for: .applicationScriptsDirectory, in: .userDomainMask, appropriateFor: nil, create: true) {
            return url
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Scripts/com.smanke.PasteLens")
    }

    static func scripts() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
    }

    static func reveal() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }
}

enum FilterApplier {
    /// The text a filter starts from: the clipping's text, its recognized text for images, or file paths.
    @MainActor static func sourceText(for clip: Clipping) -> String? {
        if let text = ClipStore.shared.text(of: clip.id) { return text }
        if let ocr = clip.ocrText, !ocr.isEmpty { return ocr }
        return clip.previewText.isEmpty ? nil : clip.previewText
    }

    @MainActor static func run(_ filter: Filter, on clip: Clipping) async throws -> String {
        guard let text = sourceText(for: clip) else { throw FilterError("This clipping has no text to filter.") }
        return try await FilterRunner.run(filter, on: text, services: AppFilterServices())
    }
}

/// When PasteLens was last used and whether it's in the middle of something, so an
/// automatic update never restarts it at a bad moment.
@MainActor
final class Activity {
    static let shared = Activity()
    var lastActive = Date.distantPast

    func touch() { lastActive = Date() }

    var busyReason: String? {
        if QuickPastePanel.shared.isVisible { return "Quick Paste is open" }
        if !StackController.shared.items.isEmpty { return "the stack has items waiting" }
        if case .syncing = SyncEngine.shared.status { return "syncing" }
        if SyncEngine.shared.pendingContent > 0 { return "clippings are still syncing" }
        return nil
    }
}
