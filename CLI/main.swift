import AppKit
import Foundation
import PasteLensKit

// pastelens — PasteLens from the command line. Prints JSON on stdout; errors are JSON on
// stderr with a non-zero exit status. Starts PasteLens if it isn't running.

func fail(_ message: String, code: Int32 = 1) -> Never {
    let data = (try? JSONSerialization.data(withJSONObject: ["error": message])) ?? Data()
    FileHandle.standardError.write(data + Data("\n".utf8))
    exit(code)
}

func printJSON(_ value: Any) {
    let object: Any = JSONSerialization.isValidJSONObject(value) ? value : ["result": value]
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else {
        fail("Couldn't encode the result.")
    }
    FileHandle.standardOutput.write(data + Data("\n".utf8))
}

func usage() -> String {
    var lines = ["usage: pastelens <command> [--option value ...]", "", "Commands:"]
    for command in Bridge.commands {
        lines.append("  \(command.name)")
        lines.append("      \(command.summary)")
        for p in command.parameters {
            lines.append("      --\(p.name)\(p.required ? " (required)" : "")  \(p.summary)")
        }
    }
    lines += ["", "Extra options:", "  --text -            read the text from standard input",
              "  --image-file PATH   (write-to-pasteboard) image to copy; - reads standard input",
              "  -o PATH             (get-clipping-image, get-clipping-data) write the bytes to a file"]
    return lines.joined(separator: "\n")
}

var arguments = Array(CommandLine.arguments.dropFirst())
guard let name = arguments.first, !["help", "-h", "--help"].contains(name) else {
    print(usage())
    exit(arguments.isEmpty ? 1 : 0)
}
arguments.removeFirst()
guard let command = Bridge.command(named: name) else { fail("Unknown command '\(name)'. Run `pastelens help`.") }

var args: [String: String] = [:]
var output: String?
var i = 0
while i < arguments.count {
    let flag = arguments[i]
    guard flag.hasPrefix("-") else { fail("Unexpected argument '\(flag)'.") }
    guard i + 1 < arguments.count else { fail("\(flag) needs a value.") }
    let value = arguments[i + 1]
    let key = flag.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    switch key {
    case "o", "output": output = value
    case "image-file":
        let data = value == "-" ? FileHandle.standardInput.readDataToEndOfFile() : (try? Data(contentsOf: URL(fileURLWithPath: value)))
        guard let data else { fail("Can't read \(value).") }
        args["image-base64"] = data.base64EncodedString()
        if args["mime-type"] == nil, value != "-" {
            let ext = URL(fileURLWithPath: value).pathExtension.lowercased()
            args["mime-type"] = ["jpg": "image/jpeg", "jpeg": "image/jpeg", "tif": "image/tiff", "tiff": "image/tiff", "pdf": "application/pdf"][ext] ?? "image/png"
        }
    case "text" where value == "-":
        args["text"] = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
    default:
        args[key] = value
    }
    i += 2
}
for p in command.parameters where p.required && args[p.name] == nil { fail("--\(p.name) is required.") }

/// Starts PasteLens and waits for its bridge, if needed.
func ensureRunning() {
    if FileManager.default.fileExists(atPath: Bridge.socketPath), (try? Bridge.call("get-pastebins", args: [:], timeout: 3)) != nil { return }
    let config = NSWorkspace.OpenConfiguration()
    config.activates = false
    let done = DispatchSemaphore(value: 0)
    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Bridge.bundleID) {
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in done.signal() }
        _ = done.wait(timeout: .now() + 10)
    } else {
        fail("PasteLens isn't installed.")
    }
    for _ in 0..<40 {
        if (try? Bridge.call("get-pastebins", args: [:], timeout: 2)) != nil { return }
        Thread.sleep(forTimeInterval: 0.25)
    }
    fail("PasteLens didn't start its bridge in time.")
}

ensureRunning()
do {
    let result = try Bridge.call(command.name, args: args)
    if let output, let dict = result as? [String: Any], let base64 = dict["data"] as? String, let data = Data(base64Encoded: base64) {
        do { try data.write(to: URL(fileURLWithPath: output)) } catch { fail("Can't write \(output): \(error.localizedDescription)") }
        var summary = dict
        summary["data"] = nil
        summary["path"] = output
        printJSON(summary)
    } else {
        printJSON(result)
    }
} catch {
    fail(error.localizedDescription)
}
