import Testing
import Foundation
@testable import ContainerDashboard

/// Phase 14: `container image pull` runs uncached (side-effecting, not deduped)
/// via the output-discarding path (progress would overflow a pipe buffer and
/// hang the capturing `run()`).

private let k = FakeCommandRunner.key

@Test(arguments: ["alpine", "alpine:3.22"])
func imagePull_argv_shape(_ ref: String) async throws {
    let fake = FakeCommandRunner(bytes: [k("container", ["image", "pull", ref]): Data("ok".utf8)])
    try await ContainerCLI.imagePull(fake, ref: ref)
    #expect(fake.discardingCalls.count == 1)
    let call = fake.discardingCalls[0]
    #expect(call.binary == "container")
    // The whole ref travels as one argv element (ImageRefValidator allows `:`/`.`).
    #expect(call.args == ["image", "pull", ref])
    #expect(fake.calls.isEmpty)   // did NOT go through the capturing run() path
}

@Test func imagePull_error_is_not_cached() async throws {
    // A failing pull must not be remembered as "done": both calls reach the inner
    // runner. ResultCache only ever stores successes, so an erroring call is never
    // short-circuited - assert the inner runner is spawned twice.
    let pullKey = k("container", ["image", "pull", "alpine"])
    let inner = FakeCommandRunner(
        bytes: [pullKey: Data("ok".utf8)],
        errors: [pullKey: .nonZeroExit(1)]
    )
    let cached = ResultCache(inner: inner, ttl: .seconds(10))
    _ = try? await cached.runDiscardingOutput(binary: "container", args: ["image", "pull", "alpine"], timeout: .seconds(3))
    _ = try? await cached.runDiscardingOutput(binary: "container", args: ["image", "pull", "alpine"], timeout: .seconds(3))
    #expect(inner.discardingCalls.count == 2)   // bypassed the dedupe map; error not cached
}
