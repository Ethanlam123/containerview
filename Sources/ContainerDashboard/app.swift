import Vapor

@main
struct App {
    static func main() async throws {
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
        app.http.server.configuration.port = 8080

        try configure(app)
        try await app.execute()
        try await app.asyncShutdown()
    }
}
