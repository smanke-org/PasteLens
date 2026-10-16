import AppKit
import LinkPresentation
import PasteLensKit
import QuickLookThumbnailing
import SwiftUI

/// Named colors for pastebins.
enum BinColor {
    static let names = ["blue", "purple", "pink", "red", "orange", "yellow", "green", "teal", "gray"]
    static func color(_ name: String) -> Color {
        switch name {
        case "purple": .purple
        case "pink": .pink
        case "red": .red
        case "orange": .orange
        case "yellow": .yellow
        case "green": .green
        case "teal": .teal
        case "gray": .gray
        default: .blue
        }
    }
}

/// Icon of the app a clipping came from, cached.
@MainActor
enum AppIcons {
    private static var cache: [String: NSImage] = [:]
    static func icon(for bundleID: String?) -> NSImage? {
        guard let bundleID else { return nil }
        if let cached = cache[bundleID] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        cache[bundleID] = icon
        return icon
    }
}

/// Small image thumbnails, made once per clipping.
@MainActor
enum Thumbnails {
    private static var cache: [UUID: NSImage] = [:]
    static func image(for clip: Clipping, maxSide: CGFloat = 400) -> NSImage? {
        if let cached = cache[clip.id] { return cached }
        guard let content = ClipStore.shared.content(for: clip.id), let cg = Recognizer.cgImage(from: content) else { return nil }
        let scale = min(1, maxSide / CGFloat(max(cg.width, cg.height)))
        let size = NSSize(width: CGFloat(cg.width) * scale, height: CGFloat(cg.height) * scale)
        let image = NSImage(cgImage: cg, size: size)
        if cache.count > 200 { cache.removeAll() }
        cache[clip.id] = image
        return image
    }
}

extension ColorText.RGBA {
    var color: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: a) }
}

enum RelativeTime {
    /// "just now" for the last minute (the system format says "in 0 sec." when clocks differ slightly).
    static func string(_ date: Date, now: Date = Date()) -> String {
        if abs(now.timeIntervalSince(date)) < 60 { return "just now" }
        return date.formatted(.relative(presentation: .numeric, unitsStyle: .abbreviated))
    }
}

/// One clipping in a list: kind icon or thumbnail, text, source and age.
struct ClipRowContent: View {
    let clip: Clipping
    var lines = 1
    var index: Int?
    var showsSource = true

    var body: some View {
        HStack(spacing: 8) {
            leading
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .lineLimit(lines)
                    .truncationMode(.tail)
                    .font(clip.kind == .text || clip.kind == .richText ? .body : .body)
                HStack(spacing: 4) {
                    if clip.pinned { Image(systemName: "pin.fill").foregroundStyle(.orange) }
                    if clip.sensitive { Image(systemName: "lock.fill").foregroundStyle(.red) }
                    if let note = clip.note, !note.isEmpty { Image(systemName: "note.text"); Text(note).lineLimit(1) }
                    else if showsSource, let source = clip.sourceName { Text(source).lineLimit(1) }
                    Text("·")
                    Text(RelativeTime.string(clip.copiedAt))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if let index, index < 9 {
                Text("⌘\(index + 1)").font(.caption.monospaced()).foregroundStyle(.tertiary)
            }
        }
        .contentShape(Rectangle())
    }

    var title: String {
        if clip.sensitive { return SensitiveScanner.mask(clip.previewText, finding: nil).replacingOccurrences(of: "Sensitive", with: clip.title ?? "Sensitive") }
        if let t = clip.title, !t.isEmpty { return t }
        switch clip.kind {
        case .image:
            if let w = clip.imageWidth, let h = clip.imageHeight { return "Image \(w) × \(h)" + (clip.ocrText.map { $0.isEmpty ? "" : " — " + $0.prefix(80).replacingOccurrences(of: "\n", with: " ") } ?? "") }
            return "Image"
        case .file:
            let paths = clip.previewText.split(separator: "\n")
            let first = paths.first.map { URL(fileURLWithPath: String($0)).lastPathComponent } ?? "File"
            return paths.count > 1 ? "\(first) and \(paths.count - 1) more" : first
        default:
            let collapsed = lines == 1 ? clip.previewText.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ⏎ ")
                : clip.previewText.trimmingCharacters(in: .whitespacesAndNewlines)
            return collapsed.isEmpty ? clip.kind.label : collapsed
        }
    }

    @ViewBuilder var leading: some View {
        if clip.kind == .image, let image = Thumbnails.image(for: clip, maxSide: 80) {
            Image(nsImage: image).resizable().aspectRatio(contentMode: .fill).frame(width: 28, height: 28).clipShape(.rect(cornerRadius: 4))
        } else if clip.kind == .color, let rgba = ColorText.parse(clip.previewText) {
            RoundedRectangle(cornerRadius: 5).fill(rgba.color).frame(width: 28, height: 28)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(.separator))
        } else if let icon = AppIcons.icon(for: clip.sourceBundleID) {
            ZStack(alignment: .bottomTrailing) {
                Image(nsImage: icon).resizable().frame(width: 28, height: 28)
                Image(systemName: clip.kind.symbol).font(.system(size: 9, weight: .bold)).padding(2)
                    .background(.regularMaterial, in: .circle)
            }
        } else {
            Image(systemName: clip.kind.symbol).font(.title3).foregroundStyle(.secondary).frame(width: 28, height: 28)
        }
    }
}

