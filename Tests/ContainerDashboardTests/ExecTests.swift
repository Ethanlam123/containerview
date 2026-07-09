import Testing
import Foundation
import os
@testable import ContainerDashboard

/// Phase 15 core: PTY open/close, concurrent distinct slave paths, the exec
/// pool cap, the ws-Origin blocker gate, and a PTY round-trip + reap against
/// /bin/sh (no container needed).

// MARK: - PTY

@Test func pty_open_returns_two_fds() throws {
    let opened = try PTY.openMaster()
    #expect(opened.master >= 0)
    #expect(opened.slave >= 0)
    #expect(!opened.slavePath.isEmpty)
    close(opened.master)
    close(opened.slave)
}

@Test func pty_concurrent_opens_distinct_paths() async throws {
    // ptsname_r is thread-safe; ptsname is not. Open many PTYs concurrently and
    // keep them all open: simultaneously-open sessions must get distinct slave
    // paths (a ptsname race would hand several callers one shared static buffer).
    let lock = OSAllocatedUnfairLock<[(String, Int32, Int32)]>(initialState: [])
    await withTaskGroup(of: Void.self) { group in
        for _ in 0..<8 {
            group.addTask {
                if let opened = try? PTY.openMaster() {
                    lock.withLock { $0.append((opened.slavePath, opened.master, opened.slave)) }
                }
            }
        }
    }
    let opened = lock.withLock { $0 }
    #expect(opened.count == 8)
    let paths = opened.map(\.0)
    #expect(paths.count == Set(paths).count)   // all distinct while open
    for (_, m, s) in opened { close(m); close(s) }
}

// MARK: - ExecPool

@Test func exec_pool_caps_at_capacity() async throws {
    let pool = ExecPool(capacity: 8)
    for _ in 0..<8 { try await pool.acquire() }
    do { try await pool.acquire(); Issue.record("expected pool to be full") } catch ExecPoolError.full {}
    await pool.release()
    try await pool.acquire()   // a freed slot is reusable
    do { try await pool.acquire(); Issue.record("expected pool to be full") } catch ExecPoolError.full {}
}

// MARK: - ws Origin guard

@Test func ws_origin_guard_blocks_cross_origin() {
    #expect(OriginGuardMiddleware.shouldBlockWS(origin: "https://evil.tld", secFetchSite: nil))
    #expect(OriginGuardMiddleware.shouldBlockWS(origin: "http://10.0.0.5:8080", secFetchSite: nil))
    #expect(OriginGuardMiddleware.shouldBlockWS(origin: "http://127.0.0.1:8080", secFetchSite: "cross-site"))
    #expect(OriginGuardMiddleware.shouldBlockWS(origin: "garbage", secFetchSite: nil))   // malformed
}

@Test func ws_origin_guard_allows_loopback_and_non_browser() {
    #expect(!OriginGuardMiddleware.shouldBlockWS(origin: nil, secFetchSite: nil))            // CLI
    #expect(!OriginGuardMiddleware.shouldBlockWS(origin: "http://127.0.0.1:8080", secFetchSite: "same-origin"))
    #expect(!OriginGuardMiddleware.shouldBlockWS(origin: "http://localhost:8080", secFetchSite: "same-site"))
}

// MARK: - PTY round-trip + reap

@Test func exec_roundtrip_then_reap() async throws {
    let runner = PTYProcessRunner()
    let stream = runner.exec(binary: "/bin/sh", args: [], cols: 80, rows: 24)

    // Collect output as it arrives.
    let collected = OSAllocatedUnfairLock<String>(initialState: "")
    let pumpTask = Task {
        for try await chunk in stream.output {
            collected.withLock { c in
                if let s = String(data: chunk, encoding: .utf8) { c.append(s) }
            }
        }
    }

    try await Task.sleep(for: .milliseconds(300))   // let the shell boot
    stream.send(Data("echo hi\n".utf8))

    var saw = false
    for _ in 0..<50 {   // up to ~5s
        if collected.withLock({ $0.contains("hi") }) { saw = true; break }
        try await Task.sleep(for: .milliseconds(100))
    }
    #expect(saw, "echo hi output should arrive on the PTY")

    // close() -> driver observes (<= 20ms) -> SIGTERM/grace/SIGKILL -> finish().
    // The pump ending within ~3s proves the child was reaped, not orphaned.
    stream.close()
    let done = OSAllocatedUnfairLock<Bool>(initialState: false)
    let race = Task { _ = try? await pumpTask.value; done.withLock { $0 = true } }
    for _ in 0..<30 {
        if done.withLock({ $0 }) { break }
        try await Task.sleep(for: .milliseconds(100))
    }
    race.cancel()
    let isDone = done.withLock({ $0 })
    #expect(isDone, "close() must reap the child and finish the stream within ~3s")
}
