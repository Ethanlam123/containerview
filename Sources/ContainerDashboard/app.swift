import Vapor
import Darwin
import Dispatch

// Held at file scope so ARC retains the dispatch source for the whole process
// lifetime. A local declared inside main()'s `if` block is released at the end
// of that block, which cancels the source - and the parent-exit reap would
// never fire.
nonisolated(unsafe) private var parentWatch: (any DispatchSourceProcess)?

@main
struct App {
    static func main() async throws {
        // Parent-process watch (desktop-app mode only). When the launching
        // shell exits - including Force-Quit / kill -9, which skip Vapor's
        // graceful shutdown - the kernel delivers EXIT and we reap ourselves,
        // so no server lingers as an orphan. Gated to the bundled app so the
        // CLI (`swift run` / release binary) keeps its old semantics: `nohup`,
        // `disown`, and supervisors that re-exec are not surprised by a reap,
        // and there is no PID-recycle footgun. See docs/desktop-app-plan.md
        // Phase 2.5.
        if ProcessInfo.processInfo.environment["CONTAINER_DASHBOARD_BUNDLED"] == "1" {
            let watch = DispatchSource.makeProcessSource(
                identifier: getppid(), eventMask: .exit, queue: .global()
            )
            watch.setEventHandler { exit(EXIT_SUCCESS) }
            watch.activate()
            parentWatch = watch
        }

        var env = try Environment.detect()
        try LoggingSystem.bootstrap(from: &env)
        let app = try await Application.make(env)

        // Remote bind is opt-in via env var (a CLI flag would clash with Vapor's
        // ArgumentParser). Default is loopback only. No auth is enabled in either
        // mode - the loopback default is the security boundary.
        let allowRemote = ProcessInfo.processInfo.environment["CONTAINER_DASHBOARD_ALLOW_REMOTE"] == "1"
        let hostname = allowRemote ? "0.0.0.0" : "127.0.0.1"
        try LoopbackGuard.validate(hostname: hostname, allowRemote: allowRemote)
        app.http.server.configuration.hostname = hostname
        // 8080 is the documented default but is heavily contested on macOS
        // (TencentMeeting, dev servers). Allow an override so the app is runnable
        // without editing source; the README documents the default.
        app.http.server.configuration.port = ProcessInfo.processInfo.environment["CONTAINER_DASHBOARD_PORT"].flatMap(Int.init) ?? 8080

        try configure(app)
        try await app.execute()
        try await app.asyncShutdown()
    }
}
