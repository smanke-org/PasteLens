#if DEBUG
import AppKit
import Carbon.HIToolbox
import PasteLensKit
import SwiftUI

/// The narrated demo video (PASTELENS_DEBUG_DEMO=<trace file>), recorded by Tools/demo/record_demo.sh.
///
/// A copy of the Debug build with its own clippings and settings plays fourteen scenes on the
/// built-in display, in step with the voiceover lines in PASTELENS_DEBUG_DEMO_VO (NN.json word
/// timings from ElevenLabs). The real PasteLens windows paste for real into a blank Microsoft Word
/// document and a local sample page in Safari. Overlay panels draw the wallpaper, the keys being
/// pressed, subtitles, title cards and the two staged scenes (sync between Macs, the command line).
///
/// The trace gets `scene <n> <host seconds> <length>` for each line, which mix.py uses to place
/// the audio, and `<trace>.crop` holds the recorded area in the display's top-left coordinates.
@MainActor
enum DemoStage {
    static let state = DemoState()
    private static var screen: NSScreen!
    private(set) static var crop = CGRect.zero
    private static var windows: [NSWindow] = []
    private static var tracePath = "/dev/null"
    private static var traceLines: [String] = []
    private static let lead = 0.45
    private static var stageFolder = ""

    // MARK: Voiceover

    struct Word { var text: String; var start: Double; var end: Double }
    struct Line {
        var text: String
        var starts: [Double]
        var words: [Word]
        var duration: Double { words.last?.end ?? 0 }
    }
    private static var lines: [Int: Line] = [:]
    private static var line: Line?
    private static var sceneStart = 0.0
    private static var subtitles: [(start: Double, end: Double, text: String)] = []

    private static func loadVoiceover(_ folder: String) {
        for n in 1...30 {
            let url = URL(fileURLWithPath: folder).appending(path: String(format: "%02d.json", n))
            guard let data = try? Data(contentsOf: url),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let chars = json["characters"] as? [String],
                  let starts = json["character_start_times_seconds"] as? [Double],
                  let ends = json["character_end_times_seconds"] as? [Double] else { continue }
            var words: [Word] = []
            var current = "", start = 0.0, end = 0.0
            for (i, c) in chars.enumerated() {
                if c == " " || c == "\n" {
                    if !current.isEmpty { words.append(Word(text: current, start: start, end: end)) }
                    current = ""
                } else {
                    if current.isEmpty { start = starts[i] }
                    current += c
                    end = ends[i]
                }
            }
            if !current.isEmpty { words.append(Word(text: current, start: start, end: end)) }
            lines[n] = Line(text: chars.joined(), starts: starts, words: words)
        }
        trace("voiceover lines \(lines.keys.sorted())")
    }

    /// The line cut into subtitle-sized pieces (the same rule as mix.py).
    private static func chunks(_ line: Line) -> [(start: Double, end: Double, text: String)] {
        var out: [(Double, Double, String)] = []
        var words: [Word] = []
        func flush() {
            guard let first = words.first, let last = words.last else { return }
            out.append((first.start, last.end, words.map(\.text).joined(separator: " ")))
            words = []
        }
        for word in line.words {
            words.append(word)
            let length = words.map(\.text.count).reduce(0, +) + words.count
            let ends = word.text.last.map { ".?!…:".contains($0) } ?? false
            let pause = word.text.last.map { ",;".contains($0) } ?? false
            if ends && length > 14 || pause && length > 34 || length > 52 { flush() }
        }
        flush()
        return out.enumerated().map { i, piece in
            (piece.0, i + 1 < out.count ? out[i + 1].0 : piece.1 + 0.5, piece.2)
        }
    }

    // MARK: Running

