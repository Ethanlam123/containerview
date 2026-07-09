import Foundation

/// One container's stats plus the CPU% derived from the previous snapshot.
struct StatsWithCPU: Codable, Sendable {
    let stats: ContainerStats
    let cpuPercent: Double

    /// Sum of per-container CPU% (NOT divided by allocated CPUs - a 4-CPU
    /// container at saturation contributes ~400%) and sum of memory used.
    /// Used by the Resource Overview sparkline.
    static func aggregate(_ items: [StatsWithCPU]) -> (cpuPercent: Double, memoryBytes: Int64) {
        let cpu = items.reduce(0.0) { $0 + $1.cpuPercent }
        let mem = items.reduce(Int64(0)) { $0 + $1.stats.memoryUsageBytes }
        return (cpu, mem)
    }
}

/// Keeps the previous `{cpuUsageUsec, wallUsec}` per container id and derives
/// CPU% between snapshots. The CLI emits cumulative microseconds (not a
/// percentage), so a baseline must be retained; the backend supplies the wall
/// time at fetch completion (the CLI emits no timestamp).
actor StatsTracker {
    private struct Snapshot { let cpuUsageUsec: Int64; let wallUsec: Int64 }
    private var prev: [String: Snapshot] = [:]

    func update(_ raw: [ContainerStats], at wall: Date) -> [StatsWithCPU] {
        let wallUsec = Int64(wall.timeIntervalSince1970 * 1_000_000)
        var result: [StatsWithCPU] = []
        var live = Set<String>()
        result.reserveCapacity(raw.count)
        for s in raw {
            live.insert(s.id)
            let cpu: Double
            if let p = prev[s.id], wallUsec > p.wallUsec {
                let dWall = Double(wallUsec - p.wallUsec)
                let dCPU = Double(s.cpuUsageUsec - p.cpuUsageUsec)
                // cpuUsec is cumulative; a regression (clock jitter, restart) reads as 0.
                cpu = max(0, (dCPU / dWall) * 100)
            } else {
                cpu = 0   // first sample after start, or zero wall-time delta
            }
            result.append(StatsWithCPU(stats: s, cpuPercent: cpu))
            prev[s.id] = Snapshot(cpuUsageUsec: s.cpuUsageUsec, wallUsec: wallUsec)
        }
        // Prune ids absent from this sample so container churn does not leak memory.
        prev = prev.filter { live.contains($0.key) }
        return result
    }
}
