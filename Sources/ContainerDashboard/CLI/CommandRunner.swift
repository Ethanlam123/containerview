import Foundation
import Darwin
import os

/// Generic shell-out layer: runs `container` and host binaries (e.g. `sw_vers`)
/// via argument arrays (never a shell string). Generic so the same runner backs
/// every CLI call and tests inject a fake.
protocol CommandRunner: Sendable {
    /// One-shot: run to completion (or timeout), return captured stdout bytes.
    /// Reads use this (the cache-decorated runner dedupes within a short TTL).
    func run(binary: String, args: [String], timeout: Duration) async throws -> Data
    /// One-shot, bypassing any dedupe/cache layer. Side-effecting commands
    /// (`run`, `stop`, `start`, `kill`, `prune`, builder start/stop, `pull`) MUST
    /// use this so a repeated call within the cache TTL is not short-circuited
    /// into a cached no-op (a latent double-click dedupe bug fixed in phase 13).
    func runUncached(binary: String, args: [String], timeout: Duration) async throws -> Data
    /// One-shot, side-effecting, output discarded to `/dev/null`. For commands
    /// whose progress would overflow a `Pipe` buffer (~64 KB) and block the child
    /// on `write()` - `container image pull` does this, which would hold
    /// `isRunning` true until our timeout SIGKILLs a pull that actually finished.
    /// Never deduped (side-effecting) and returns no bytes by design.
    func runDiscardingOutput(binary: String, args: [String], timeout: Duration) async throws
    /// Streaming: yield stdout lines as they arrive (for `container logs -f`),
    /// with an explicit `cancel` for teardown. The caller MUST invoke `cancel`
    /// when it stops iterating (e.g. on client disconnect) so the child process
    /// is reaped.
    func stream(binary: String, args: [String]) -> LogStream
}

extension CommandRunner {
    /// Default: no caching layer below this runner, so uncached == cached.
    /// `ResultCache` overrides to delegate past its map.
    func runUncached(binary: String, args: [String], timeout: Duration) async throws -> Data {
        try await run(binary: binary, args: args, timeout: timeout)
    }

