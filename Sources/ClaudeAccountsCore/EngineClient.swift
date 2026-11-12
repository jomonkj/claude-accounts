import Foundation

public struct EngineResult: Equatable, Sendable {
    public let ok: Bool
    /// stdout on success; the error message (without "ERROR: ") on failure.
    public let output: String

    /// The output parsed as a JSON object, or an empty dictionary.
    public var json: [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(output.utf8))) as? [String: Any] ?? [:]
    }
}

/// Runs the engine (`claude-switch`) as a separate process. The path is injected, so tests use a fake engine.
public struct EngineClient: Sendable {
    public let path: String

    public init(path: String) { self.path = path }

    /// The engine bundled in the app, else the one in ~/.local/bin.
    public static func bundled() -> EngineClient {
        EngineClient(path: Bundle.main.path(forResource: "claude-switch", ofType: nil)
            ?? (NSHomeDirectory() + "/.local/bin/claude-switch"))
    }

    /// `input` goes to the engine's stdin, never into its arguments (used for the Keychain password).
    public func run(_ args: [String], input: String? = nil) async -> EngineResult {
        let path = self.path
        return await Task.detached { EngineClient.runSync(path, args, input: input) }.value
    }

    public func status() async throws -> Status {
        let r = await run(["status"])
        guard r.ok else { throw EngineError(message: r.output) }
        return try JSONDecoder().decode(Status.self, from: Data(r.output.utf8))
    }

    static func runSync(_ path: String, _ args: [String], input: String? = nil) -> EngineResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        p.environment = env
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        let stdin = input.map { _ in Pipe() }
        if let stdin { p.standardInput = stdin }
        do { try p.run() } catch { return EngineResult(ok: false, output: error.localizedDescription) }
        if let stdin, let input {
            stdin.fileHandleForWriting.write(Data(input.utf8))
            try? stdin.fileHandleForWriting.close()
        }
        let o = out.fileHandleForReading.readDataToEndOfFile()
        let e = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let stdout = String(decoding: o, as: UTF8.self)
        if p.terminationStatus == 0 { return EngineResult(ok: true, output: stdout) }
        let msg = String(decoding: e, as: UTF8.self).isEmpty ? stdout : String(decoding: e, as: UTF8.self)
        return EngineResult(ok: false, output: msg.replacingOccurrences(of: "ERROR: ", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

public struct EngineError: Error, Equatable {
    public let message: String
}
