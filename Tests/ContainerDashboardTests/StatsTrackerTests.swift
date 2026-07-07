import Testing
import Foundation
@testable import ContainerDashboard

/// CPU% math is the riskiest pure logic in the dashboard. These cover first
/// sample, deltas, multi-core >100%, churn pruning, zero-delta, negative clamp,
/// per-container independence, and aggregation.
private func stats(
    id: String,
    cpu: Int64,
    mem: Int64 = 100,
    rx: Int64 = 0,
    tx: Int64 = 0,
    br: Int64 = 0,
    bw: Int64 = 0,
    procs: Int = 1
) -> ContainerStats {
    ContainerStats(
        id: id, memoryUsageBytes: mem, memoryLimitBytes: 1000,
        cpuUsageUsec: cpu, networkRxBytes: rx, networkTxBytes: tx,
        blockReadBytes: br, blockWriteBytes: bw, numProcesses: procs
    )
}

private func approx(_ a: Double, _ b: Double, tol: Double = 0.01) -> Bool {
    abs(a - b) < tol
}

@Test func s1_firstSample_isZero() async {
    let t = StatsTracker()
    let r = await t.update([stats(id: "a", cpu: 1_000_000)], at: Date(timeIntervalSince1970: 0))
    #expect(r.count == 1)
    #expect(r[0].cpuPercent == 0.0)
}

@Test func s2_halfCore_over_1s() async {
    let t = StatsTracker()
    _ = await t.update([stats(id: "a", cpu: 1_000_000)], at: Date(timeIntervalSince1970: 0))
    let r = await t.update([stats(id: "a", cpu: 1_500_000)], at: Date(timeIntervalSince1970: 1))
    #expect(approx(r[0].cpuPercent, 50.0))
}

@Test func s3_fourCoresSaturated_is400() async {
    let t = StatsTracker()
    _ = await t.update([stats(id: "a", cpu: 0)], at: Date(timeIntervalSince1970: 0))
    let r = await t.update([stats(id: "a", cpu: 4_000_000)], at: Date(timeIntervalSince1970: 1))
    #expect(approx(r[0].cpuPercent, 400.0))
}

@Test func s4_containerRemoved_isPruned() async {
    let t = StatsTracker()
    _ = await t.update([stats(id: "a", cpu: 100)], at: Date(timeIntervalSince1970: 0))
    // "a" gone; bring it back later and confirm it reads as a fresh baseline (0%).
    _ = await t.update([], at: Date(timeIntervalSince1970: 1))
    let r = await t.update([stats(id: "a", cpu: 500)], at: Date(timeIntervalSince1970: 2))
    #expect(r.count == 1)
    #expect(r[0].cpuPercent == 0.0)   // pruned, so treated as first sample
}

@Test func s5_newContainer_firstSample_isZero() async {
    let t = StatsTracker()
    _ = await t.update([stats(id: "a", cpu: 100_000)], at: Date(timeIntervalSince1970: 0))
    let r = await t.update(
        [stats(id: "a", cpu: 1_100_000), stats(id: "b", cpu: 9_000_000)],
        at: Date(timeIntervalSince1970: 1)
    )
    let byId = Dictionary(uniqueKeysWithValues: r.map { ($0.stats.id, $0.cpuPercent) })
    #expect(approx(byId["a"]!, 100.0))   // delta 1_000_000 over 1s
    #expect(byId["b"] == 0.0)            // b is new this tick
}

@Test func s6_zeroWallDelta_noCrash() async {
    let t = StatsTracker()
    let instant = Date(timeIntervalSince1970: 5)
    _ = await t.update([stats(id: "a", cpu: 1_000)], at: instant)
    let r = await t.update([stats(id: "a", cpu: 5_000)], at: instant)   // same wall time
    #expect(r[0].cpuPercent == 0.0)
}

@Test func s7_perContainer_independence() async {
    let t = StatsTracker()
    _ = await t.update(
        [stats(id: "busy", cpu: 0), stats(id: "idle", cpu: 0)],
        at: Date(timeIntervalSince1970: 0)
    )
    let r = await t.update(
        [stats(id: "busy", cpu: 2_000_000), stats(id: "idle", cpu: 0)],
        at: Date(timeIntervalSince1970: 1)
    )
    let byId = Dictionary(uniqueKeysWithValues: r.map { ($0.stats.id, $0.cpuPercent) })
    #expect(approx(byId["busy"]!, 200.0))
    #expect(byId["idle"] == 0.0)
}

@Test func s8_cpuClamped_nonNegative() async {
    let t = StatsTracker()
    _ = await t.update([stats(id: "a", cpu: 5_000_000)], at: Date(timeIntervalSince1970: 0))
    // Regression: cumulative cpu went DOWN (restart/jitter) -> must not go negative.
    let r = await t.update([stats(id: "a", cpu: 4_000_000)], at: Date(timeIntervalSince1970: 1))
    #expect(r[0].cpuPercent == 0.0)
}

@Test func s9_aggregate_sumsCpuAndMemory() {
    let items = [
        StatsWithCPU(stats: stats(id: "a", cpu: 0, mem: 200), cpuPercent: 150.0),
        StatsWithCPU(stats: stats(id: "b", cpu: 0, mem: 300), cpuPercent: 50.0),
    ]
    let agg = StatsWithCPU.aggregate(items)
    #expect(approx(agg.cpuPercent, 200.0))
    #expect(agg.memoryBytes == 500)
}
