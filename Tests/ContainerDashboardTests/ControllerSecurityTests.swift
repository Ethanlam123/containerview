import Testing
import Vapor
@testable import ContainerDashboard

/// Security boundary tests. The validators (ID/ImageRef/PruneCategory) are
/// covered in ValidatorTests; route wiring (validator => 400) is verified by
/// running the server (Phase 7 manual gate). Here we cover the loopback guard
/// and the DNS-rebinding write-defense decision (pure functions - no Vapor
/// runtime, which is what makes them reliable under swift-testing).

// MARK: - OriginGuardMiddleware.shouldBlock

@Test func crossOriginWrite_blocked() {
    #expect(OriginGuardMiddleware.shouldBlock(method: .POST, origin: "http://evil.com", secFetchSite: nil))
}

@Test func crossSiteFetch_blocked() {
    #expect(OriginGuardMiddleware.shouldBlock(method: .POST, origin: nil, secFetchSite: "cross-site"))
}

@Test func sameOriginWrite_allowed() {
    #expect(!OriginGuardMiddleware.shouldBlock(method: .POST, origin: "http://127.0.0.1:8080", secFetchSite: "same-origin"))
    #expect(!OriginGuardMiddleware.shouldBlock(method: .POST, origin: "http://localhost:8080", secFetchSite: nil))
}

@Test func browserlessNoOrigin_allowed() {
    #expect(!OriginGuardMiddleware.shouldBlock(method: .POST, origin: nil, secFetchSite: nil))
}

@Test func getNeverBlocked() {
    #expect(!OriginGuardMiddleware.shouldBlock(method: .GET, origin: "http://evil.com", secFetchSite: "cross-site"))
}

@Test func deleteCrossOrigin_blocked() {
    #expect(OriginGuardMiddleware.shouldBlock(method: .DELETE, origin: "http://evil.com", secFetchSite: nil))
}

// MARK: - LoopbackGuard

@Test func loopbackGuard_rejectsNonLoopback_withoutAllowRemote() {
    #expect(throws: LoopbackGuard.Failure.self) {
        try LoopbackGuard.validate(hostname: "0.0.0.0", allowRemote: false)
    }
}

@Test func loopbackGuard_acceptsLoopback() throws {
    try LoopbackGuard.validate(hostname: "127.0.0.1", allowRemote: false)
    try LoopbackGuard.validate(hostname: "localhost", allowRemote: false)
}

@Test func loopbackGuard_allowRemote_skipsCheck() throws {
    try LoopbackGuard.validate(hostname: "0.0.0.0", allowRemote: true)
}

@Test func loopbackGuard_isLoopback_cases() {
    #expect(LoopbackGuard.isLoopback("127.0.0.1"))
    #expect(LoopbackGuard.isLoopback("127.1.2.3"))
    #expect(LoopbackGuard.isLoopback("::1"))
    #expect(!LoopbackGuard.isLoopback("0.0.0.0"))
    #expect(!LoopbackGuard.isLoopback("192.168.1.1"))
}
