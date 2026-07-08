import Foundation
import os

/// `CommandRunner` decorator that dedupes concurrent one-shot `run` calls within
/// a short TTL (~1s) keyed by `(binary, args)`. This collapses a single poll
/// tick's repeated reads (e.g. `/api/state` + lazy endpoints) into one CLI spawn.
///
/// Streaming calls (`stream`) bypass the cache entirely - logs must tail live.
/// The rest of the app talks to this as a plain `CommandRunner`, so dedupe is
/// transparent to `StateService` / `ContainerCLI`.
final class ResultCache: CommandRunner, Sendable {
    private let inner: any CommandRunner
    private let ttl: Duration
    private struct Entry { let data: Data; let storedAt: ContinuousClock.Instant }
    private let entries = OSAllocatedUnfairLock(initialState: [String: Entry]())

    init(inner: any CommandRunner, ttl: Duration = .milliseconds(1000)) {
        self.inner = inner
        self.ttl = ttl
    }

    func run(binary: String, args: [String], timeout: Duration) async throws -> Data {
        let key = Self.key(binary, args)
        if let hit = entries.withLock({ $0[key] }), ContinuousClock.now - hit.storedAt < ttl {
            return hit.data
        }
        // Between this miss and the store, a concurrent request may also miss and
        // fetch. That is acceptable: this is dedupe, not a correctness invariant.
        let data = try await inner.run(binary: binary, args: args, timeout: timeout)
        entries.withLock { $0[key] = Entry(data: data, storedAt: ContinuousClock.now) }
        return data
    }

    func stream(binary: String, args: [String]) -> LogStream {
        inner.stream(binary: binary, args: args)
    }

    /// Side-effecting callers (writes, run, pull) bypass the dedupe map so a
    /// repeated call within the TTL is not turned into a cached no-op.
    func runUncached(binary: String, args: [String], timeout: Duration) async throws -> Data {
        try await inner.runUncached(binary: binary, args: args, timeout: timeout)
    }

    /// Side-effecting + output-discarding: bypass the map and delegate to the
    /// real `/dev/null` sink on the inner runner.
    func runDiscardingOutput(binary: String, args: [String], timeout: Duration) async throws {
        try await inner.runDiscardingOutput(binary: binary, args: args, timeout: timeout)
    }

    /// Null-separated so `binary` and each arg can't collide across shapes.
    private static func key(_ binary: String, _ args: [String]) -> String {
        binary + "\u{0}" + args.joined(separator: "\u{0}")
    }
}
