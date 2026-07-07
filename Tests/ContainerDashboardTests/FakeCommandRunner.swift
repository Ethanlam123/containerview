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

    func stream(binary: String, args: [String]) -> AsyncThrowingStream<String, Error> {
        let k = Self.key(binary, args)
        let lines = store.withLock { s -> [String] in
            s.calls.append((binary, args))
            return s.streams[k] ?? []
        }
        return AsyncThrowingStream { c in
            for line in lines { c.yield(line) }
            c.finish()
        }
    }
}