    static func run(trace path: String) {
        tracePath = path
        let env = ProcessInfo.processInfo.environment
        guard env["PASTELENS_DEFAULTS_SUITE"] != nil, env["PASTELENS_DATA_FOLDER"] != nil,
              let folder = env["PASTELENS_DEBUG_DEMO_STAGE"] else { trace("missing suite, data folder or stage"); exit(2) }
        stageFolder = folder
        guard let built = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID).map { CGDisplayIsBuiltin($0) != 0 } ?? false
        }) else { trace("no built-in display"); exit(3) }
        screen = built
        if let vo = env["PASTELENS_DEBUG_DEMO_VO"] { loadVoiceover(vo) }
        let frame = built.frame, visible = built.visibleFrame
        // Narrower than the screen, so the windows come out larger in the 1920-wide film.
        // Word won't go narrower than about 1,170 points.
        let width: CGFloat = 1360, height = (width * 9 / 16).rounded()
        let bottom = max(visible.minY, frame.minY) + 40
        crop = CGRect(x: (frame.midX - width / 2).rounded(), y: bottom, width: width, height: height)
        trace("crop \(crop) screen \(frame) visible \(visible)")
        let topLeft = CGRect(x: crop.minX - frame.minX, y: frame.maxY - crop.maxY, width: crop.width, height: crop.height)
        try? "\(Int(topLeft.minX)) \(Int(topLeft.minY)) \(Int(topLeft.width)) \(Int(topLeft.height))"
            .write(toFile: path + ".crop", atomically: true, encoding: .utf8)

        NSApp.setActivationPolicy(.accessory)
        AppDefaults.store.set(true, forKey: "welcomed")
        Preferences.shared.quickPasteAtMouse = false
        Preferences.shared.expansion = false
        _ = ClipStore.shared
        DemoLibrary.fill()
        ClipboardMonitor.shared.start()

        Task {
            // Text in the receipt picture, for searching.
            for _ in 0..<60 where (ClipStore.shared.clip(DemoLibrary.receipt)?.ocrText ?? "").isEmpty {
                try? await Task.sleep(for: .milliseconds(250))
            }
            trace("receipt text: \(ClipStore.shared.clip(DemoLibrary.receipt)?.ocrText?.prefix(60) ?? "none")")
            DemoApps.setUp(stage: folder, frame: appFrameCG)
            makeWindows()
            try? await Task.sleep(for: .seconds(1.5))
            Timer.scheduledTimer(withTimeInterval: 0.05, repeats: false) { _ in
                MainActor.assumeIsolated {
                    trace("stage ready")
                    pump(Double(env["PASTELENS_DEBUG_DEMO_LEAD"] ?? "") ?? 3)
                    trace("action \(CACurrentMediaTime())")
                    play()
                    trace("cut \(CACurrentMediaTime())")
                    pump(0.6)
                    DemoApps.tearDown()
                    exit(0)
                }
            }
        }
    }

    static func trace(_ line: String) {
        traceLines.append(line)
        try? traceLines.joined(separator: "\n").appending("\n").write(toFile: tracePath, atomically: true, encoding: .utf8)
    }

    // MARK: Windows

    @discardableResult
    private static func panel(level: NSWindow.Level, view: some View) -> NSWindow {
        let window = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = level
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.animationBehavior = .none
        let hosting = NSHostingView(rootView: view)
        hosting.sizingOptions = []
        window.contentView = hosting
        window.setFrame(screen.frame, display: true)
        window.orderFrontRegardless()
        windows.append(window)
        return window
    }

    private static func makeWindows() {
        let cropInView = CGRect(x: crop.minX - screen.frame.minX, y: screen.frame.maxY - crop.maxY, width: crop.width, height: crop.height)
        panel(level: NSWindow.Level(Int(CGWindowLevelForKey(.desktopWindow)) + 1), view: DemoDesk(crop: cropInView))
        panel(level: NSWindow.Level(NSWindow.Level.popUpMenu.rawValue + 2), view: DemoOverlay(state: state, crop: cropInView, cover: safariCoverInView))
    }

    /// Where Word and Safari sit, in the global top-left (Core Graphics) coordinates System Events uses.
    private static var appFrameCG: CGRect {
        let mainHeight = NSScreen.screens[0].frame.maxY
        return CGRect(x: crop.minX + 90, y: mainHeight - crop.maxY + 28, width: 1180, height: crop.height - 28 - 22)
    }

    /// Safari's toolbar and favorites bar, covered by a plain address strip (they show the user's bookmarks).
    private static var safariCoverInView: CGRect {
        let mainHeight = NSScreen.screens[0].frame.maxY
        let f = appFrameCG
        let topInView = f.minY - (mainHeight - screen.frame.maxY)
        return CGRect(x: f.minX - screen.frame.minX, y: topInView, width: f.width, height: DemoApps.safariChrome)
    }

    /// A frame inside the recorded area: x and y from its top-left corner.
    private static func filmFrame(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect {
        NSRect(x: crop.minX + x, y: crop.maxY - y - h, width: w, height: h)
    }

    private static func placeQuickPaste(_ x: CGFloat = 400, _ y: CGFloat = 150) {
        pump(0.05)
        NSApp.windows.first { $0.isVisible && String(describing: Swift.type(of: $0)).contains("KeyPanel") }?
            .setFrame(filmFrame(x, y, 900, 500), display: true)
    }

    private static var mainWindow: NSWindow? { MainWindow.shared.debugWindow }

    private static func showMain(_ section: MainState.Section, query: String = "", select: [UUID] = []) {
        MainWindow.shared.state.section = section
        MainWindow.shared.state.query = query
        MainWindow.shared.show()
        mainWindow?.setFrame(filmFrame(100, 45, 1160, 670), display: true)
        MainWindow.shared.state.selection = Set(select)
    }

    private static func hideAll() {
        StackWindow.shared.debugPanel?.orderOut(nil)
        QuickPastePanel.shared.close()
        mainWindow?.orderOut(nil)
        SettingsWindow.shared.debugWindow?.orderOut(nil)
        StackWindow.shared.debugPanel?.orderOut(nil)
    }

    // MARK: Time

    static func pump(_ seconds: Double) {
        let end = CACurrentMediaTime() + seconds
        while CACurrentMediaTime() < end {
            RunLoop.main.run(until: Date().addingTimeInterval(1.0 / 120))
            tickSubtitles()
        }
    }

    private static func pump(until time: Double) { pump(max(0, time - CACurrentMediaTime())) }

    private static var now: Double { CACurrentMediaTime() - sceneStart - lead }

    private static func tickSubtitles() {
        guard line != nil else { return }
        let t = now
        let text = subtitles.first { t >= $0.start && t < $0.end }?.text
        if state.subtitle != text { state.subtitle = text }
    }

    /// Waits until `phrase` is spoken in this scene's line (plus `offset` seconds).
    private static func at(_ phrase: String, _ offset: Double = 0) {
        guard let line else { return }
        let lower = line.text.lowercased()
        guard let range = lower.range(of: phrase.lowercased()) else { trace("phrase not found: \(phrase)"); return }
        let index = lower.distance(from: lower.startIndex, to: range.lowerBound)
        guard index < line.starts.count else { return }
        pump(until: sceneStart + lead + line.starts[index] + offset)
    }

    private static func scene(_ n: Int, tail: Double = 0.8, _ body: () -> Void) {
        sceneStart = CACurrentMediaTime()
        line = lines[n]
        subtitles = line.map(chunks) ?? []
        trace("scene \(n) \(sceneStart + lead) \(line?.duration ?? 0)")
        body()
        pump(until: sceneStart + lead + (line?.duration ?? 0) + tail)
        state.subtitle = nil
        line = nil
    }

    // MARK: Keys

    /// Shows the keys as a pill for `hold` seconds.
    private static func keys(_ k: String, hold: Double = 1.0) {
        withAnimation(.easeOut(duration: 0.15)) { state.keys = k }
        pump(hold)
        withAnimation(.easeIn(duration: 0.2)) { state.keys = nil }
    }

    private static func post(_ code: Int, _ flags: CGEventFlags = []) {
        Paster.postKey(CGKeyCode(code), flags: flags)
        pump(0.05)
    }

    /// Types into the front app one character at a time.
    private static func type(_ text: String, every: Double = 0.07) {
        for ch in text {
            let utf16 = Array(String(ch).utf16)
            for down in [true, false] {
                let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down)
                event?.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
                event?.post(tap: .cghidEventTap)
            }
            pump(every)
        }
    }

    /// Types into Quick Paste's search field, as the person would.
    private static func search(_ text: String) {
        var typed = ""
        for ch in text {
            typed.append(ch)
            QuickPastePanel.shared.model.query = typed
            pump(0.11)
        }
    }

    // MARK: - The scenes

    private static func play() {
        let qp = QuickPastePanel.shared.model
        let ids = DemoLibrary.self

        // 1. Copying three things in Word; each one replaces the last.
        scene(1) {
            DemoApps.front(.word)
            pump(0.6)
            for (i, paragraph) in [2, 3, 4].enumerated() {
                DemoApps.selectWordParagraph(paragraph)
                pump(0.35)
                keys("⌘C", hold: 0.5)
                post(kVK_ANSI_C, .maskCommand)
                pump(0.3)
                withAnimation(.spring(duration: 0.4)) { state.clipboard = DemoApps.wordParagraphs[paragraph - 1] }
                if i == 0 { at("Then something else") } else if i == 1 { pump(0.5) }
            }
            at("And the first thing")
            withAnimation(.easeOut(duration: 0.3)) { state.clipboardLost = true }
            at("Meet PasteLens", -0.2)
            withAnimation(.easeInOut(duration: 0.5)) { state.clipboard = nil; state.clipboardLost = false; state.card = .intro }
        }
        withAnimation(.easeInOut(duration: 0.5)) { state.card = nil }

        // 2. History.
        scene(2) {
            DemoApps.selectWordEnd()
            showMain(.clips(.history), select: [ids.rich])
            at("rich text"); MainWindow.shared.state.selection = [ids.rich]
            at("links"); MainWindow.shared.state.selection = [ids.link]
            at("colors"); MainWindow.shared.state.selection = [ids.color]
            at("images"); MainWindow.shared.state.selection = [ids.receipt]
            at("files"); MainWindow.shared.state.selection = [ids.file]
            at("with a preview"); MainWindow.shared.state.selection = [ids.invoice]
        }

        // 3. Quick Paste into Word.
        scene(3) {
            hideAll()
            DemoApps.front(.word)
            DemoApps.selectWordEnd()
            pump(0.4)
            at("Press Control", 0.3)
            keys("⌃ `", hold: 0.6)
            QuickPastePanel.shared.show()
            placeQuickPaste()
            at("Start typing", 0.4)
            search("invce")
            at("Press Return", 0.2)
            keys("↩", hold: 0.4)
            qp.activate(.paste)
            pump(0.6)
            post(kVK_Return)
            at("Or press Command", 0.2)
            QuickPastePanel.shared.show()
            placeQuickPaste()
            pump(0.6)
            keys("⌘3", hold: 0.4)
            qp.selection = 2
            pump(0.25)
            qp.activate(.paste)
        }

        // 4. Text in pictures.
        scene(4) {
            DemoApps.selectWordEnd()
            showMain(.clips(.history))
            pump(0.5)
            at("search for words", -0.6)
            for (i, _) in "Total".enumerated() {
                MainWindow.shared.state.query = String("Total".prefix(i + 1))
                pump(0.12)
            }
            pump(0.3)
            MainWindow.shared.state.selection = [ids.receipt]
        }

        // 5. Pastebins.
        scene(5) {
            hideAll()
            DemoApps.front(.word)
            QuickPastePanel.shared.show()
            placeQuickPaste()
            at("Tab steps", -0.2)
            keys("⇥", hold: 0.5); qp.source = .pastebin(ids.work)
            pump(0.5)
            keys("⇥", hold: 0.5); qp.source = .pastebin(ids.personal)
            pump(0.4)
            keys("⇧⇥", hold: 0.5); qp.source = .history
            at("moves a clipping", -0.4)
            qp.selection = 1
            pump(0.3)
            keys("⌃1", hold: 0.6)
            ClipStore.shared.move([ids.agenda], to: ids.work)
            qp.notice = "Moved to Work"
            pump(0.4)
            qp.source = .pastebin(ids.work)
            at("Smart pastebins", 0.2)
            keys("⌥⇥", hold: 0.6)
            qp.source = .smart(ids.safariLinks)
            at("everything from this week", 0.3)
            qp.source = .smart(ids.images)
        }

        // 6. Plain text and typing out, in Safari.
        scene(6) {
            QuickPastePanel.shared.close()
            state.safariCover = true
            DemoApps.front(.safari)
            DemoApps.focusSafariField("Full name")
            pump(0.5)
            QuickPastePanel.shared.show()
            placeQuickPaste(380, 250)
            search("jordan")
            at("Shift", -0.1)
            keys("⇧↩", hold: 0.4)
            qp.activate(.pastePlain)
            pump(0.5)
            DemoApps.focusSafariField("Email")
            pump(0.2)
            QuickPastePanel.shared.show()
            placeQuickPaste(380, 250)
            search("jordan@")
            keys("↩", hold: 0.3)
            qp.activate(.paste)
            pump(0.4)
            at("refuse", -0.3)
            DemoApps.focusSafariField("Confirm email")
            pump(0.2)
            keys("⌘V", hold: 0.4)
            post(kVK_ANSI_V, .maskCommand)
            at("Option", -0.2)
            QuickPastePanel.shared.show()
            placeQuickPaste(380, 250)
            search("jordan@")
            keys("⌥↩", hold: 0.4)
            qp.activate(.typeOut)
        }

        // 7. Filters, into Word.
        scene(7) {
            DemoApps.front(.word)
            state.safariCover = false
            DemoApps.selectWordEnd()
            post(kVK_Return)
            QuickPastePanel.shared.show()
            placeQuickPaste()
            search("launch")
            pump(0.3)
            keys("⌘↩", hold: 0.5)
            if let clip = ClipStore.shared.clip(ids.sloppy) { qp.filterMode = clip }
            pump(0.3)
            @MainActor func pick(_ name: String) {
                if let i = qp.filters.firstIndex(where: { $0.name == name }) { qp.selection = i }
            }
            at("Fix the case"); pick("Title Case")
            at("tidy up JSON"); pick("Format JSON")
            at("find and replace"); pick("Sentence case")
            at("translate"); pick("Translate to English")
            at("Apple Intelligence", -0.3); pick("Fix Spelling and Grammar")
            // The on-device model needs a moment for its preview.
            for _ in 0..<40 where qp.filterPreview == nil { pump(0.1) }
            at("Build your own", -0.5)
            keys("↩", hold: 0.4)
            qp.activate(.paste)
        }

        // 8. The stack: collect three, paste them into Safari's shipping fields.
        scene(8) {
            QuickPastePanel.shared.close()
            DemoApps.front(.word)
            StackController.shared.clear()
            StackController.shared.collecting = true
            StackWindow.shared.show()
            StackWindow.shared.debugPanel?.setFrame(filmFrame(990, 80, 340, 420), display: true)
            at("copy them", -0.3)
            for paragraph in [2, 3, 4] {
                DemoApps.selectWordParagraph(paragraph)
                pump(0.2)
                keys("⌘C", hold: 0.3)
                post(kVK_ANSI_C, .maskCommand)
                pump(0.35)
            }
            at("then paste them", -0.4)
            state.safariCover = true
            DemoApps.front(.safari)
            for (i, field) in ["Order number", "Tracking number", "Address"].enumerated() {
                DemoApps.focusSafariField(field)
                pump(0.15)
                keys("⌃⇧⌘V", hold: 0.35)
                StackController.shared.pasteNext()
                pump(i == 2 ? 0.3 : 0.45)
            }
        }

        // 9. Snippets.
        scene(9) {
            StackWindow.shared.debugPanel?.orderOut(nil)
            DemoApps.front(.word)
            state.safariCover = false
            showMain(.snippets, select: [ids.signature])
            at("Type a short", -0.3)
            mainWindow?.orderOut(nil)
            DemoApps.front(.word)
            DemoApps.selectWordEnd()
            post(kVK_Return)
            post(kVK_Return)
            type(";sig", every: 0.12)
            pump(0.15)
            for _ in 0..<4 { post(kVK_Delete) }
            if let snippet = ClipStore.shared.library.snippets.first(where: { $0.id == ids.signature }) {
                SnippetPaster.paste(snippet, delay: 0.05)
            }
            pump(1.2)
        }

        // 10. Secrets.
        StackController.shared.collecting = false
        StackController.shared.clear()
        scene(10) {
            DemoApps.selectWordParagraph(5, wholeLineAfterColon: true)
            pump(0.3)
            keys("⌘C", hold: 0.4)
            post(kVK_ANSI_C, .maskCommand)
            pump(0.4)
            at("hidden", -0.4)
            showMain(.clips(.history))
            if let secret = ClipStore.shared.recent(1).first { MainWindow.shared.state.selection = [secret.id] }
            at("Copies from your password", -0.3)
            mainWindow?.orderOut(nil)
            SettingsWindow.shared.show(tab: "Privacy")
            SettingsWindow.shared.debugWindow?.setFrame(filmFrame(230, 30, 900, 700), display: true)
        }

        // 11. Sync (staged).
        scene(11) {
            StackWindow.shared.debugPanel?.orderOut(nil)
            SettingsWindow.shared.debugWindow?.orderOut(nil)
            withAnimation(.easeInOut(duration: 0.4)) { state.sync = 0 }
            at("through iCloud", -0.2); withAnimation(.spring(duration: 0.5)) { state.sync = 1 }
            at("every record", -0.1); withAnimation(.spring(duration: 0.5)) { state.sync = 2 }
            at("under a passphrase", 0); withAnimation(.spring(duration: 0.5)) { state.sync = 3 }
        }
        withAnimation(.easeInOut(duration: 0.4)) { state.sync = nil }

        // 12. Activity.
        scene(12) {
            StackWindow.shared.debugPanel?.orderOut(nil)
            showMain(.activity)
        }

        // 13. The command line (staged terminal) with History updating.
        scene(13) {
            StackWindow.shared.debugPanel?.orderOut(nil)
            showMain(.clips(.history))
            mainWindow?.setFrame(filmFrame(560, 45, 760, 670), display: true)
            withAnimation(.easeOut(duration: 0.3)) { state.terminal = [] }
            pump(0.3)
            at("a command-line tool", -0.3)
            typeTerminal("pastelens clips list --search invoice")
            state.terminal?.append(contentsOf: ["3f2a9c1e  Invoice INV-2291 from Northwind — $1,284.00", "8b71d04a  Receipt (picture) · Total $86.40"])
            pump(0.6)
            at("save new ones", -1.4)
            typeTerminal("pastelens clips add --text \"Launch checklist\"")
            let added = ClipStore.shared.add(.text("Launch checklist: QA sign-off, release notes, site update"), source: (nil, "pastelens"))
            state.terminal?.append("Saved 5c09e7b2  Launch checklist")
            MainWindow.shared.state.selection = [added.id]
        }
        withAnimation(.easeOut(duration: 0.3)) { state.terminal = nil }

        // 14. Title card.
        scene(14, tail: 2.6) {
            hideAll()
            withAnimation(.easeInOut(duration: 0.6)) { state.card = .outro }
        }
    }

    private static func typeTerminal(_ command: String) {
        state.terminal?.append("$ ")
        for ch in command {
            if var t = state.terminal, !t.isEmpty { t[t.count - 1].append(ch); state.terminal = t }
            pump(0.035)
        }
        pump(0.25)
    }
}

