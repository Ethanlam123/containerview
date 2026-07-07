import Vapor

/// Route + middleware registration. Fills out across phases.
public func configure(_ app: Application) throws {
    try routes(app)
}

/// Smoke route replaced by static-file serving in Phase 7/9.
public func routes(_ app: Application) throws {
    app.get { _ in
        "Container Dashboard - scaffold OK"
    }
}