/// A large view of a clipping: text (editable), image with its recognized text, color,
/// link with a preview, or files.
struct ClipPreview: View {
    let clip: Clipping
    var editable = true
    @State private var text = ""
    @State private var reveal = false
    @State private var dirty = false
    @State private var store = ClipStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if clip.sensitive && !reveal {
                ContentUnavailableView {
                    Label(clip.title ?? "Sensitive", systemImage: "lock.fill")
                } description: {
                    Text("Hidden because it looks like a secret. It isn't synced and is deleted \(clip.expiresAt.map { $0.formatted(.relative(presentation: .named)) } ?? "soon").")
                } actions: {
                    Button("Show") { reveal = true }
                    Button("Not a Secret") { store.update(clip.id) { $0.sensitive = false; $0.expiresAt = nil; $0.title = nil } }
                }
            } else {
                content
            }
            Divider()
            details.padding(10)
        }
        .onAppear(perform: load)
        .onChange(of: clip.id) { load() }
        .onChange(of: clip.contentHash) { if !dirty { load() } }
    }

    private func load() {
        text = store.text(of: clip.id) ?? clip.previewText
        dirty = false
        reveal = false
    }

    @ViewBuilder var content: some View {
        switch clip.kind {
        case .image:
            ScrollView {
                VStack(alignment: .leading) {
                    if let image = Thumbnails.image(for: clip, maxSide: 1200) {
                        Image(nsImage: image).resizable().aspectRatio(contentMode: .fit).frame(maxWidth: .infinity)
                    } else {
                        ContentUnavailableView("Image Not Available Yet", systemImage: "icloud.and.arrow.down",
                                               description: Text("It's still coming from another Mac."))
                    }
                    if let ocr = clip.ocrText, !ocr.isEmpty {
                        GroupBox {
                            Text(ocr).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        } label: {
                            HStack {
                                Label("Text in Image", systemImage: "text.viewfinder")
                                Spacer()
                                Button("Copy Text") { Paster.write(text: ocr) }.controlSize(.small)
                            }
                        }
                    } else if Preferences.shared.ocr {
                        Button("Recognize Text") { store.recognizeText(in: clip.id) }.controlSize(.small)
                    }
                }.padding()
            }
        case .color:
            VStack(spacing: 12) {
                if let rgba = ColorText.parse(clip.previewText) {
                    RoundedRectangle(cornerRadius: 12).fill(rgba.color).frame(height: 140)
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.separator))
                    ColorFormats(rgba: rgba)
                }
                Text(clip.previewText).font(.title3.monospaced()).textSelection(.enabled)
            }.padding()
            Spacer()
        case .file:
            List(clip.previewText.split(separator: "\n").map(String.init), id: \.self) { path in
                HStack {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable().frame(width: 24, height: 24)
                    VStack(alignment: .leading) {
                        Text(URL(fileURLWithPath: path).lastPathComponent)
                        Text(path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) } label: { Image(systemName: "magnifyingglass") }
                        .buttonStyle(.borderless).help("Show in Finder")
                }
            }
        case .url:
            VStack(alignment: .leading, spacing: 8) {
                if Preferences.shared.linkPreviews, let url = URL(string: clip.previewText.trimmingCharacters(in: .whitespacesAndNewlines)),
                   url.scheme?.hasPrefix("http") == true {
                    LinkPreview(url: url).frame(maxWidth: .infinity, minHeight: 120, maxHeight: 260)
                }
                textEditor
            }.padding(.top, 8)
        default:
            textEditor
        }
    }

    var textEditor: some View {
        VStack(spacing: 0) {
            TextEditor(text: Binding(get: { text }, set: { text = $0; dirty = true }))
                .font(.body.monospaced())
                .scrollContentBackground(.hidden)
                .padding(6)
                .disabled(!editable)
            if dirty {
                HStack {
                    Text("Edited").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Revert") { load() }
                    Button("Save") {
                        store.replaceText(clip.id, with: text)
                        dirty = false
                    }.keyboardShortcut("s", modifiers: .command)
                }.padding(6).background(.bar)
            }
        }
    }

    var details: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if let icon = AppIcons.icon(for: clip.sourceBundleID) { Image(nsImage: icon).resizable().frame(width: 16, height: 16) }
                Text(clip.sourceName ?? "Unknown app")
                Text("·")
                Text(clip.kind.label)
                Text("·")
                Text(ByteCountFormatter.string(fromByteCount: Int64(clip.sizeBytes), countStyle: .file))
                if clip.textLength > 0, clip.kind != .image {
                    Text("·")
                    Text("\(clip.textLength) characters")
                }
            }
            HStack(spacing: 6) {
                Text("Copied \(clip.copiedAt.formatted(date: .abbreviated, time: .shortened))")
                if clip.createdAt.timeIntervalSince(clip.copiedAt) < -60 {
                    Text("· first \(clip.createdAt.formatted(date: .abbreviated, time: .shortened))")
                }
            }
            NoteField(clip: clip)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

