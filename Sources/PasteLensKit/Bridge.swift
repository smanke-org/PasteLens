import Darwin
import Foundation

/// How the `pastelens` command-line tool and the MCP helper talk to the running app: one
/// JSON request and one JSON reply per connection, over a Unix socket in the app group container.
public enum Bridge {
    public static let appGroup = "32CWL275JJ.com.smanke.PasteLens"
    public static let bundleID = "com.smanke.PasteLens"

    /// ~/Library/Group Containers/<group>/bridge.sock. Built by hand so tools that aren't the
    /// app find the same place.
    public static var socketPath: String {
        if let override = ProcessInfo.processInfo.environment["PASTELENS_BRIDGE_SOCKET"] { return override }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        // Inside the sandbox, the home directory is the container; the real one is above it.
        let realHome = home.contains("/Library/Containers/") ? String(home[..<home.range(of: "/Library/Containers/")!.lowerBound]) : home
        return "\(realHome)/Library/Group Containers/\(appGroup)/bridge.sock"
    }

    public struct Parameter: Sendable {
        public var name: String
        public var kind: String   // "string", "integer", "boolean"
        public var required: Bool
        public var summary: String
        public init(_ name: String, _ kind: String = "string", required: Bool = false, _ summary: String) {
            self.name = name
            self.kind = kind
            self.required = required
            self.summary = summary
        }
        public init(_ name: String, _ summary: String) {
            self.init(name, "string", required: false, summary)
        }
    }

    public struct Command: Sendable {
        public var name: String
        public var summary: String
        public var parameters: [Parameter]
        /// Changes or deletes data, or acts on the screen; tools ask before running these.
        public var mutates: Bool
        public var mcpName: String { name.replacingOccurrences(of: "-", with: "_") }

        public init(name: String, summary: String, parameters: [Parameter], mutates: Bool) {
            self.name = name
            self.summary = summary
            self.parameters = parameters
            self.mutates = mutates
        }
    }

    public static let commands: [Command] = [
        Command(name: "get-pastebins", summary: "List pastebins, smart pastebins and how many clippings each holds.", parameters: [], mutates: false),
        Command(name: "get-clippings", summary: "List or search clippings in a pastebin, newest first. Defaults to the first 20 in History.", parameters: [
            Parameter("query", "Words to search for; typos and skipped letters are tolerated."),
            Parameter("limit", "integer", "How many to return (default 20, at most 500)."),
            Parameter("offset", "integer", "How many to skip, for paging."),
            Parameter("pastebin-id", "Pastebin or smart pastebin id (from get-pastebins). Default: History."),
            Parameter("since", "Only clippings copied on or after this ISO 8601 date."),
        ], mutates: false),
        Command(name: "get-clipping-by-index", summary: "The clipping at a position in a pastebin; 0 is the most recent.", parameters: [
            Parameter("index", "integer", required: true, "Position, starting at 0."),
            Parameter("pastebin-id", "Pastebin id. Default: History."),
        ], mutates: false),
        Command(name: "get-clipping-text", summary: "The full text of a clipping.", parameters: [
            Parameter("id", required: true, "Clipping id."),
        ], mutates: false),
        Command(name: "get-clipping-image", summary: "A clipping's image as base64 PNG (or the original bytes for PNG/JPEG).", parameters: [
            Parameter("id", required: true, "Clipping id."),
        ], mutates: false),
        Command(name: "get-clipping-data", summary: "Raw bytes of one pasteboard type of a clipping, base64-encoded.", parameters: [
            Parameter("id", required: true, "Clipping id."),
            Parameter("type", required: true, "A type from the clipping's types list, such as public.html."),
        ], mutates: false),
        Command(name: "list-filters", summary: "All filters, built-in and your own.", parameters: [], mutates: false),
        Command(name: "apply-filter", summary: "Run a filter on a clipping or on supplied text and return the result.", parameters: [
            Parameter("filter-id", required: true, "Filter id or exact name (from list-filters)."),
            Parameter("id", "Clipping id to filter."),
            Parameter("text", "Text to filter, instead of a clipping."),
        ], mutates: false),
        Command(name: "list-snippets", summary: "Snippets with their abbreviations and templates.", parameters: [], mutates: false),
        Command(name: "expand-snippet", summary: "Expand a snippet's placeholders and return the text.", parameters: [
            Parameter("snippet-id", required: true, "Snippet id, name or abbreviation."),
            Parameter("inputs", "JSON object of values for {input:Name} fields."),
        ], mutates: false),
        Command(name: "write-to-pasteboard", summary: "Put a clipping, text or an image on the system clipboard. Text and images also become new clippings.", parameters: [
            Parameter("id", "Clipping id."),
            Parameter("text", "Text to copy."),
            Parameter("image-base64", "Image bytes, base64-encoded."),
            Parameter("mime-type", "Image type, such as image/png (default image/png)."),
        ], mutates: true),
        Command(name: "add-clipping", summary: "Save text as a new clipping without touching the clipboard.", parameters: [
            Parameter("text", required: true, "The text."),
            Parameter("pastebin-id", "Also save it into this pastebin."),
            Parameter("title", "A title to show instead of the first line."),
        ], mutates: true),
        Command(name: "paste-clipboard", summary: "Paste the clipboard into the frontmost app (needs Accessibility permission).", parameters: [], mutates: true),
        Command(name: "add-to-stack", summary: "Add clippings to the paste stack, to paste one after another.", parameters: [
            Parameter("ids", required: true, "Comma-separated clipping ids."),
        ], mutates: true),
        Command(name: "move-to-pastebin", summary: "Move clippings into a pastebin. They leave History, so clearing History won't remove them.", parameters: [
            Parameter("ids", required: true, "Comma-separated clipping ids."),
            Parameter("pastebin-id", required: true, "Pastebin id (from get-pastebins), or \"history\" to move them back to History."),
        ], mutates: true),
        Command(name: "pin-clipping", summary: "Pin or unpin a clipping so history limits never remove it.", parameters: [
            Parameter("id", required: true, "Clipping id."),
            Parameter("pinned", "boolean", "true to pin (default), false to unpin."),
        ], mutates: true),
        Command(name: "delete-clipping", summary: "Delete a clipping permanently, on every Mac that syncs.", parameters: [
            Parameter("id", required: true, "Clipping id."),
        ], mutates: true),
        Command(name: "clear-pastebin", summary: "Delete every clipping in History (pinned and saved clippings stay). Irreversible.", parameters: [], mutates: true),
    ]

