import Vapor
import Darwin
import Dispatch

@main
struct App {
    static func main() async throws {
        // Parent-process watch (desktop-app mode). When the launching shell
        // exits - including Force-Quit / kill -9, which skip Vapor's graceful
        // shutdown - the kernel delivers EXIT and we reap ourselves, so no
        // server lingers as an orphan. No-op for `swift run` / direct CLI use:
        // the foreground parent stays alive while the server runs, so the
        // source never fires. This removes the main argument for running the
        // server in-process (see docs/desktop-app-plan.md Phase 2.5 / 6).
        let parentWatch = DispatchSource.makeProcessSource(
            identifier: getppid(), eventMask: .exit, queue: .global()
        )
        parentWatch.setEventHandler { exit(EXIT_SUCCESS) }
        parentWatch.activate()

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