struct NoteField: View {
    let clip: Clipping
    @State private var note = ""
    var body: some View {
        TextField("Add a note…", text: $note, onCommit: save)
            .textFieldStyle(.plain)
            .font(.caption)
            .onAppear { note = clip.note ?? "" }
            .onChange(of: clip.id) { note = clip.note ?? "" }
            .onDisappear(perform: save)
    }
    private func save() {
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed != (clip.note ?? "") { ClipStore.shared.update(clip.id) { $0.note = trimmed.isEmpty ? nil : trimmed } }
    }
}

/// A color shown in the common notations, each copyable.
struct ColorFormats: View {
    let rgba: ColorText.RGBA
    var formats: [(String, String)] {
        let r = Int((rgba.r * 255).rounded()), g = Int((rgba.g * 255).rounded()), b = Int((rgba.b * 255).rounded())
        let ns = NSColor(srgbRed: rgba.r, green: rgba.g, blue: rgba.b, alpha: rgba.a)
        var h: CGFloat = 0, s: CGFloat = 0, br: CGFloat = 0, a: CGFloat = 0
        ns.usingColorSpace(.sRGB)?.getHue(&h, saturation: &s, brightness: &br, alpha: &a)
        let l = (2 - s) * br / 2
        let sl = l > 0 && l < 1 ? s * br / (l < 0.5 ? l * 2 : 2 - l * 2) : 0
        return [
            ("Hex", String(format: "#%02X%02X%02X", r, g, b)),
            ("RGB", rgba.a < 1 ? "rgba(\(r), \(g), \(b), \(String(format: "%.2f", rgba.a)))" : "rgb(\(r), \(g), \(b))"),
            ("HSL", "hsl(\(Int((h * 360).rounded())), \(Int((sl * 100).rounded()))%, \(Int((l * 100).rounded()))%)"),
            ("Swift", String(format: "Color(red: %.3f, green: %.3f, blue: %.3f)", rgba.r, rgba.g, rgba.b)),
        ]
    }
    var body: some View {
        Grid(alignment: .leading) {
            ForEach(formats, id: \.0) { name, value in
                GridRow {
                    Text(name).foregroundStyle(.secondary)
                    Text(value).font(.body.monospaced()).textSelection(.enabled)
                    Button { Paster.write(text: value) } label: { Image(systemName: "doc.on.doc") }.buttonStyle(.borderless).help("Copy")
                }
            }
        }
    }
}

/// The page's title, image and site, fetched by LinkPresentation.
struct LinkPreview: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> LPLinkView {
        let view = LPLinkView(url: url)
        Self.fetch(url) { view.metadata = $0 }
        return view
    }

    func updateNSView(_ view: LPLinkView, context: Context) {
        guard view.metadata.originalURL != url else { return }
        view.metadata = LPLinkMetadata()
        view.metadata.originalURL = url
        Self.fetch(url) { view.metadata = $0 }
    }

    @MainActor private static var cache: [URL: LPLinkMetadata] = [:]

    @MainActor static func fetch(_ url: URL, done: @escaping (LPLinkMetadata) -> Void) {
        if let cached = cache[url] { done(cached); return }
        let provider = LPMetadataProvider()
        provider.timeout = 8
        provider.startFetchingMetadata(for: url) { metadata, _ in
            guard let metadata else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    cache[url] = metadata
                    done(metadata)
                }
            }
        }
    }
}
