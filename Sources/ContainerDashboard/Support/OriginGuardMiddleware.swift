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
}