// MARK: - Word and Safari

@MainActor
enum DemoApps {
    enum App { case word, safari }
    /// Height of Safari's toolbar and favorites bar, which the overlay covers.
    static let safariChrome: CGFloat = 86

    static let wordParagraphs = [
        "Launch notes",
        "Order number: NW-48213",
        "Tracking: 1Z 999 AA1 01 2345 6784",
        "Ship to: 220 Harbor Lane, Portland, OR 97209",
        "Build server key: AKIAQ4DEMOEXAMPLE7Z2",
        "",
    ]

    @discardableResult
    static func script(_ source: String) -> String? {
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error { DemoStage.trace("applescript error \(error)") }
        return result?.stringValue
    }

    static func setUp(stage: String, frame: CGRect) {
        let page = URL(fileURLWithPath: stage).appending(path: "demo.html").absoluteString
        script("""
        tell application "Safari"
            make new document with properties {URL:"\(page)"}
        end tell
        """)
        DemoStage.pump(2)
        place("Safari", frame)
        let text = wordParagraphs.joined(separator: "\\r")
        script("""
        tell application "Microsoft Word"
            activate
            set d to make new document
            set content of text object of d to "\(text)"
            set bold of font object of text object of paragraph 1 of d to true
            set font size of font object of text object of paragraph 1 of d to 22
        end tell
        """)
        DemoStage.pump(1.5)
        script("""
        tell application "Microsoft Word"
            try
                set percentage of zoom of view of active window to 150
            end try
        end tell
        """)
        place("Microsoft Word", frame)
        safariMinimized(true)
        DemoStage.pump(0.8)
    }