    public static func command(named name: String) -> Command? {
        commands.first { $0.name == name || $0.mcpName == name }
    }

    // MARK: Wire format

    public struct Failure: LocalizedError {
        public var message: String
        public init(_ message: String) { self.message = message }
        public var errorDescription: String? { message }
    }

    /// Sends one request and waits for the reply.
    public static func call(_ command: String, args: [String: String], timeout: TimeInterval = 60) throws -> Any {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure("Couldn't create a socket.") }
        defer { close(fd) }
        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var address = try unixAddress(socketPath)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else { throw Failure("PasteLens isn't running, or its bridge isn't reachable (\(String(cString: strerror(errno)))).") }
        var request = try JSONSerialization.data(withJSONObject: ["command": command, "args": args])
        request.append(0x0A)
        try writeAll(fd, request)
        shutdown(fd, SHUT_WR)
        let reply = try readAll(fd)
        guard let object = try JSONSerialization.jsonObject(with: reply) as? [String: Any] else { throw Failure("Unreadable reply.") }
        if let error = object["error"] as? String { throw Failure(error) }
        return object["result"] ?? NSNull()
    }

    static func unixAddress(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count < capacity else { throw Failure("Socket path too long: \(path)") }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        return address
    }

    static func writeAll(_ fd: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = write(fd, raw.baseAddress! + offset, raw.count - offset)
                guard n > 0 else { throw Failure("Write failed.") }
                offset += n
            }
        }
    }

    static func readAll(_ fd: Int32, max: Int = 512 << 20) throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let n = read(fd, &buffer, buffer.count)
            if n == 0 { break }
            guard n > 0 else { throw Failure("Timed out waiting for PasteLens.") }
            data.append(buffer, count: n)
            guard data.count < max else { throw Failure("Reply too large.") }
        }
        return data
    }
}

/// The app's side: accepts connections and answers each request with `handler`.
public final class BridgeServer: @unchecked Sendable {
    public typealias Handler = @Sendable (_ command: String, _ args: [String: String]) async throws -> Any

    private let path: String
    private let handler: Handler
    private var listenFD: Int32 = -1
    private var source: DispatchSourceRead?
    private let queue = DispatchQueue(label: "PasteLens.bridge")

    public init(path: String = Bridge.socketPath, handler: @escaping Handler) {
        self.path = path
        self.handler = handler
    }

    public func start() throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        unlink(path)
        listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFD >= 0 else { throw Bridge.Failure("socket() failed") }
        var address = try Bridge.unixAddress(path)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listenFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0 else { throw Bridge.Failure("bind() failed: \(String(cString: strerror(errno)))") }
        chmod(path, 0o600)
        guard listen(listenFD, 16) == 0 else { throw Bridge.Failure("listen() failed") }
        let source = DispatchSource.makeReadSource(fileDescriptor: listenFD, queue: queue)
        source.setEventHandler { [weak self] in self?.accept() }
        source.resume()
        self.source = source
    }

    public func stop() {
        source?.cancel()
        if listenFD >= 0 { close(listenFD) }
        unlink(path)
    }

    private func accept() {
        let fd = Darwin.accept(listenFD, nil, nil)
        guard fd >= 0 else { return }
        var tv = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var nosigpipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &nosigpipe, socklen_t(MemoryLayout<Int32>.size))
        let handler = self.handler
        DispatchQueue.global().async {
            var reply: [String: Any]
            do {
                let data = try Bridge.readAll(fd, max: 128 << 20)
                guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let command = object["command"] as? String else { throw Bridge.Failure("Bad request.") }
                let args = object["args"] as? [String: String] ?? [:]
                let semaphore = DispatchSemaphore(value: 0)
                let box = ResultBox()
                Task {
                    do { box.value = .success(try await handler(command, args)) } catch { box.value = .failure(error) }
                    semaphore.signal()
                }
                semaphore.wait()
                switch box.value! {
                case .success(let result): reply = ["result": result]
                case .failure(let error): reply = ["error": error.localizedDescription]
                }
            } catch {
                reply = ["error": error.localizedDescription]
            }
            let out = (try? JSONSerialization.data(withJSONObject: reply, options: [.withoutEscapingSlashes]))
                ?? Data(#"{"error":"Couldn't encode the reply."}"#.utf8)
            try? Bridge.writeAll(fd, out)
            close(fd)
        }
    }
}

private final class ResultBox: @unchecked Sendable {
    var value: Result<Any, Error>?
}
