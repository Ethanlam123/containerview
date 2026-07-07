import Testing
import Foundation
@testable import ContainerDashboard

/// Dedupe within a poll tick. The fake counts every underlying call so we can
/// prove the cache short-circuits.
private let sampleArgs = ["ls", "--format", "json", "--all"]

@Test func r1_sameKey_withinTTL_deduped() async throws {
    let fake = FakeCommandRunner(bytes: [
        FakeCommandRunner.key("container", sampleArgs): Data("[{}]".utf8)
    ])
    let cache = ResultCache(inner: fake, ttl: .seconds(5))

    let first = try await cache.run(binary: "container", args: sampleArgs, timeout: .seconds(3))
    let second = try await cache.run(binary: "container", args: sampleArgs, timeout: .seconds(3))

    #expect(first == second)
    #expect(fake.calls.count == 1)   // second served from cache
}

@Test func r2_afterTTL_refetched() async throws {
    let fake = FakeCommandRunner(bytes: [
        FakeCommandRunner.key("container", sampleArgs): Data("[{}]".utf8)
    ])
    let cache = ResultCache(inner: fake, ttl: .milliseconds(20))

    _ = try await cache.run(binary: "container", args: sampleArgs, timeout: .seconds(3))
    try await Task.sleep(for: .milliseconds(80))   // past TTL
    _ = try await cache.run(binary: "container", args: sampleArgs, timeout: .seconds(3))

    #expect(fake.calls.count == 2)
}

@Test func r3_differentArgs_bothFetched() async throws {
    let fake = FakeCommandRunner(bytes: [
        FakeCommandRunner.key("container", ["ls"]): Data("[]".utf8),
        FakeCommandRunner.key("container", ["ps"]): Data("[]".utf8),
    ])
    let cache = ResultCache(inner: fake, ttl: .seconds(5))

    _ = try await cache.run(binary: "container", args: ["ls"], timeout: .seconds(3))
    _ = try await cache.run(binary: "container", args: ["ps"], timeout: .seconds(3))

    #expect(fake.calls.count == 2)
}

@Test func r4_differentBinary_sameArgs_bothFetched() async throws {
    let fake = FakeCommandRunner(bytes: [
        FakeCommandRunner.key("container", ["x"]): Data("{}".utf8),
        FakeCommandRunner.key("sw_vers", ["x"]): Data("{}".utf8),
    ])
    let cache = ResultCache(inner: fake, ttl: .seconds(5))

    _ = try await cache.run(binary: "container", args: ["x"], timeout: .seconds(3))
    _ = try await cache.run(binary: "sw_vers", args: ["x"], timeout: .seconds(3))

    #expect(fake.calls.count == 2)   // binary is part of the key
}

@Test func r5_stream_isNeverCached() async throws {
    let fake = FakeCommandRunner(streams: [
        FakeCommandRunner.key("container", ["logs", "-f", "x"]): ["line1", "line2"]
    ])
    let cache = ResultCache(inner: fake, ttl: .seconds(5))

    for _ in 0..<3 {
        let got = try await collect(cache.stream(binary: "container", args: ["logs", "-f", "x"]))
        #expect(got == ["line1", "line2"])
    }
    #expect(fake.calls.count == 3)   // every stream hits the inner runner
}

private func collect(_ s: AsyncThrowingStream<String, Error>) async throws -> [String] {
    var out: [String] = []
    for try await line in s { out.append(line) }
    return out
}