    static func tearDown() {
        script("tell application \"Safari\" to close (every window whose name contains \"Northwind Checkout\")")
        script("tell application \"Microsoft Word\" to close active document saving no")
    }

    static func place(_ process: String, _ frame: CGRect) {
        // Moved onto the screen first: a move straight from another display gets clamped.
        script("""
        tell application "System Events" to tell process "\(process)"
            set position of front window to {\(Int(frame.minX) + 40), \(Int(frame.minY) + 300)}
            delay 0.3
            set position of front window to {\(Int(frame.minX)), \(Int(frame.minY))}
            set size of front window to {\(Int(frame.width)), \(Int(frame.height))}
        end tell
        """)
    }

    /// Brings Word or Safari to the front. The demo's Safari window is minimized while Word is in
    /// front, so the user's bookmarks in its toolbar never show behind Word.
    static func front(_ app: App) {
        if app == .word {
            safariMinimized(true)
            script("tell application \"Microsoft Word\" to activate")
        } else {
            safariMinimized(false)
            script("tell application \"Safari\" to activate")
            DemoStage.pump(0.3)
            script("tell application \"Safari\" to set index of (first window whose name contains \"Northwind Checkout\") to 1")
        }
        DemoStage.pump(0.35)
    }

    static func safariMinimized(_ minimized: Bool) {
        script("""
        tell application "Safari"
            set w to (first window whose name contains "Northwind Checkout")
            if miniaturized of w is not \(minimized) then set miniaturized of w to \(minimized)
        end tell
        """)
    }

