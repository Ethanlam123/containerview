// Regression tests for the app's pure logic. The Spec encoding is the high-value
// one: a drift from the server's single-value RunSpecs shape makes every
// container create 400. deriveRows is the containers+stats join that backs the
// table.

import Testing
import Foundation
import ContainerMonitorCore

@Test("ContainerRunRequest encodes argv-bound fields as bare JSON strings")
func runRequestWireShape() throws {
    let req = ContainerRunRequest(
        image: "alpine:latest",
        name: "demo",
        ports: [.init(rawValue: "127.0.0.1:8080:80/tcp")],
        env: [.init(rawValue: "FOO=bar")],
        volumes: [.init(rawValue: "/h:/c:ro")],
        cpus: 2,
        memory: .init(rawValue: "512m"),
        args: ["echo", "hi"],
        rm: false
    )

    let obj = try JSONSerialization.jsonObject(
        with: JSONEncoder().encode(req)
    ) as! [String: Any]

    // Spec fields must be bare strings / arrays of strings, NOT objects.
    // A regression (e.g. Spec becoming a struct with a property) encodes
    // {"rawValue":"..."} here and the server 400s every create.
    #expect(obj["image"] as? String == "alpine:latest")
    #expect(obj["name"] as? String == "demo")
    #expect(obj["ports"] as? [String] == ["127.0.0.1:8080:80/tcp"])
    #expect(obj["env"] as? [String] == ["FOO=bar"])
    #expect(obj["volumes"] as? [String] == ["/h:/c:ro"])
    #expect(obj["memory"] as? String == "512m")
    #expect(obj["cpus"] as? Int == 2)
    #expect(obj["args"] as? [String] == ["echo", "hi"])
    #expect(obj["rm"] as? Bool == false)
}

@Test("Optional run fields are omitted when nil (encodeIfPresent)")
func runRequestOmitsNil() throws {
    let req = ContainerRunRequest(
        image: "alpine", name: nil, ports: [], env: [], volumes: [],
        cpus: nil, memory: nil, args: [], rm: nil
    )
    let obj = try JSONSerialization.jsonObject(
        with: JSONEncoder().encode(req)
    ) as! [String: Any]

    #expect(obj["image"] as? String == "alpine")
    #expect(obj["name"] == nil)
    #expect(obj["cpus"] == nil)
    #expect(obj["memory"] == nil)
    #expect(obj["rm"] == nil)
}

@Test("deriveRows joins containers with their stats by id")
func deriveRowsJoinsStats() {
    let container = ContainerList(
        id: "abc123",
        configuration: .init(
            id: "abc123",
            image: .init(reference: "alpine:latest",
                        descriptor: .init(digest: "sha256:deadbeef", size: 7, mediaType: nil)),
            resources: .init(cpus: 2, memoryInBytes: 536870912, cpuOverhead: nil),
            platform: .init(architecture: "arm64", os: "linux"),
            publishedPorts: nil, mounts: nil, hostname: nil),
        status: .init(state: "running",
                      networks: [.init(network: "default", ipv4Address: "10.0.0.1",
                                       ipv6Address: nil, ipv4Gateway: nil,
                                       macAddress: nil, hostname: nil)],
                      startedDate: nil))
    let stat = StatsWithCPU(
        stats: .init(id: "abc123", memoryUsageBytes: 1234567, memoryLimitBytes: 536870912,
                     cpuUsageUsec: 0, networkRxBytes: 0, networkTxBytes: 0,
                     blockReadBytes: 0, blockWriteBytes: 0, numProcesses: 1),
        cpuPercent: 12.5)
    let state = DashboardState(containers: [container], stats: [stat])

    let rows = deriveRows(state)

    #expect(rows.count == 1)
    let row = rows[0]
    #expect(row.id == "abc123")
    #expect(row.imageRef == "alpine:latest")
    #expect(row.state == "running")
    #expect(row.ip == "10.0.0.1")
    #expect(row.cpuPercent == 12.5)
    #expect(row.memoryBytes == 1234567)
    #expect(row.memoryLimit == 536870912)
    #expect(row.arch == "arm64")
    #expect(row.cpus == 2)
}

@Test("deriveRows renders a container with no matching stat")
func deriveRowsMissingStat() {
    let container = ContainerList(
        id: "xyz",
        configuration: .init(
            id: "xyz",
            image: .init(reference: "busybox",
                        descriptor: .init(digest: "sha256:1", size: 1, mediaType: nil)),
            resources: .init(cpus: 1, memoryInBytes: 0, cpuOverhead: nil),
            platform: .init(architecture: "amd64", os: "linux"),
            publishedPorts: nil, mounts: nil, hostname: nil),
        status: .init(state: "created", networks: nil, startedDate: nil))

    let rows = deriveRows(DashboardState(containers: [container]))

    #expect(rows.count == 1)
    let row = rows[0]
    #expect(row.cpuPercent == nil)
    #expect(row.memoryBytes == nil)
    #expect(row.ip == "-")
}
