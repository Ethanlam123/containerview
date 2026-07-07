import Foundation

/// Generic shell-out layer: runs `container` and host binaries (e.g. `sw_vers`)
/// via argument arrays (never a shell string). Generic so the same runner backs
/// every CLI call and tests inject a fake.
protocol CommandRunner: Sendable {
    /// One-shot: run to completion (or timeout), return captured stdout bytes.
    func run(binary: String, args: [String], timeout: Duration) async throws -> Data
    /// Streaming: yield stdout lines as they arrive (for `container logs -f`).
    func stream(binary: String, args: [String]) -> AsyncThrowingStream<String, Error>
}

enum CLIError: Error, Equatable, Sendable {
    case timedOut
    case nonZeroExit(Int)
    case missing          // binary not on PATH / not executable
    case decoding(String) // CLI output failed to decode into a typed model
}

/// Production runner backed by `Foundation.Process`.
///
/// Swift 6 note: `Process` is not `Sendable`. `run` keeps the `Process` as a
/// function-local used linearly across awaits (permitted by region-based
/// isolation); `stream` constructs the `Process` *inside* the read-loop `Task`
/// so it never crosses a concurrency domain. No stored `Process` state.
struct ProcessCommandRunner: CommandRunner {
    func run(binary: String, args: [String], timeout: Duration) async throws -> Data {
        guard let resolved = Self.resolve(binary) else { throw CLIError.missing }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: resolved)
        proc.arguments = args
        let stdout = Pipe()
        let stderr = Pipe()
        proc.standardOutput = stdout
        proc.standardError = stderr
        do {
            try proc.run()
        } catch {
            throw CLIError.missing
        }
        let deadline = ContinuousClock().now.advanced(by: timeout)
        while proc.isRunning {
            if ContinuousClock().now >= deadline {
                proc.terminate()
                proc.waitUntilExit()
                throw CLIError.timedOut
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        proc.waitUntilExit()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        if proc.terminationStatus != 0 {
            throw CLIError.nonZeroExit(Int(proc.terminationStatus))
        }
        return data
    }

    func stream(binary: String, args: [String]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                guard let resolved = Self.resolve(binary) else {
                    throw CLIError.missing
                }
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: resolved)
                proc.arguments = args
                let stdout = Pipe()
                proc.standardOutput = stdout
                try proc.run()

                // Read availableData in a loop; availableData returns empty
                // only at EOF, so empty + notRunning means done.
                let handle = stdout.fileHandleForReading
                var buffer = Data()
                while !Task.isCancelled {
                    let chunk = handle.availableData
                    if chunk.isEmpty {
                        if !proc.isRunning { break }
                        try await Task.sleep(for: .milliseconds(50))
                        continue
                    }
                    buffer.append(chunk)
                    while let nl = buffer.firstIndex(of: 0x0A) {
                        let lineData = buffer.prefix(upTo: nl)
                        buffer.removeSubrange(...nl)
                        if let s = String(data: lineData, encoding: .utf8)?.trimmingCharacters(in: CharacterSet(charactersIn: "\r")) {
                            continuation.yield(s)
                        }
                    }
                }
                if !buffer.isEmpty, let s = String(data: buffer, encoding: .utf8) {
                    continuation.yield(s.trimmingCharacters(in: CharacterSet(charactersIn: "\r")))
                }
                proc.terminate()
                proc.waitUntilExit()
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Resolve a binary name through `$PATH`; absolute/relative paths pass through.
    private static func resolve(_ binary: String) -> String? {
        if binary.contains("/") { return binary }
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for dir in path.split(separator: ":") {
            let candidate = "\(dir)/\(binary)"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }
}
