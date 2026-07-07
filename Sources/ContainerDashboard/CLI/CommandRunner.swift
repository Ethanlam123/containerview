import Foundation
import Darwin
import os

/// Generic shell-out layer: runs `container` and host binaries (e.g. `sw_vers`)
/// via argument arrays (never a shell string). Generic so the same runner backs
/// every CLI call and tests inject a fake.
protocol CommandRunner: Sendable {
    /// One-shot: run to completion (or timeout), return captured stdout bytes.
    func run(binary: String, args: [String], timeout: Duration) async throws -> Data
    /// Streaming: yield stdout lines as they arrive (for `container logs -f`),
    /// with an explicit `cancel` for teardown. The caller MUST invoke `cancel`
    /// when it stops iterating (e.g. on client disconnect) so the child process
    /// is reaped.
    func stream(binary: String, args: [String]) -> LogStream
}

/// A streaming read handle. `lines` is iterated for output; `cancel` stops the
/// backing process. The explicit `cancel` exists because `AsyncThrowingStream`
/// termination-on-consumer-abandonment is not reliable enough to guarantee the
/// `container logs -f` child is killed when an SSE client disconnects.
struct LogStream: Sendable {
    let lines: AsyncThrowingStream<String, Error>
    let cancel: @Sendable () -> Void
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

    func stream(binary: String, args: [String]) -> LogStream {
        // Boxed task reference so the returned `cancel` can reach the producer.
        final class ProducerTaskBox: @unchecked Sendable {
            private let lock = OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)
            func set(_ task: Task<Void, Never>) { lock.withLock { $0 = task } }
            func cancel() { lock.withLock { $0?.cancel() } }
        }
        let box = ProducerTaskBox()
        let lines = AsyncThrowingStream<String, Error> { continuation in
            let task = Task {
                guard let resolved = Self.resolve(binary) else {
                    continuation.finish(throwing: CLIError.missing)
                    return
                }
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: resolved)
                proc.arguments = args
                let stdout = Pipe()
                proc.standardOutput = stdout
                do {
                    try proc.run()
                } catch {
                    continuation.finish(throwing: CLIError.missing)
                    return
                }

                // Interruptible read loop. `availableData` blocks until data or
                // EOF, so it would ignore task cancellation entirely; instead we
                // `poll()` on the stdout fd with a short timeout and re-check
                // `Task.isCancelled` each iteration. This bounds the time
                // between a cancel and reaping the child.
                let fd = stdout.fileHandleForReading.fileDescriptor
                let handle = stdout.fileHandleForReading
                var carry = Data()
                while !Task.isCancelled {
                    var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                    let rc = poll(&pfd, 1, 250)
                    if Task.isCancelled { break }
                    if rc <= 0 { continue } // timeout or interrupted; loop and re-check
                    let chunk = handle.availableData
                    if chunk.isEmpty {
                        if !proc.isRunning { break } // EOF
                        continue
                    }
                    carry.append(chunk)
                    while let nl = carry.firstIndex(of: 0x0A) {
                        let lineData = carry.prefix(upTo: nl)
                        carry.removeSubrange(...nl)
                        if let s = String(data: lineData, encoding: .utf8)?
                            .trimmingCharacters(in: CharacterSet(charactersIn: "\r")) {
                            continuation.yield(s)
                        }
                    }
                }
                if !carry.isEmpty, let s = String(data: carry, encoding: .utf8)?
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\r")) {
                    continuation.yield(s)
                }
                Self.reap(proc)
                continuation.finish()
            }
            box.set(task)
            continuation.onTermination = { _ in box.cancel() }
        }
        return LogStream(lines: lines, cancel: { box.cancel() })
    }

    /// SIGTERM, a 2s grace, then SIGKILL; finally reap. `container logs -f` is
    /// long-running and may not exit on SIGTERM alone. Brief blocking sleep here
    /// is fine - this is teardown, not a hot path.
    private static func reap(_ proc: Process) {
        proc.terminate()
        let deadline = ContinuousClock().now.advanced(by: .seconds(2))
        while proc.isRunning, ContinuousClock().now < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if proc.isRunning { kill(proc.processIdentifier, SIGKILL) }
        proc.waitUntilExit()
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
