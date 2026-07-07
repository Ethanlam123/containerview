import Foundation
@testable import ContainerDashboard

/// In-memory CommandRunner for tests. Returns canned bytes per (binary, args),
/// throws a planted `CLIError` on demand, and yields planted stream lines.
/// Records every call so argument-array construction can be asserted.
///
/// `@unchecked Sendable`: each test owns its own instance and calls are
/// sequential within a test, so plain mutable state is safe by usage discipline
/// (no cross-test sharing, no overlapping awaits on one fake).
final class FakeCommandRunner: CommandRunner, @unchecked Sendable {
    var bytes: [String: Data]
    var errors: [String: CLIError]
    var streams: [String: [String]]
    private(set) var calls: [(binary: String, args: [String])] = []

    init(
        bytes: [String: Data] = [:],
        errors: [String: CLIError] = [:],
        streams: [String: [String]] = [:]
    ) {
        self.bytes = bytes
        self.errors = errors
        self.streams = streams
    }

    static func key(_ binary: String, _ args: [String]) -> String {
        "\(binary) \(args.joined(separator: " "))"
    }

    func run(binary: String, args: [String], timeout: Duration) async throws -> Data {
        calls.append((binary, args))
        let k = Self.key(binary, args)
        if let err = errors[k] { throw err }
        guard let data = bytes[k] else { throw CLIError.missing }
        return data
    }

    func stream(binary: String, args: [String]) -> AsyncThrowingStream<String, Error> {
        calls.append((binary, args))
        let k = Self.key(binary, args)
        let lines = streams[k] ?? []
        return AsyncThrowingStream { c in
            for line in lines { c.yield(line) }
            c.finish()
        }
    }
}