    /// Default: run uncached and drop the bytes. `ProcessCommandRunner` overrides
    /// to sink to `/dev/null` (the whole point - avoid the pipe-buffer hang).
    func runDiscardingOutput(binary: String, args: [String], timeout: Duration) async throws {
        _ = try await runUncached(binary: binary, args: args, timeout: timeout)
    }
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
/// Swift 6 note: `Process` is not `Sendable`. Both `run` and `stream` construct
/// and drive the `Process` entirely inside a `DispatchQueue.global().async`
/// closure (bridged to async via a continuation / `AsyncThrowingStream`), so the
/// non-Sendable `Process` is created, used, and torn down on one GCD thread and
/// never crosses a concurrency domain. No stored `Process` state. Keeping the
/// blocking lifecycle off Swift's cooperative thread pool is what lets the
/// server keep accepting requests under concurrent CLI load.
struct ProcessCommandRunner: CommandRunner {
    func run(binary: String, args: [String], timeout: Duration) async throws -> Data {
        guard let resolved = Self.resolve(binary) else { throw CLIError.missing }
        // Run the blocking Process lifecycle on a GCD thread, not the
        // cooperative pool. `waitUntilExit` / `readDataToEndOfFile` / the poll
        // are blocking; on the cooperative pool they parked every thread under
        // the /api/state fan-out when the container daemon was contended (a
        // thread sample showed all pool threads stacked in
        // -[NSConcreteTask waitUntilExit], and the server stopped accepting).
        // GCD is built for blocking work; the continuation resumes the async
        // caller without holding a cooperative thread.
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
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
                    cont.resume(throwing: CLIError.missing)
                    return
                }
                let deadline = ContinuousClock().now.advanced(by: timeout)
                while proc.isRunning, ContinuousClock().now < deadline {
                    Thread.sleep(forTimeInterval: 0.02)
                }
                if proc.isRunning {
                    // SIGKILL (unignorable) so waitUntilExit can't hang on a
                    // child that stonewalls SIGTERM - that hang was the wedge.
                    kill(proc.processIdentifier, SIGKILL)
                    proc.waitUntilExit()
                    cont.resume(throwing: CLIError.timedOut)
                    return
                }
                proc.waitUntilExit()
                let data = stdout.fileHandleForReading.readDataToEndOfFile()
                if proc.terminationStatus != 0 {
                    cont.resume(throwing: CLIError.nonZeroExit(Int(proc.terminationStatus)))
                } else {
                    cont.resume(returning: data)
                }
            }
        }
    }

    func runDiscardingOutput(binary: String, args: [String], timeout: Duration) async throws {
        guard let resolved = Self.resolve(binary) else { throw CLIError.missing }
        // Same blocking lifecycle as `run()` (GCD, not the cooperative pool) but
        // stdout/stderr sink to `/dev/null` instead of a `Pipe`. A `Pipe` would
        // fill its ~64 KB buffer on `container image pull`'s progress and block
        // the child on `write()`, holding `isRunning` true until our timeout
        // SIGKILLed a pull that had actually finished. `/dev/null` never blocks.
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: resolved)
                proc.arguments = args
                let devnull = open("/dev/null", O_WRONLY)
                if devnull >= 0 {
                    // Two handles over one fd; closeOnDealloc false so we own the
                    // single close below.
                    proc.standardOutput = FileHandle(fileDescriptor: devnull, closeOnDealloc: false)
                    proc.standardError = FileHandle(fileDescriptor: devnull, closeOnDealloc: false)
                }
                do {
                    try proc.run()
                } catch {
                    if devnull >= 0 { close(devnull) }
                    cont.resume(throwing: CLIError.missing)
                    return
                }
                let deadline = ContinuousClock().now.advanced(by: timeout)
                while proc.isRunning, ContinuousClock().now < deadline {
                    Thread.sleep(forTimeInterval: 0.02)
                }
                if proc.isRunning {
                    kill(proc.processIdentifier, SIGKILL)
                    proc.waitUntilExit()
                    if devnull >= 0 { close(devnull) }
                    cont.resume(throwing: CLIError.timedOut)
                    return
                }
                proc.waitUntilExit()
                if devnull >= 0 { close(devnull) }
                if proc.terminationStatus != 0 {
                    cont.resume(throwing: CLIError.nonZeroExit(Int(proc.terminationStatus)))
                } else {
                    cont.resume(returning: ())
                }
            }
        }
    }

    func stream(binary: String, args: [String]) -> LogStream {
        // Cancellation flag: the read loop below runs on a GCD thread (not a
        // Task), so there is no Task to cancel; this bridges `cancel()` /
        // `onTermination` into the loop.
        let cancelled = OSAllocatedUnfairLock<Bool>(initialState: false)
        let lines = AsyncThrowingStream<String, Error> { continuation in
            // Run the blocking read loop on a background dispatch queue, NOT a
            // cooperative-pool Task. `poll()` and `reap()` are blocking; on the
            // cooperative pool they starved HTTP/SSE handling under concurrent
            // streams (server stopped accepting connections, SSE task groups
            // never tore down, `container logs -f` children orphaned). GCD is
            // built for blocking work, and the cooperative tasks awaiting the
            // next yielded line suspend - holding no thread - so the pool that
            // serves HTTP stays free. Do not move this back onto a Task.
            DispatchQueue.global(qos: .userInitiated).async {
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
                // EOF, so it would never observe `cancel()`; instead `poll()`
                // gates each read with a short timeout and we re-check the
                // cancellation flag every iteration. This bounds the time
                // between a cancel and reaping the child to ~250ms.
                let fd = stdout.fileHandleForReading.fileDescriptor
                let handle = stdout.fileHandleForReading
                var carry = Data()
                while !(cancelled.withLock({ $0 })) {
                    var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                    let rc = poll(&pfd, 1, 250)
                    if cancelled.withLock({ $0 }) { break }
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
            continuation.onTermination = { _ in cancelled.withLock { $0 = true } }
        }
        return LogStream(lines: lines, cancel: { cancelled.withLock { $0 = true } })
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
