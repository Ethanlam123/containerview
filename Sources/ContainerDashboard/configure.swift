import Vapor

/// Middleware + service wiring. The cache-decorated runner and the shared
/// StatsTracker are constructed once and threaded into route registration.
public func configure(_ app: Application) throws {
    app.middleware.use(OriginGuardMiddleware())
    // FileMiddleware (static assets) is added in Phase 9 once Resources/Public exists.
    let runner: any CommandRunner = ResultCache(inner: ProcessCommandRunner())
    let tracker = StatsTracker()
    registerRoutes(app, runner: runner, tracker: tracker)
}
