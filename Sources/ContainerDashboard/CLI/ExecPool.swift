import Foundation

/// Caps concurrent exec sessions. Each ws exec holds one slot for its lifetime;
/// overflow is rejected (the route refuses the upgrade rather than spawning an
/// unbounded number of `container exec` children). An actor serializes the
/// count so concurrent upgrades cannot all pass the check at once.
actor ExecPool {
    static let shared = ExecPool(capacity: 8)
    private let capacity: Int
    private var inUse = 0

    init(capacity: Int) { self.capacity = capacity }

    func acquire() throws {
        guard inUse < capacity else { throw ExecPoolError.full }
        inUse += 1
    }

    func release() {
        guard inUse > 0 else { return }
        inUse -= 1
    }

    var count: Int { inUse }
}

enum ExecPoolError: Error, Equatable {
    case full
}