    static func selectWordParagraph(_ n: Int, wholeLineAfterColon: Bool = false) {
        let p = wordParagraphs[n - 1]
        let skip = wholeLineAfterColon ? (p.firstIndex(of: ":").map { p.distance(from: p.startIndex, to: $0) + 2 } ?? 0) : 0
        script("""
        tell application "Microsoft Word"
            set r to text object of paragraph \(n) of active document
            set s to (start of content of r) + \(skip)
            set e to (end of content of r) - 1
            select (create range active document start s end e)
        end tell
        """)
    }

    static func selectWordEnd() {
        script("""
        tell application "Microsoft Word"
            set e to (end of content of text object of active document) - 1
            select (create range active document start e end e)
        end tell
        """)
    }

    /// Focuses a text field in the Safari page by its placeholder, through Accessibility.
    static func focusSafariField(_ placeholder: String) {
        guard let safari = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Safari").first else { return }
        let app = AXUIElementCreateApplication(safari.processIdentifier)
        var window: CFTypeRef?
        AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &window)
        guard let window else { return }
        if let field = find(window as! AXUIElement, placeholder: placeholder, depth: 0) {
            AXUIElementSetAttributeValue(field, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        } else {
            DemoStage.trace("no Safari field \(placeholder)")
        }
    }

