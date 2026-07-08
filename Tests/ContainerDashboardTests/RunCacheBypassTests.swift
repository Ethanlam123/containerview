import Testing
import Foundation
@testable import ContainerDashboard

/// Writes must bypass `ResultCache` so a repeated (e.g. double-clicked)
/// side-effecting call is not short-circuited into a cached no-op. This was a
/// latent bug in the shipped writes (stop/start/kill/prune/builder), surfaced by
/// the phase-13 review (architect C1). Reads keep the cache.

private let k = FakeCommandRunner.key

@Test func runUncached_bypasses_dedupe_map() async throws {
    let inner = FakeCommandRunner(bytes: [k("container", ["stop", "x"]): Data("ok".utf8)])
    let cached = ResultCache(inner: inner, ttl: .seconds(10))
    _ = try await cached.runUncached(binary: "container", args: ["stop", "x"], timeout: .seconds(3))
    _ = try await cached.runUncached(binary: "container", args: ["stop", "x"], timeout: .seconds(3))
    #expect(inner.calls.count == 2)   // not deduped
}

@Test func run_remains_deduped_for_reads() async throws {
    let inner = FakeCommandRunner(bytes: [k("container", ["ls"]): Data("[]".utf8)])
    let cached = ResultCache(inner: inner, ttl: .seconds(10))
    _ = try await cached.run(binary: "container", args: ["ls"], timeout: .seconds(3))
    _ = try await cached.run(binary: "container", args: ["ls"], timeout: .seconds(3))
    #expect(inner.calls.count == 1)   // deduped
}

@Test(arguments: ["stop", "start", "kill"])
func lifecycle_writes_bypass_cache(_ verb: String) async throws {
    let inner = FakeCommandRunner(bytes: [k("container", [verb, "x"]): Data("ok".utf8)])
    let cached = ResultCache(inner: inner, ttl: .seconds(10))
    for _ in 0..<2 {
        switch verb {
        case "stop": try await ContainerCLI.stop(cached, id: "x")
        case "start": try await ContainerCLI.start(cached, id: "x")
        default: try await ContainerCLI.kill(cached, id: "x")
        }
    }
    #expect(inner.calls.count == 2)   // the retrofit works through the cache
}

@Test func prune_bypasses_cache() async throws {
    let inner = FakeCommandRunner(bytes: [k("container", ["prune"]): Data("ok".utf8)])
    let cached = ResultCache(inner: inner, ttl: .seconds(10))
    try await ContainerCLI.prune(cached, category: .containers)
    try await ContainerCLI.prune(cached, category: .containers)
    #expect(inner.calls.count == 2)
}
