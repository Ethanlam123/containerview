import Testing
import Foundation
@testable import ContainerDashboard

/// Composition + resilience: every section fails independently, stats get CPU%,
/// and the buildkit builder is filtered out of containers + stats.
private func fixture(_ name: String) throws -> Data {
    guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures") else {
        struct Missing: Error {}; throw Missing()
    }
    return try Data(contentsOf: url)
}

private func fullFake(
    overrides: [String: Data] = [:],
    errors: [String: CLIError] = [:]
) throws -> FakeCommandRunner {
    var bytes: [String: Data] = [
        FakeCommandRunner.key("container", ["ls", "--format", "json", "--all"]): try fixture("ls"),
        FakeCommandRunner.key("container", ["stats", "--format", "json", "--no-stream"]): try fixture("stats"),
        FakeCommandRunner.key("container", ["machine", "ls", "--format", "json"]): try fixture("machine_ls_empty"),
        FakeCommandRunner.key("container", ["image", "list", "--format", "json"]): try fixture("image_list"),
        FakeCommandRunner.key("container", ["network", "list", "--format", "json"]): try fixture("network_list"),
        FakeCommandRunner.key("container", ["system", "df", "--format", "json"]): try fixture("system_df"),
        FakeCommandRunner.key("container", ["builder", "status", "--format", "json"]): try fixture("builder_status_empty"),
        FakeCommandRunner.key("container", ["system", "version", "--format", "json"]): try fixture("version"),
        FakeCommandRunner.key("container", ["system", "status", "--format", "json"]): try fixture("system_status"),
        FakeCommandRunner.key("sw_vers", ["-productVersion"]): Data("15.2.0\n".utf8),
    ]
    for (k, v) in overrides { bytes[k] = v }
    return FakeCommandRunner(bytes: bytes, errors: errors)
}

private func state(_ fake: FakeCommandRunner, tracker: StatsTracker = StatsTracker()) async -> DashboardState {
    await StateService().state(runner: fake, tracker: tracker)
}

@Test func c1_allSectionsPopulated_noWarnings() async throws {
    let s = await state(try fullFake())
    #expect(s.health?.status == "running")
    #expect(s.containers?.isEmpty == false)
    #expect(s.stats?.isEmpty == false)
    #expect(s.images?.isEmpty == false)
    #expect(s.networks?.isEmpty == false)
    #expect(s.diskUsage != nil)
    #expect(s.version?.count == 2)
    #expect(s.macosVersion == "15.2.0")
    #expect(s.warnings.isEmpty)
}

@Test func c2_statsTimedOut_statsNilWithWarning_othersIntact() async throws {
    let fake = try fullFake(errors: [
        FakeCommandRunner.key("container", ["stats", "--format", "json", "--no-stream"]): .timedOut,
    ])
    let s = await state(fake)
    #expect(s.stats == nil)
    #expect(s.warnings.contains { $0.section == "stats" })
    #expect(s.containers?.isEmpty == false)   // other sections survived
    #expect(s.health?.status == "running")
}

@Test func c3_builderEmptyArray_isEmptyNotWarning() async throws {
    let s = await state(try fullFake())
    #expect(s.builder != nil)
    #expect(s.builder?.isEmpty == true)
    #expect(s.warnings.contains { $0.section == "builder" } == false)
}

@Test func c4_statsMerged_cpuPercentPopulated() async throws {
    let s = await state(try fullFake())
    let first = try #require(s.stats?.first)
    #expect(first.stats.id == "hermes")
    #expect(first.cpuPercent == 0.0)   // first sample, no baseline
}

@Test func c5_macosVersionTrimmed() async throws {
    let s = await state(try fullFake())
    #expect(s.macosVersion == "15.2.0")
}

@Test func c6_partialResponseStillReturned() async throws {
    // stats + images both fail; the response is still a valid DashboardState.
    let fake = try fullFake(errors: [
        FakeCommandRunner.key("container", ["stats", "--format", "json", "--no-stream"]): .timedOut,
        FakeCommandRunner.key("container", ["image", "list", "--format", "json"]): .timedOut,
    ])
    let s = await state(fake)
    #expect(s.health?.status == "running")
    #expect(s.warnings.count == 2)
    #expect(s.warnings.contains { $0.section == "stats" })
    #expect(s.warnings.contains { $0.section == "images" })
}

// MARK: - Buildkit filter (B1-B3)

@Test func b1_builderRunning_filtersBuilderFromContainersAndStats() async throws {
    let builderWithID = #"[{"state":"running","containerID":"hermes","cpus":2,"memoryInBytes":2147483648}]"#
    let fake = try fullFake(overrides: [
        FakeCommandRunner.key("container", ["builder", "status", "--format", "json"]): Data(builderWithID.utf8),
    ])
    let s = await state(fake)
    #expect(s.containers?.contains { $0.id == "hermes" } == false)
    #expect(s.stats?.contains { $0.stats.id == "hermes" } == false)
}

@Test func b2_builderEmpty_noFilter() async throws {
    let s = await state(try fullFake())   // builder_status_empty.json is []
    #expect(s.containers?.contains { $0.id == "hermes" } == true)
}

@Test func b3_builderDecodeFails_noFilter_withWarning() async throws {
    let fake = try fullFake(overrides: [
        FakeCommandRunner.key("container", ["builder", "status", "--format", "json"]): Data("not-json".utf8),
    ])
    let s = await state(fake)
    #expect(s.builder == nil)
    #expect(s.warnings.contains { $0.section == "builder" })
    #expect(s.containers?.contains { $0.id == "hermes" } == true)   // not filtered
}
