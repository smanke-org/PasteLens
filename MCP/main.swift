import AppKit
import Foundation
import PasteLensKit

// pastelens-mcp — a Model Context Protocol server on stdio, so AI assistants can search
// clippings, run filters and paste. Each tool forwards to the running PasteLens app.

let protocolVersion = "2025-06-18"

func send(_ object: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]) else { return }
    FileHandle.standardOutput.write(data + Data("\n".utf8))
}

func toolList() -> [[String: Any]] {
    Bridge.commands.map { command in
        var properties: [String: Any] = [:]
        for p in command.parameters {
            let key = p.name.replacingOccurrences(of: "-", with: "_")
            properties[key] = ["type": p.kind, "description": p.summary]
        }
        // An image can't arrive as a file path the app can read, so it comes as base64.
        return [
            "name": command.mcpName,
            "description": command.summary,
            "inputSchema": ["type": "object", "properties": properties,
                            "required": command.parameters.filter(\.required).map { $0.name.replacingOccurrences(of: "-", with: "_") }],
            "annotations": ["readOnlyHint": !command.mutates, "destructiveHint": command.name.hasPrefix("delete") || command.name.hasPrefix("clear")],
        ]
    }
}

func ensureRunning() throws {
    if (try? Bridge.call("get-pastebins", args: [:], timeout: 3)) != nil { return }
    guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Bridge.bundleID) else { throw Bridge.Failure("PasteLens isn't installed.") }
    let config = NSWorkspace.OpenConfiguration()
    config.activates = false
    let done = DispatchSemaphore(value: 0)
    NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in done.signal() }
    _ = done.wait(timeout: .now() + 10)
    for _ in 0..<40 {
        if (try? Bridge.call("get-pastebins", args: [:], timeout: 2)) != nil { return }
        Thread.sleep(forTimeInterval: 0.25)
    }
    throw Bridge.Failure("PasteLens didn't start in time.")
}

func callTool(_ name: String, _ arguments: [String: Any]) -> [String: Any] {
    guard let command = Bridge.command(named: name) else {
        return ["content": [["type": "text", "text": "Unknown tool \(name)"]], "isError": true]
    }
    var args: [String: String] = [:]
    for (key, value) in arguments {
        let dashed = key.replacingOccurrences(of: "_", with: "-")
        if let s = value as? String { args[dashed] = s }
        else if let b = value as? Bool { args[dashed] = b ? "true" : "false" }
        else if let n = value as? NSNumber { args[dashed] = n.stringValue }
        else if let data = try? JSONSerialization.data(withJSONObject: value) { args[dashed] = String(decoding: data, as: UTF8.self) }
    }
    do {
        try ensureRunning()
        let result = try Bridge.call(command.name, args: args)
        if command.name == "get-clipping-image", let dict = result as? [String: Any], let data = dict["data"] as? String {
            return ["content": [["type": "image", "data": data, "mimeType": dict["mime_type"] as? String ?? "image/png"]]]
        }
        let object: Any = JSONSerialization.isValidJSONObject(result) ? result : ["result": result]
        let text = (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]))
            .map { String(decoding: $0, as: UTF8.self) } ?? "\(result)"
        return ["content": [["type": "text", "text": text]]]
    } catch {
        return ["content": [["type": "text", "text": error.localizedDescription]], "isError": true]
    }
}

while let line = readLine(strippingNewline: true) {
    guard let data = line.data(using: .utf8), let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let method = message["method"] as? String else { continue }
    let id = message["id"]
    let params = message["params"] as? [String: Any] ?? [:]
    func reply(_ result: [String: Any]) { if let id { send(["jsonrpc": "2.0", "id": id, "result": result]) } }
    switch method {
    case "initialize":
        reply([
            "protocolVersion": (params["protocolVersion"] as? String) ?? protocolVersion,
            "capabilities": ["tools": ["listChanged": false]],
            "serverInfo": ["name": "pastelens", "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"],
            "instructions": "PasteLens is a macOS clipboard manager. Clipping ids come from get_clippings. Pasting needs the user's Accessibility permission for PasteLens.",
        ])
    case "notifications/initialized", "notifications/cancelled":
        break
    case "ping":
        reply([:])
    case "tools/list":
        reply(["tools": toolList()])
    case "tools/call":
        reply(callTool(params["name"] as? String ?? "", params["arguments"] as? [String: Any] ?? [:]))
    default:
        if let id { send(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Method not found: \(method)"]]) }
    }
}
