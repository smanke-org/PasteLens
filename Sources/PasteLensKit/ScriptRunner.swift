import Foundation
import JavaScriptCore

/// Runs the script steps of a filter: shell scripts through a child process, JavaScript
/// in JavaScriptCore.
public enum ScriptRunner {
    public static var timeout: TimeInterval = 20

    /// Runs `script` with the text on standard input. A script that starts with #! picks its
    /// own interpreter; anything else runs with /bin/zsh.
    public static func shell(_ script: String, input: String) async throws -> String {
        guard !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw FilterError("The script is empty.") }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("pastelens-\(UUID().uuidString)")
        let body = script.hasPrefix("#!") ? script : "#!/bin/zsh\n" + script
        try body.write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        defer { try? FileManager.default.removeItem(at: file) }
        return try await run(executable: file, arguments: [], input: input)
    }

    /// Runs an executable with the text on standard input and returns standard output.
    public static func run(executable: URL, arguments: [String], input: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
            environment["LANG"] = environment["LANG"] ?? "en_US.UTF-8"
            process.environment = environment
            let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
            process.standardInput = stdin
            process.standardOutput = stdout
            process.standardError = stderr
            let output = DataBox(), errors = DataBox()
            stdout.fileHandleForReading.readabilityHandler = { output.append($0.availableData) }
            stderr.fileHandleForReading.readabilityHandler = { errors.append($0.availableData) }
            let timer = DispatchWorkItem { if process.isRunning { process.terminate() } }
            process.terminationHandler = { p in
                timer.cancel()
                stdout.fileHandleForReading.readabilityHandler = nil
                stderr.fileHandleForReading.readabilityHandler = nil
                output.append(stdout.fileHandleForReading.readDataToEndOfFile())
                errors.append(stderr.fileHandleForReading.readDataToEndOfFile())
                if p.terminationReason == .uncaughtSignal {
                    continuation.resume(throwing: FilterError("The script was stopped after \(Int(timeout)) seconds."))
                } else if p.terminationStatus != 0 {
                    let message = String(decoding: errors.data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                    continuation.resume(throwing: FilterError(message.isEmpty ? "The script exited with status \(p.terminationStatus)." : message))
                } else {
                    continuation.resume(returning: String(decoding: output.data, as: UTF8.self))
                }
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: FilterError("Couldn't run the script: \(error.localizedDescription)"))
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
            DispatchQueue.global().async {
                stdin.fileHandleForWriting.write(Data(input.utf8))
                try? stdin.fileHandleForWriting.close()
            }
        }
    }

    /// Runs JavaScript with the input in `text`. The body can `return` a value; without one,
    /// the value of the last expression is used.
    public static func javascript(_ source: String, input: String) throws -> String {
        guard let context = JSContext() else { throw FilterError("JavaScript isn't available.") }
        var thrown: String?
        context.exceptionHandler = { _, exception in thrown = exception?.toString() }
        context.setObject(input, forKeyedSubscript: "text" as NSString)
        let usesReturn = source.range(of: #"(^|[^\w.])return\b"#, options: .regularExpression) != nil
        let wrapped = usesReturn ? "(function(text){\n\(source)\n})(text)" : source
        let value = context.evaluateScript(wrapped)
        if let thrown { throw FilterError(thrown) }
        guard let value, !value.isUndefined, !value.isNull else { return "" }
        // Arrays and objects come back as JSON rather than "[object Object]".
        if value.isObject, !value.isString,
           let json = context.objectForKeyedSubscript("JSON")?.invokeMethod("stringify", withArguments: [value, NSNull(), 2]),
           json.isString {
            return json.toString()
        }
        return value.toString()
    }
}

/// Collects pipe output from handler threads.
private final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()
    func append(_ data: Data) { lock.lock(); storage.append(data); lock.unlock() }
    var data: Data { lock.lock(); defer { lock.unlock() }; return storage }
}