    private static func find(_ element: AXUIElement, placeholder: String, depth: Int) -> AXUIElement? {
        guard depth < 30 else { return nil }
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        if (role as? String) == kAXTextFieldRole {
            var value: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXPlaceholderValueAttribute as CFString, &value)
            if (value as? String) == placeholder { return element }
        }
        var children: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children)
        for child in (children as? [AXUIElement]) ?? [] {
            if let hit = find(child, placeholder: placeholder, depth: depth + 1) { return hit }
        }
        return nil
    }
}

// MARK: - Sample clippings

@MainActor
enum DemoLibrary {
    static var rich = UUID(), link = UUID(), color = UUID(), receipt = UUID(), file = UUID(), invoice = UUID()
    static var agenda = UUID(), sloppy = UUID(), json = UUID(), name = UUID(), email = UUID()
    static var work = UUID(), personal = UUID(), safariLinks = UUID(), images = UUID()
    static var signature = UUID()

    static func fill() {
        let store = ClipStore.shared
        let stage = ProcessInfo.processInfo.environment["PASTELENS_DEBUG_DEMO_STAGE"] ?? "/tmp"

        work = UUID(); personal = UUID()
        store.upsertPastebin(Pastebin(id: work, name: "Work", symbol: "briefcase", colorName: "blue", order: 0.1))
        store.upsertPastebin(Pastebin(id: personal, name: "Personal", symbol: "house", colorName: "green", order: 0.2))
        store.upsertSmart(SmartPastebin(id: safariLinks, name: "Links from Safari", symbol: "safari", colorName: "teal",
                                        rules: [SmartRule(field: .sourceApp, op: .contains, value: "Safari"),
                                                SmartRule(field: .kind, op: .is, value: ClipKind.url.rawValue)], order: 0.1))
        store.upsertSmart(SmartPastebin(id: images, name: "Images", symbol: "photo", colorName: "orange",
                                        rules: [SmartRule(field: .kind, op: .is, value: ClipKind.image.rawValue)], order: 0.2))
        // The signature without its fill-in question: the prompt can't take keys while the
        // demo copy is in the background.
        if var sig = store.library.snippets.first(where: { $0.abbreviation == ";sig" }) {
            sig.template = "Best regards,\nJordan Lee\nNorthwind Supply · {date:MMMM d, yyyy}"
            store.upsertSnippet(sig)
            signature = sig.id
        }

        func add(_ content: ClipContent, _ minutes: Double, _ bundle: String, _ app: String, title: String? = nil, bins: [UUID] = []) -> UUID {
            let clip = store.add(content, title: title, source: (bundle, app), inHistory: true, pastebins: bins)
            store.update(clip.id) { $0.copiedAt = Date().addingTimeInterval(-minutes * 60); $0.createdAt = $0.copiedAt }
            return clip.id
        }
        let safari = "com.apple.Safari", mail = "com.apple.mail", notes = "com.apple.Notes", word = "com.microsoft.Word"

        _ = add(.text("https://developer.apple.com/documentation/swiftui"), 300, safari, "Safari")
        _ = add(.text("https://www.nationalgeographic.com/travel"), 260, safari, "Safari", bins: [personal])
        json = add(.text("{\"name\": \"PasteLens\", \"version\": \"1.2.7\", \"free\": true, \"platforms\": [\"macOS\"]}"), 220, "com.apple.dt.Xcode", "Xcode", bins: [work])
        _ = add(.text("Dinner Saturday at 7 — Luca’s on Pine Street"), 180, "com.apple.MobileSMS", "Messages", bins: [personal])
        sloppy = add(.text("i think we shoud move the launch to tuesday becuase the the build isnt ready"), 150, "com.tinyspeck.slackmacgap", "Slack")
        agenda = add(.text("Agenda: roadmap review, hiring plan, launch timeline"), 120, notes, "Notes")
        name = add(.text("Jordan Lee"), 100, "com.apple.AddressBook", "Contacts")
        email = add(.text("jordan@northwind.example"), 95, "com.apple.AddressBook", "Contacts")
        // A file: the receipt picture saved in the stage folder.
        let receiptURL = URL(fileURLWithPath: stage).appending(path: "Receipt.png")
        let receiptPNG = DemoPictures.receipt()
        try? receiptPNG.write(to: receiptURL)
        file = add(ClipContent(representations: [ClipRepresentation(type: UTI.fileURL, data: receiptURL.absoluteURL.dataRepresentation)]), 80, "com.apple.finder", "Finder")
        receipt = add(ClipContent(representations: [ClipRepresentation(type: UTI.png, data: receiptPNG)]), 70, "com.apple.Preview", "Preview")
        store.recognizeText(in: receipt)
        color = add(.text("#FF6B35"), 60, "com.figma.Desktop", "Figma")
        link = add(.text("https://www.apple.com/macos/"), 45, safari, "Safari")
        let rtf = NSAttributedString(string: "Team offsite: Thursday, 9:30 AM, Harbor Room", attributes: [
            .font: NSFont.boldSystemFont(ofSize: 14), .foregroundColor: NSColor.systemBlue])
        let rtfData = (try? rtf.data(from: NSRange(location: 0, length: rtf.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])) ?? Data()
        rich = add(ClipContent(representations: [ClipRepresentation(type: UTI.rtf, data: rtfData),
                                                 ClipRepresentation(type: UTI.plainText, data: Data(rtf.string.utf8))]), 30, mail, "Mail")
        invoice = add(.text("Invoice INV-2291 from Northwind — $1,284.00 due December 5"), 12, mail, "Mail", bins: [work])
        _ = word

        // About seven weeks of copying and pasting.
        var seed: UInt64 = 7
        func random(_ n: Int) -> Int { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Int((seed >> 33) % UInt64(n)) }
        for day in 1...48 {
            let weekend = (day % 7 == 2 || day % 7 == 3)
            let copies = weekend ? 4 + random(10) : 18 + random(30)
            let pastes = Int(Double(copies) * (0.55 + Double(random(30)) / 100))
            let date = Date().addingTimeInterval(-Double(day) * 86_400)
            for _ in 0..<copies { ActivityStore.shared.record(.copy, at: date) }
            for _ in 0..<pastes { ActivityStore.shared.record(.paste, at: date) }
        }
    }
}

