import Vapor

/// DNS-rebinding / CSRF defense for writes. Loopback binding alone does not stop
/// a hostile webpage (its DNS can resolve to 127.0.0.1, then attacker JS POSTs
/// `/api/containers/<id>/kill`). Browsers send `Origin` and `Sec-Fetch-Site` on
/// cross-origin POSTs, so reject any state-changing request whose `Origin` host
/// is not loopback or whose `Sec-Fetch-Site` is `cross-site`. Non-browser clients
/// (curl, no Origin) are unaffected.
struct OriginGuardMiddleware: AsyncMiddleware {
    func respond(to req: Request, chainingTo next: AsyncResponder) async throws -> Response {
        if Self.shouldBlock(
            method: req.method,
            origin: req.headers.first(name: .origin),
            secFetchSite: req.headers.first(name: HTTPHeaders.Name("Sec-Fetch-Site"))
        ) {
            throw Abort(.forbidden, reason: "cross-origin write blocked")
        }
        return try await next.respond(to: req)
    }

    /// Pure decision - unit-tested without a Vapor runtime.
    static func shouldBlock(method: HTTPMethod, origin: String?, secFetchSite: String?) -> Bool {
        guard method == .POST || method == .DELETE else { return false }
        if let origin, let url = URL(string: origin) {
            let host = url.host ?? ""
            if !LoopbackGuard.isLoopback(host) { return true }
        }
        if secFetchSite == "cross-site" { return true }
        return false
    }

    /// WebSocket upgrade gate. `shouldBlock` only covers POST/DELETE, so a ws
    /// upgrade (GET + Upgrade: websocket) is NOT covered by it. This is the
    /// blocker gate enforced inside Vapor's `shouldUpgrade` (reject = nil). A
    /// browser always sends `Origin` on a ws upgrade; a non-browser client (CLI)
    /// sends none and is allowed. A present Origin must resolve to loopback, and
    /// `Sec-Fetch-Site` must not be `cross-site`. Pure - unit-tested standalone.
    static func shouldBlockWS(origin: String?, secFetchSite: String?) -> Bool {
        if let origin, !origin.isEmpty {
            guard let url = URL(string: origin) else { return true }   // malformed -> block
            let host = url.host ?? ""
            guard !host.isEmpty, LoopbackGuard.isLoopback(host) else { return true }
        }
        if secFetchSite == "cross-site" { return true }
        return false
    }
}
