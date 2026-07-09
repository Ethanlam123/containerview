import Foundation
import Darwin
import os

/// Interactive PTY-backed exec. `output` is the read side (bounded); `send`
/// queues bytes to the child's stdin; `close` idempotently tears down + reaps.
struct ExecStream: Sendable {
    let output: AsyncThrowingStream<Data, Error>
    let send: @Sendable (Data) -> Void
    let close: @Sendable () -> Void
}

/// Spawns a process on a slave PTY. Separate from `CommandRunner` so the fake
/// and the existing test surface are untouched.
protocol PTYRunner: Sendable {
    func exec(binary: String, args: [String], cols: UInt16, rows: UInt16) -> ExecStream
}

/// Production PTY runner. Each `exec` allocates one `ExecSession`.
struct PTYProcessRunner: PTYRunner {
    func exec(binary: String, args: [String], cols: UInt16, rows: UInt16) -> ExecStream {
        let session = ExecSession()
        let output = AsyncThrowingStream<Data, Error>(bufferingPolicy: .bufferingNewest(64)) { c in
            session.start(binary: binary, args: args, cols: cols, rows: rows, continuation: c)
        }
        return ExecStream(
            output: output,
            send: { session.send($0) },
            close: { session.requestClose() }
        )
    }
}

/// One interactive PTY session. A single serial dispatch queue ("exec.io") runs
/// the driver loop and is the SOLE thread that touches the master fd (reads,
/// writes, close) and the `Process` - so the non-Sendable `Process` never
/// crosses a concurrency domain (same discipline as `ProcessCommandRunner.stream`).
///
/// `send`/`close` do NOT hop to the queue (the driver loop blocks it); they
/// mutate locked state (`pendingWrites` / `closed`) that the driver loop
/// observes every iteration (poll timeout 20ms -> write latency <= 20ms, close
/// observed <= 20ms). This realizes the single-owner property without deadlocking
/// writes behind a blocking read loop.
final class ExecSession: @unchecked Sendable {
    private let ioQueue = DispatchQueue(label: "exec.io")
    private let closed = OSAllocatedUnfairLock<Bool>(initialState: false)
    private let started = OSAllocatedUnfairLock<Bool>(initialState: false)
    private let pendingWrites = OSAllocatedUnfairLock<[Data]>(initialState: [])
    private var masterFD: Int32 = -1
    private var proc: Process?
    private var continuation: AsyncThrowingStream<Data, Error>.Continuation!

    /// Kick off the driver loop (idempotent). Runs the loop on the ioQueue.
    func start(binary: String, args: [String], cols: UInt16, rows: UInt16,
               continuation: AsyncThrowingStream<Data, Error>.Continuation) {
        let already = started.withLock { s -> Bool in let was = s; s = true; return was }
        guard !already else { return }
        self.continuation = continuation
        continuation.onTermination = { [weak self] _ in self?.requestClose() }
        ioQueue.async { [weak self] in
            self?.drive(binary: binary, args: args, cols: cols, rows: rows)
        }
    }

    /// The driver loop. Owns the PTY + Process; reads output, drains pending
    /// writes, and tears down when `closed` is set or the child exits (EOF/EIO).
    private func drive(binary: String, args: [String], cols: UInt16, rows: UInt16) {
        guard let resolved = ProcessCommandRunner.resolve(binary) else {
            continuation.finish(throwing: CLIError.missing)
            return
        }
        let opened: (master: Int32, slave: Int32, String)
        do { opened = try PTY.openMaster() }
        catch {
            continuation.finish(throwing: error)
            return
        }
        masterFD = opened.master
        PTY.setWinsize(opened.slave, rows: rows, cols: cols)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: resolved)
        p.arguments = args
        let slave = FileHandle(fileDescriptor: opened.slave, closeOnDealloc: false)
        p.standardInput = slave
        p.standardOutput = slave
        p.standardError = slave
        do {
            try p.run()
        } catch {
            close(opened.master); close(opened.slave)
            continuation.finish(throwing: CLIError.missing)
            return
        }
        // Parent closes the slave now: otherwise the master read never sees EOF
        // when the child exits (the child holds the only remaining copy via 0/1/2).
        close(opened.slave)
        proc = p

        let fd = masterFD
        while !closed.withLock({ $0 }) {
            flushWrites(to: fd)
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let rc = poll(&pfd, 1, 20)
            if closed.withLock({ $0 }) { break }
            if rc > 0 && (pfd.revents & Int16(POLLIN | POLLHUP)) != 0 {
                var buf = [UInt8](repeating: 0, count: 8192)
                let n = buf.withUnsafeMutableBytes { rb in read(fd, rb.baseAddress!, rb.count) }
                if n > 0 {
                    continuation.yield(Data(buf[0..<Int(n)]))
                } else {
                    break  // EOF (0) or -1/EIO: the slave side is gone
                }
            } else if rc > 0 && (pfd.revents & Int16(POLLHUP)) != 0 {
                break
            }
        }
        teardown()
    }

    /// Write all pending input to the master fd. Partial writes loop; any
    /// hard error drops the remainder (the fd is closing or the child died).
    private func flushWrites(to fd: Int32) {
        let writes = pendingWrites.withLock { w -> [Data] in let v = w; w.removeAll(); return v }
        guard !writes.isEmpty else { return }
        var remaining = writes.reduce(into: Data()) { $0.append($1) }
        while !remaining.isEmpty {
            let written = remaining.withUnsafeBytes { rb in write(fd, rb.baseAddress!, rb.count) }
            if written <= 0 {
                if errno == EINTR { continue }
                break
            }
            remaining.removeFirst(written)
        }
    }

    /// Reap the child (SIGTERM -> 2s grace -> SIGKILL), close the master fd,
    /// finish the stream. Runs only on the ioQueue.
    private func teardown() {
        if let p = proc {
            p.terminate()
            let deadline = ContinuousClock().now.advanced(by: .seconds(2))
            while p.isRunning, ContinuousClock().now < deadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            if p.isRunning { kill(p.processIdentifier, SIGKILL) }
            p.waitUntilExit()
        }
        if masterFD >= 0 { close(masterFD); masterFD = -1 }
        continuation.finish()
    }

    /// Queue bytes to the child stdin. Drops input after close. Non-blocking.
    func send(_ data: Data) {
        if closed.withLock({ $0 }) { return }
        pendingWrites.withLock { $0.append(data) }
    }

    /// Idempotent teardown request. Sets the closed flag; the driver loop
    /// observes it (<= 20ms) and reaps + closes the fd. (Renamed so it does not
    /// shadow the global `close(fd)` used in teardown.)
    func requestClose() {
        _ = closed.withLock { c -> Bool in let was = c; c = true; return was }
    }
}