enum DemoPictures {
    /// A store receipt, as a picture, so its text is only in pixels.
    static func receipt() -> Data {
        let size = NSSize(width: 520, height: 700)
        let image = NSImage(size: size, flipped: true) { rect in
            NSColor.white.setFill(); rect.fill()
            func draw(_ s: String, _ x: CGFloat, _ y: CGFloat, _ size: CGFloat, bold: Bool = false, right: Bool = false) {
                let font = NSFont.monospacedSystemFont(ofSize: size, weight: bold ? .bold : .regular)
                let a = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: NSColor.black])
                a.draw(at: NSPoint(x: right ? x - a.size().width : x, y: y))
            }
            draw("HARBOR MARKET", 150, 40, 30, bold: true)
            draw("220 Harbor Lane, Portland", 105, 86, 18)
            draw("Nov 18 2026   4:12 PM", 135, 114, 18)
            var y: CGFloat = 180
            for (item, price) in [("Coffee beans", "18.50"), ("Sourdough loaf", "7.25"), ("Olive oil", "21.90"),
                                  ("Apples 2 lb", "6.40"), ("Cheddar", "12.75"), ("Flowers", "14.00")] {
                draw(item, 50, y, 22); draw(price, 470, y, 22, right: true); y += 40
            }
            y += 20
            draw("Tax", 50, y, 22); draw("5.60", 470, y, 22, right: true); y += 50
            draw("Total", 50, y, 28, bold: true); draw("$86.40", 470, y, 28, bold: true, right: true)
            draw("Thank you!", 190, y + 90, 22)
            return true
        }
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return Data() }
        return rep.representation(using: .png, properties: [:]) ?? Data()
    }
}

// MARK: - State and views

@Observable
@MainActor
final class DemoState {
    enum Card { case intro, outro }
    var subtitle: String?
    var keys: String?
    var card: Card?
    var clipboard: String?
    var clipboardLost = false
    var safariCover = false
    var sync: Int?
    var terminal: [String]?
}

private let demoRed = Color(red: 0.92, green: 0.13, blue: 0.18)

private struct DemoDesk: View {
    let crop: CGRect
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.10, green: 0.07, blue: 0.13), Color(red: 0.30, green: 0.06, blue: 0.10)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Circle().fill(demoRed.opacity(0.35)).frame(width: 900).blur(radius: 160).offset(x: 520, y: 260)
            Circle().fill(Color(red: 0.35, green: 0.25, blue: 0.75).opacity(0.25)).frame(width: 800).blur(radius: 170).offset(x: -560, y: -200)
        }
        .ignoresSafeArea()
    }
}

private struct DemoOverlay: View {
    let state: DemoState
    let crop: CGRect
    let cover: CGRect

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            if state.safariCover {
                SafariStrip().frame(width: cover.width, height: cover.height).offset(x: cover.minX, y: cover.minY)
            }
            if let text = state.clipboard {
                ClipboardBubble(text: text, lost: state.clipboardLost)
                    .offset(x: crop.minX + crop.width - 520, y: crop.minY + 70)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .id(text)
            }
            if let step = state.sync {
                SyncScene(step: step).frame(width: crop.width, height: crop.height).offset(x: crop.minX, y: crop.minY)
                    .transition(.opacity)
            }
            if let lines = state.terminal {
                TerminalCard(lines: lines).frame(width: 620, height: 380).offset(x: crop.minX + 40, y: crop.minY + 170)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
            if let card = state.card {
                TitleCard(outro: card == .outro).frame(width: crop.width, height: crop.height).offset(x: crop.minX, y: crop.minY)
                    .transition(.opacity)
            }
            VStack(spacing: 14) {
                if let keys = state.keys {
                    Text(keys)
                        .font(.system(size: 34, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 26).padding(.vertical, 12)
                        .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 16))
                        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.25)))
                        .transition(.scale(scale: 0.85).combined(with: .opacity))
                }
                if let subtitle = state.subtitle {
                    Text(subtitle)
                        .font(.system(size: 27, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 20).padding(.vertical, 9)
                        .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .frame(width: crop.width, height: 170, alignment: .bottom)
            .offset(x: crop.minX, y: crop.maxY - 170 - 28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct SafariStrip: View {
    var body: some View {
        ZStack {
            Rectangle().fill(Color(white: 0.965))
            HStack(spacing: 8) {
                ForEach([Color(red: 1, green: 0.37, blue: 0.34), Color(red: 1, green: 0.74, blue: 0.18), Color(red: 0.16, green: 0.79, blue: 0.25)], id: \.self) {
                    Circle().fill($0).frame(width: 12, height: 12)
                }
                Spacer()
            }.padding(.leading, 18)
            HStack(spacing: 6) {
                Image(systemName: "lock.fill").font(.system(size: 11))
                Text("northwind.example/checkout").font(.system(size: 13))
            }
            .foregroundStyle(.secondary)
            .frame(width: 420, height: 28)
            .background(Color(white: 0.9), in: RoundedRectangle(cornerRadius: 8))
            VStack { Spacer(); Rectangle().fill(Color(white: 0.84)).frame(height: 1) }
        }
        .environment(\.colorScheme, .light)
    }
}

private struct ClipboardBubble: View {
    let text: String
    let lost: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Clipboard", systemImage: "doc.on.clipboard").font(.system(size: 15, weight: .semibold)).foregroundStyle(.white.opacity(0.7))
            Text(text).font(.system(size: 22, weight: .medium)).foregroundStyle(.white)
            if lost {
                Text("…and the one before? Gone.").font(.system(size: 16, weight: .semibold)).foregroundStyle(Color(red: 1, green: 0.55, blue: 0.55))
            }
        }
        .padding(18)
        .frame(width: 460, alignment: .leading)
        .background(.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.white.opacity(0.18)))
    }
}

