import Vapor

/// Middleware + service wiring. The cache-decorated runner and the shared
/// StatsTracker are constructed once and threaded into route registration.
public func configure(_ app: Application) throws {
    app.middleware.use(OriginGuardMiddleware())
    // Serve the dashboard shell + assets. Two resolution modes:
    //  - Bundled (.app, marked by CONTAINER_DASHBOARD_BUNDLED=1): assets live at
    //    Contents/Resources/Public, resolved from Bundle.main so the lookup
    //    survives App Translocation (a quarantined-DMG run lives under a
    //    randomized path, but the bundle relocates as a unit). The obvious
    //    CWD-based path is wrong for every bundle launch dir.
    //  - `swift run` / release binary: <cwd>/Resources/Public (run.sh pins CWD).
    app.middleware.use(
        FileMiddleware(publicDirectory: resolvePublicDirectory(), defaultFile: "index.html")
    )
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

private func resolvePublicDirectory() -> String {
    if ProcessInfo.processInfo.environment["CONTAINER_DASHBOARD_BUNDLED"] == "1" {
        return Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/Public/").path
    }
    var cwd = FileManager.default.currentDirectoryPath
    if !cwd.hasSuffix("/") { cwd += "/" }
    return cwd + "Resources/Public/"
}
