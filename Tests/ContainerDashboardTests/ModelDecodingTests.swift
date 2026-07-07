import Testing
import Foundation
@testable import ContainerDashboard

/// Ground-truth decode tests: every captured fixture round-trips through
/// `JSONDecoder` and asserts specific fields (not just "didn't throw").
/// Shapes are the captured CLI output, which governs where it diverges from prose.

private let decoder = JSONDecoder()

private enum FixtureError: Error { case missing(String) }

private func fixtureData(_ name: String) throws -> Data {
    guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures") else {
        throw FixtureError.missing(name)
    }
    return try Data(contentsOf: url)
}

private func decode<T: Decodable>(_ type: T.Type, _ fixture: String) throws -> T {
    try decoder.decode(T.self, from: fixtureData(fixture))
}

// MARK: - D1 Container list

@Test func d1_containerList() throws {
    let list = try decode([ContainerList].self, "ls")
    #expect(list.count == 1)
    let c = try #require(list.first)
    #expect(c.id == "hermes")
    #expect(c.status.state == "running")

    let net = try #require(c.status.networks?.first)
    #expect(net.ipv4Address?.isEmpty == false)

    #expect(c.configuration.resources.cpus == 4)
    #expect(c.configuration.resources.memoryInBytes == 1_073_741_824)
    #expect(c.configuration.resources.cpuOverhead == 1)

    #expect(c.configuration.image.reference == "docker.io/nousresearch/hermes-agent:latest")
    #expect(c.configuration.image.descriptor.size == 1609)
    #expect(c.configuration.platform.architecture == "arm64")
    #expect(c.configuration.platform.os == "linux")
}

@Test func d1b_inspectReusesContainerList() throws {
    // container inspect <id> returns the same {configuration,id,status} shape.
    let inspected = try decode([ContainerList].self, "inspect")
    #expect(inspected.first?.id == "hermes")
    let mount = try #require(inspected.first?.configuration.mounts?.first)
    #expect(mount.type.kind == "virtiofs")
    let port = try #require(inspected.first?.configuration.publishedPorts?.first)
    #expect(port.hostPort == 9119)
    #expect(port.containerPort == 9119)
}

// MARK: - D2 Stats (flat camelCase)

@Test func d2_stats() throws {
    let stats = try decode([ContainerStats].self, "stats")
    let s = try #require(stats.first)
    #expect(s.id == "hermes")
    #expect(s.cpuUsageUsec > 0)
    #expect(s.memoryLimitBytes == 1_073_741_824)
    #expect(s.memoryUsageBytes > 0)
    #expect(s.networkRxBytes >= 0)
    #expect(s.networkTxBytes >= 0)
    #expect(s.blockReadBytes >= 0)
    #expect(s.blockWriteBytes >= 0)
    #expect(s.numProcesses > 0)
}

// MARK: - D3 Disk usage (object, three categories)

@Test func d3_systemDF() throws {
    let df = try decode(SystemDF.self, "system_df")
    #expect(df.containers.total == 1)
    #expect(df.containers.active == 1)
    #expect(df.images.total == 3)
    #expect(df.images.reclaimable > 0)
    #expect(df.images.sizeInBytes > 0)
    #expect(df.volumes.total == 0)
}

// MARK: - D4 Version (array, up to 2 rows)

@Test func d4_version() throws {
    let v = try decode([VersionComponent].self, "version")
    #expect(v.count == 2)
    #expect(v[0].appName == "container")
    #expect(v[0].version == "1.0.0")
    #expect(v[1].appName == "container-apiserver")
    #expect(v[1].buildType == "release")
}

// MARK: - D5 System status

@Test func d5_systemStatus() throws {
    let s = try decode(SystemStatus.self, "system_status")
    #expect(s.status == "running")
}

// MARK: - D6 Image list

@Test func d6_imageList() throws {
    let images = try decode([ImageList].self, "image_list")
    #expect(images.isEmpty == false)
    let first = try #require(images.first)
    #expect(first.configuration.name.isEmpty == false)
    let variant = try #require(first.variants.first)
    #expect(variant.platform.architecture.isEmpty == false)
    #expect(variant.size > 0)
    let totalVariantSize = first.variants.reduce(Int64(0)) { $0 + $1.size }
    #expect(totalVariantSize > 0)
}

@Test func d6b_imageInspectReusesImageList() throws {
    let inspected = try decode([ImageList].self, "image_inspect")
    #expect(inspected.first?.configuration.name == "docker.io/library/hello-world:latest")
}

// MARK: - D7 Network list

@Test func d7_networkList() throws {
    let nets = try decode([NetworkList].self, "network_list")
    let n = try #require(nets.first)
    #expect(n.configuration.name == "default")
    #expect(n.status.ipv4Gateway.isEmpty == false)
}

// MARK: - D8 / D9 Empty arrays decode cleanly

@Test func d8_builderStatusEmpty() throws {
    let b = try decode([BuilderStatus].self, "builder_status_empty")
    #expect(b.isEmpty)
}

@Test func d9_machineListEmpty() throws {
    let m = try decode([MachineList].self, "machine_ls_empty")
    #expect(m.isEmpty)
}

// MARK: - D10 Forward-compat (unknown keys ignored)

@Test func d10_unknownKeysIgnored() throws {
    var raw = try JSONSerialization.jsonObject(with: fixtureData("ls")) as! [[String: Any]]
    raw[0]["__future_field__"] = ["nested": 42]
    let data = try JSONSerialization.data(withJSONObject: raw)
    let list = try decoder.decode([ContainerList].self, from: data)
    #expect(list.first?.id == "hermes")
}

// MARK: - D11 Optional absence

@Test func d11_optionalAbsence() throws {
    let json = """
    [{
      "id": "bare",
      "configuration": {
        "id": "bare",
        "image": {"reference": "r", "descriptor": {"digest": "d", "size": 1}},
        "resources": {"cpus": 1, "memoryInBytes": 2},
        "platform": {"architecture": "arm64", "os": "linux"}
      },
      "status": {"state": "stopped"}
    }]
    """
    let list = try decoder.decode([ContainerList].self, from: Data(json.utf8))
    let c = try #require(list.first)
    #expect(c.configuration.publishedPorts == nil)
    #expect(c.configuration.mounts == nil)
    #expect(c.status.networks == nil)
    #expect(c.status.startedDate == nil)
}

// MARK: - D12 Mount type tag

@Test func d12_mountTypeVirtiofs() throws {
    let virtiofs = #"{"source":"/s","destination":"/d","type":{"virtiofs":{}}}"#
    let v = try decoder.decode(ContainerList.Mount.self, from: Data(virtiofs.utf8))
    #expect(v.type.kind == "virtiofs")

    let bind = #"{"source":"/s","destination":"/d","type":{"bind":{"propagation":"rprivate"}}}"#
    let b = try decoder.decode(ContainerList.Mount.self, from: Data(bind.utf8))
    #expect(b.type.kind == "bind")
}