private struct TitleCard: View {
    let outro: Bool
    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            LinearGradient(colors: [Color(red: 0.10, green: 0.07, blue: 0.13).opacity(0.85), Color(red: 0.30, green: 0.06, blue: 0.10).opacity(0.85)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            VStack(spacing: 22) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 220, height: 220)
                    .shadow(color: .black.opacity(0.4), radius: 24, y: 10)
                Text("PasteLens").font(.system(size: 76, weight: .bold, design: .rounded)).foregroundStyle(.white)
                Text(outro ? "Copy everything… and find it again." : "The clipboard that remembers.")
                    .font(.system(size: 30, weight: .medium)).foregroundStyle(.white.opacity(0.85))
                if outro {
                    Text("Free for Mac  ·  stevemanke.com/pastelens")
                        .font(.system(size: 24, weight: .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 22).padding(.vertical, 10)
                        .background(demoRed, in: Capsule())
                        .padding(.top, 8)
                }
            }
        }
    }
}

private struct SyncScene: View {
    let step: Int
    var body: some View {
        ZStack {
            Rectangle().fill(.black.opacity(0.55))
            HStack(spacing: 70) {
                MacCard(name: "MacBook Pro", symbol: "laptopcomputer", pinned: step >= 1)
                VStack(spacing: 14) {
                    Image(systemName: step >= 2 ? "lock.fill" : "icloud.fill")
                        .font(.system(size: 54, weight: .semibold))
                        .foregroundStyle(.white)
                        .contentTransition(.symbolEffect(.replace))
                    Text(step >= 2 ? "AES-256-GCM" : "iCloud").font(.system(size: 22, weight: .bold, design: .monospaced)).foregroundStyle(.white)
                    if step >= 3 {
                        Label("Passphrase stays on your Macs", systemImage: "key.fill")
                            .font(.system(size: 17, weight: .semibold)).foregroundStyle(.white.opacity(0.85))
                            .transition(.opacity)
                    }
                    Image(systemName: "arrow.left.arrow.right").font(.system(size: 30)).foregroundStyle(.white.opacity(0.7))
                }
                .frame(width: 300)
                MacCard(name: "iMac", symbol: "desktopcomputer", pinned: step >= 2)
            }
        }
    }
}

private struct MacCard: View {
    let name: String
    let symbol: String
    let pinned: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(name, systemImage: symbol).font(.system(size: 22, weight: .bold)).foregroundStyle(.white)
            ForEach(Array(["Invoice INV-2291 from Northwind", "Team offsite: Thursday, 9:30", "#FF6B35", "Agenda: roadmap review"].enumerated()), id: \.offset) { i, row in
                HStack {
                    Text(row).font(.system(size: 16)).foregroundStyle(.white.opacity(0.9)).lineLimit(1)
                    Spacer()
                    if i == 0 && pinned { Image(systemName: "pin.fill").foregroundStyle(demoRed).transition(.scale.combined(with: .opacity)) }
                }
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(.white.opacity(i == 0 && pinned ? 0.16 : 0.07), in: RoundedRectangle(cornerRadius: 9))
            }
        }
        .padding(22)
        .frame(width: 400)
        .background(Color(white: 0.12).opacity(0.95), in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(.white.opacity(0.15)))
    }
}

private struct TerminalCard: View {
    let lines: [String]
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                ForEach([Color(red: 1, green: 0.37, blue: 0.34), Color(red: 1, green: 0.74, blue: 0.18), Color(red: 0.16, green: 0.79, blue: 0.25)], id: \.self) {
                    Circle().fill($0).frame(width: 12, height: 12)
                }
                Spacer()
                Text("zsh").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(0.5))
                Spacer()
            }
            .padding(14)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, l in
                    Text(l).font(.system(size: 17, design: .monospaced))
                        .foregroundStyle(l.hasPrefix("$") ? .white : Color(red: 0.6, green: 0.9, blue: 0.65))
                }
            }
            .padding(.horizontal, 20)
            Spacer()
        }
        .background(Color(red: 0.08, green: 0.08, blue: 0.1).opacity(0.97), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.15)))
        .shadow(color: .black.opacity(0.5), radius: 30, y: 12)
    }
}
#endif
