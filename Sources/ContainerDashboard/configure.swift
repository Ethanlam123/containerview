import Vapor

/// Middleware + service wiring. The cache-decorated runner and the shared
/// StatsTracker are constructed once and threaded into route registration.
public func configure(_ app: Application) throws {
    app.middleware.use(OriginGuardMiddleware())
    // Serve the dashboard shell + assets. Vapor's DirectoryConfiguration.detect
    // points at `<cwd>/Public/`, but the spec lays assets under
    // `Resources/Public/`, so resolve that explicitly against CWD. CWD is the
    // project root under `swift run`; Phase 12 run.sh pins it for releases.
    var cwd = FileManager.default.currentDirectoryPath
    if !cwd.hasSuffix("/") { cwd += "/" }
    app.middleware.use(FileMiddleware(publicDirectory: cwd + "Resources/Public/", defaultFile: "index.html"))
    let runner: any CommandRunner = ResultCache(inner: ProcessCommandRunner())
    let tracker = StatsTracker()
    // Exec (interactive terminal) is ON by default; opt out with
    // CONTAINERDASHBOARD_DISABLE_EXEC=1 for shared/multi-user hosts where an
    // arbitrary shell route should not be live. run + exec can mount and
    // read/write arbitrary host paths - the capability stays loopback-only and
    // is guarded by the Origin/Sec-Fetch-Site posture either way.
    let execEnabled = ProcessInfo.processInfo.environment["CONTAINERDASHBOARD_DISABLE_EXEC"] != "1"
    registerRoutes(app, runner: runner, tracker: tracker, execEnabled: execEnabled)
}
