import Testing
import Foundation
@testable import ContainerDashboard

/// The argument array IS the security boundary (CommandRunner never shells out),
/// so every wrapper's argv is asserted. StateServiceTests only covers the
/// /api/state subset; this covers the rest.
private func fake(_ binary: String, _ args: [String], bytes: String = "[]", lines: [String] = []) -> FakeCommandRunner {
    if lines.isEmpty {
        return FakeCommandRunner(bytes: [FakeCommandRunner.key(binary, args): Data(bytes.utf8)])
    }
    return FakeCommandRunner(streams: [FakeCommandRunner.key(binary, args): lines])
}

private func args(_ fake: FakeCommandRunner) throws -> [String] {
    try #require(fake.calls.last?.args)
}

@Test func ls_args() async throws {
    let f = fake("container", ["ls", "--format", "json", "--all"])
    _ = try await ContainerCLI.ls(f)
    #expect(try args(f) == ["ls", "--format", "json", "--all"])
    #expect(f.calls.last?.binary == "container")
}

@Test func stats_args() async throws {
    let f = fake("container", ["stats", "--format", "json", "--no-stream"])
    _ = try await ContainerCLI.stats(f)
    #expect(try args(f) == ["stats", "--format", "json", "--no-stream"])
}

@Test func inspect_args_noFormatFlag() async throws {
    let f = fake("container", ["inspect", "hermes"])
    _ = try await ContainerCLI.inspect(f, id: "hermes")
    #expect(try args(f) == ["inspect", "hermes"])   // JSON default, no --format
}

@Test func systemReads_args() async throws {
    let f1 = fake("container", ["system", "status", "--format", "json"], bytes: "{\"status\":\"running\"}")
    _ = try await ContainerCLI.systemStatus(f1)
    #expect(try args(f1) == ["system", "status", "--format", "json"])

    let f2 = fake("container", ["system", "version", "--format", "json"])
    _ = try await ContainerCLI.version(f2)
    #expect(try args(f2) == ["system", "version", "--format", "json"])

    let dfBytes = #"{"containers":{"active":0,"reclaimable":0,"sizeInBytes":0,"total":0},"images":{"active":0,"reclaimable":0,"sizeInBytes":0,"total":0},"volumes":{"active":0,"reclaimable":0,"sizeInBytes":0,"total":0}}"#
    let f3 = fake("container", ["system", "df", "--format", "json"], bytes: dfBytes)
    _ = try await ContainerCLI.systemDF(f3)
    #expect(try args(f3) == ["system", "df", "--format", "json"])
}

@Test func builderStatus_args() async throws {
    let f = fake("container", ["builder", "status", "--format", "json"])
    _ = try await ContainerCLI.builderStatus(f)
    #expect(try args(f) == ["builder", "status", "--format", "json"])
}

@Test func machines_args() async throws {
    let f1 = fake("container", ["machine", "ls", "--format", "json"])
    _ = try await ContainerCLI.machines(f1)
    #expect(try args(f1) == ["machine", "ls", "--format", "json"])

    let f2 = fake("container", ["machine", "inspect", "dev"])
    _ = try await ContainerCLI.machineInspect(f2, id: "dev")
    #expect(try args(f2) == ["machine", "inspect", "dev"])
}

@Test func images_args() async throws {
    let f = fake("container", ["image", "list", "--format", "json"])
    _ = try await ContainerCLI.images(f)
    #expect(try args(f) == ["image", "list", "--format", "json"])
}

@Test func imageInspect_refIsSingleArgvElement() async throws {
    let ref = "docker.io/library/hello-world:latest"
    let f = fake("container", ["image", "inspect", ref])
    _ = try await ContainerCLI.imageInspect(f, ref: ref)
    let a = try args(f)
    #expect(a == ["image", "inspect", ref])   // ref NOT split on ":" or "/"
    #expect(a.count == 3)
}

@Test func networks_args() async throws {
    let f = fake("container", ["network", "list", "--format", "json"])
    _ = try await ContainerCLI.networks(f)
    #expect(try args(f) == ["network", "list", "--format", "json"])
}

@Test func systemProperties_and_dns_args() async throws {
    let f1 = fake("container", ["system", "property", "list", "--format", "json"], bytes: "{}")
    _ = try await ContainerCLI.systemProperties(f1)
    #expect(try args(f1) == ["system", "property", "list", "--format", "json"])

    let f2 = fake("container", ["system", "dns", "list", "--format", "json"], bytes: "[]")
    _ = try await ContainerCLI.dnsDomains(f2)
    #expect(try args(f2) == ["system", "dns", "list", "--format", "json"])
}

@Test func macosVersion_usesSwVers() async throws {
    let f = fake("sw_vers", ["-productVersion"], bytes: "15.2.0\n")
    let v = try await ContainerCLI.macosVersion(f)
    #expect(v == "15.2.0")
    #expect(f.calls.last?.binary == "sw_vers")
}

@Test func logsStream_args() async throws {
    let f = fake("container", ["logs", "-f", "hermes"], lines: ["line1", "line2"])
    var got: [String] = []
    for try await line in ContainerCLI.logsStream(f, id: "hermes") { got.append(line) }
    #expect(got == ["line1", "line2"])
    #expect(try args(f) == ["logs", "-f", "hermes"])
}

@Test(arguments: [("stop", "stop"), ("start", "start"), ("kill", "kill")])
func lifecycle_args(_ label: String, _ verb: String) async throws {
    let f = fake("container", [verb, "x"])
    switch verb {
    case "stop": try await ContainerCLI.stop(f, id: "x")
    case "start": try await ContainerCLI.start(f, id: "x")
    default: try await ContainerCLI.kill(f, id: "x")
    }
    #expect(try args(f) == [verb, "x"])
}

@Test func builderStartStop_args() async throws {
    let f1 = fake("container", ["builder", "start"])
    try await ContainerCLI.builderStart(f1)
    #expect(try args(f1) == ["builder", "start"])

    let f2 = fake("container", ["builder", "stop"])
    try await ContainerCLI.builderStop(f2)
    #expect(try args(f2) == ["builder", "stop"])
}

@Test func prune_args_mapWhitelist() async throws {
    let f1 = fake("container", ["prune"])
    try await ContainerCLI.prune(f1, category: .containers)
    #expect(try args(f1) == ["prune"])

    let f2 = fake("container", ["image", "prune", "-a"])
    try await ContainerCLI.prune(f2, category: .images)
    #expect(try args(f2) == ["image", "prune", "-a"])

    let f3 = fake("container", ["volume", "prune"])
    try await ContainerCLI.prune(f3, category: .volumes)
    #expect(try args(f3) == ["volume", "prune"])
}
