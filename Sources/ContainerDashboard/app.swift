import Vapor

@main
struct App {
    static func main() async throws {
        var env = try Environment.detect()
        try LoggingSystem.bootstrap(from: &env)
        let app = try await Application.make(env)

        // Loopback only. External bind requires --allow-remote (Phase 7).
        app.http.server.configuration.hostname = "127.0.0.1"
        app.http.server.configuration.port = 8080

        try configure(app)
        try await app.execute()
        try await app.asyncShutdown()
    }
}
