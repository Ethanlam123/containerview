import Foundation
import os
@testable import ContainerDashboard

/// In-memory CommandRunner for tests. Returns canned bytes per (binary, args),
/// throws a planted `CLIError` on demand, and yields planted stream lines.
/// Records every call so argument-array construction can be asserted.
///
/// Backed by `OSAllocatedUnfairLock` because `StateService` fans out many
/// concurrent reads against one fake - plain mutable state would race (and
/// crash the test process under parallel execution).
final class FakeCommandRunner: CommandRunner, @unchecked Sendable {
    private struct Store {
        var bytes: [String: Data] = [:]
        var errors: [String: CLIError] = [:]
        var streams: [String: [String]] = [:]
        var calls: [(binary: String, args: [String])] = []
        var discardingCalls: [(binary: String, args: [String])] = []
    }
    private let store = OSAllocatedUnfairLock(initialState: Store())

    init(
        bytes: [String: Data] = [:],
        errors: [String: CLIError] = [:],
        streams: [String: [String]] = [:]
    ) {
        store.withLock { s in
            s.bytes = bytes
            s.errors = errors
            s.streams = streams
        }
    }

    var calls: [(binary: String, args: [String])] {
        store.withLock { $0.calls }
    }

    /// Calls to `runDiscardingOutput` (kept separate from `calls` so tests can
    /// prove a command took the discarding path, not the capturing `run` path).
    var discardingCalls: [(binary: String, args: [String])] {
        store.withLock { $0.discardingCalls }
    }

    static func key(_ binary: String, _ args: [String]) -> String {
        "\(binary) \(args.joined(separator: " "))"
    }

    func run(binary: String, args: [String], timeout: Duration) async throws -> Data {
        let k = Self.key(binary, args)
        let (err, data) = store.withLock { s -> (CLIError?, Data?) in
            s.calls.append((binary, args))
            return (s.errors[k], s.bytes[k])
        }
        if let err { throw err }
        guard let data else { throw CLIError.missing }
        return data
    }

    func runDiscardingOutput(binary: String, args: [String], timeout: Duration) async throws {
        let k = Self.key(binary, args)
        let (err, hasData) = store.withLock { s -> (CLIError?, Bool) in
            s.discardingCalls.append((binary, args))
            return (s.errors[k], s.bytes[k] != nil)
        }
        if let err { throw err }
        // The real runner discards output; the fake just needs to not throw when
        // bytes were planted (proving the call was accepted).
        guard hasData else { throw CLIError.missing }
    }

    func stream(binary: String, args: [String]) -> LogStream {
        let k = Self.key(binary, args)
        let lines = store.withLock { s -> [String] in
            s.calls.append((binary, args))
            return s.streams[k] ?? []
        }
        let linesStream = AsyncThrowingStream<String, Error> { c in
            for line in lines { c.yield(line) }
            c.finish()
        }
        return LogStream(lines: linesStream, cancel: { })
    }
}
