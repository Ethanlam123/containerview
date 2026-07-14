// Container Monitor - native macOS app.
//
// Owns the spawned Vapor server: clean env, port pin, stderr capture, and a
// terminate() that SIGTERMs the server. The server's own parent-process watch
// (app.swift, gated on CONTAINER_DASHBOARD_BUNDLED=1) reaps it on shell exit
// including Force-Quit / kill -9, so no local SIGKILL fallback is needed.
//
// Ported from the former App/Shell/main.swift; the window is now SwiftUI, but
// the server lifecycle is unchanged.

import Foundation
import Darwin

// MARK: - Stderr tail (thread-safe, Sendable)

/// A 2 KB rolling tail of the server's stderr, for the error pane if the server
/// never becomes healthy. `@unchecked Sendable`: all access is serialized through
/// `queue`. Captured by the FileHandle readability handler (a @Sendable closure),
/// so it must not capture ServerProcess itself.
final class StderrTail: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.containermonitor.server.stderr")
    private var text = ""

    func append(_ s: String) {
        queue.sync { text = String((text + s).suffix(2000)) }
    }

    var current: String { queue.sync { text } }
}

// MARK: - Server process

enum ServerError: LocalizedError {
    case notFound
    var errorDescription: String? {
        switch self {
        case .notFound: return "Server binary not found (looked in the app bundle and .build)."
        }
    }
}

/// Owns the spawned Vapor server process. Not Sendable; only accessed from the
/// main actor (via AppModel). The stderr readability handler runs off-main but
/// only touches the Sendable StderrTail.
final class ServerProcess {
    private let process: Process
    private let stderrPipe: Pipe
    private let stderrTail = StderrTail()
    let port: Int

    private init(process: Process, stderrPipe: Pipe, port: Int) {
        self.process = process
        self.stderrPipe = stderrPipe
        self.port = port
    }

    static func start(port: Int) throws -> ServerProcess {
        guard let serverURL = locateServerExecutable() else { throw ServerError.notFound }
        let process = Process()
        process.executableURL = serverURL
        // Always set the dashboard knobs explicitly - do not inherit, so a stale
        // exported value (e.g. CONTAINER_DASHBOARD_PORT) cannot leak into the child.
        var env = ProcessInfo.processInfo.environment
        env["CONTAINER_DASHBOARD_PORT"] = String(port)
        env["CONTAINER_DASHBOARD_BUNDLED"] = "1"
        env.removeValue(forKey: "CONTAINER_DASHBOARD_ALLOW_REMOTE")
        env.removeValue(forKey: "CONTAINERDASHBOARD_DISABLE_EXEC")
        process.environment = env

        let pipe = Pipe()
        process.standardError = pipe
        try process.run()

        let server = ServerProcess(process: process, stderrPipe: pipe, port: port)
        server.captureStderr()
        return server
    }

    var isRunning: Bool { process.isRunning }

    /// Diagnostics for the error pane if the server never becomes healthy.
    var diagnostics: String {
        let exit = process.isRunning ? "" : "\n(exit \(process.terminationStatus))"
        return stderrTail.current + exit
    }

    private func captureStderr() {
        let handle = stderrPipe.fileHandleForReading
        let tail = stderrTail
        // ponytail: readabilityHandler keeps a 2KB tail for the error pane.
        // Fine for diagnostic volume; no need to stream to a file.
        handle.readabilityHandler = { fh in
            let data = fh.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            tail.append(text)
        }
    }

    /// SIGTERM (Vapor shuts down gracefully on it). The server's bundled
    /// parent-watch reaps it if this is never reached (Force-Quit / crash).
    func terminate() {
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        if process.isRunning { process.terminate() }
    }
}

// MARK: - Path helpers

/// Locate the server executable. In a bundled `.app` it sits beside the shell at
/// `Contents/MacOS/ContainerDashboardServer`. When running outside a bundle
/// (`swift run` / a direct `.build` binary for dev), fall back to the SPM
/// build output so the app is testable without assembling the bundle.
private func locateServerExecutable() -> URL? {
    let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/ContainerDashboardServer")
    if FileManager.default.isExecutableFile(atPath: bundled.path) { return bundled }
    for config in ["release", "debug"] {
        let candidate = ".build/\(config)/ContainerDashboard"
        if FileManager.default.isExecutableFile(atPath: candidate) { return URL(fileURLWithPath: candidate) }
    }
    return nil
}

/// `which`: locate an executable on PATH.
func findOnPATH(_ name: String) -> String? {
    let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
    for dir in path.split(separator: ":") {
        let candidate = URL(fileURLWithPath: String(dir)).appendingPathComponent(name)
        if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate.path }
    }
    return nil
}

/// Bind 127.0.0.1:0, read the assigned port, close. There is a tiny TOCTOU
/// window on loopback between close and the server's bind - acceptable for a
/// single-user local tool (the spawn follows milliseconds later). Needs zero
/// server changes; a race-free variant would need server-side port readback.
func findFreeLoopbackPort() -> Int? {
    let s = socket(AF_INET, SOCK_STREAM, 0)
    guard s >= 0 else { return nil }
    defer { close(s) }
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = 0
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    let bound = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
            bind(s, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard bound == 0 else { return nil }
    var actual = sockaddr_in()
    var len = socklen_t(MemoryLayout<sockaddr_in>.size)
    let got = withUnsafeMutablePointer(to: &actual) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
            getsockname(s, sa, &len)
        }
    }
    guard got == 0 else { return nil }
    return Int(UInt16(bigEndian: actual.sin_port))
}
