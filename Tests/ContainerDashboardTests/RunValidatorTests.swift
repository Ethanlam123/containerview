import Testing
import Foundation
@testable import ContainerDashboard

// MARK: - PortSpec

@Test func port_simple_defaults_loopback() throws {
    let p = try PortSpec(raw: "8080:80")
    #expect(p.argv == "127.0.0.1:8080:80/tcp")
}

@Test func port_with_explicit_loopback() throws {
    let p = try PortSpec(raw: "127.0.0.1:9090:90")
    #expect(p.argv == "127.0.0.1:9090:90/tcp")
}

@Test func port_udp_proto() throws {
    let p = try PortSpec(raw: "5353:5353/udp")
    #expect(p.argv == "127.0.0.1:5353:5353/udp")
}

@Test(arguments: [
    "0:80",            // host port 0
    "8080:0",          // container port 0
    "99999:80",        // out of range
    "8080:80:extra",   // too many parts (no ip) - 4 parts
    "abc:80",          // non-numeric
    "-p:80",           // leading dash
    "8080:80/icmp",    // bad proto
    "8080:80\n",       // newline
    "80 80:80",        // whitespace (leading not dash, but invalid shape)
])
func port_invalid(_ raw: String) {
    #expect(throws: SpecError.self) { try PortSpec(raw: raw) }
}

@Test func port_remote_bind_rejected_by_default() {
    // CONTAINERDASHBOARD_ALLOW_REMOTE_BIND is unset in tests -> non-loopback rejected.
    #expect(throws: SpecError.self) { try PortSpec(raw: "0.0.0.0:8080:80") }
}

@Test func port_remote_bind_allowed_when_opted_in() throws {
    // The injectable policy lets the opt-in branch be exercised without env mutation.
    let p = try PortSpec(raw: "0.0.0.0:8080:80", allowRemote: true)
    #expect(p.argv == "0.0.0.0:8080:80/tcp")
}

@Test func port_loopback_range_accepted() throws {
    // 127.0.0.0/8 is loopback; 127.1.2.3 is safe to bind without the opt-in.
    #expect((try PortSpec(raw: "127.1.2.3:8080:80")).argv == "127.1.2.3:8080:80/tcp")
}

@Test func port_bad_octet_rejected() {
    #expect(throws: SpecError.self) { try PortSpec(raw: "999.0.0.1:80:80") }
}

// MARK: - EnvSpec

@Test func env_key_value() throws {
    let e = try EnvSpec(raw: "FOO=bar")
    #expect(e.argv == "FOO=bar")
}

@Test func env_inherit_key_only() throws {
    let e = try EnvSpec(raw: "LANG")
    #expect(e.argv == "LANG")
}

@Test(arguments: [
    "=novalue",        // empty key
    "1FOO=v",          // key starts with digit
    "FOO VAL=v",       // key has space
    "FOO=a\nb",        // newline in value
    "-FOO=v",          // key leading dash (also fails key regex)
])
func env_invalid(_ raw: String) {
    #expect(throws: SpecError.self) { try EnvSpec(raw: raw) }
}

// MARK: - VolumeSpec

@Test func volume_bind() throws {
    let v = try VolumeSpec(raw: "/host/data:/data")
    #expect(v.argv == "/host/data:/data")
}

@Test func volume_bind_readonly() throws {
    let v = try VolumeSpec(raw: "/host/data:/data:ro")
    #expect(v.argv == "/host/data:/data:ro")
}

@Test func volume_anonymous() throws {
    let v = try VolumeSpec(raw: "/data")
    #expect(v.argv == "/data")
}

@Test(arguments: [
    "",                // empty
    "-x:/y",           // leading dash
    "/a:/b\n",         // newline
    "/a:/b:rw",        // bad option (only ro allowed)
])
func volume_invalid(_ raw: String) {
    #expect(throws: SpecError.self) { try VolumeSpec(raw: raw) }
}

// MARK: - MemorySpec

@Test func memory_plain_number() throws {
    let m = try MemorySpec(raw: "512")
    #expect(m.argv == "512")
}

@Test func memory_with_suffix() throws {
    let m = try MemorySpec(raw: "512M")
    #expect(m.argv == "512M")
}

@Test func memory_accepts_lowercase_units() throws {
    #expect(try MemorySpec(raw: "512m").argv == "512m")
    #expect(try MemorySpec(raw: "2g").argv == "2g")
}

@Test(arguments: [
    "1Q",              // bad suffix
    "-512",            // leading dash
    "abc",             // non-numeric
    "512M\n",          // newline
])
func memory_invalid(_ raw: String) {
    #expect(throws: SpecError.self) { try MemorySpec(raw: raw) }
}

// MARK: - ContainerRunRequest

@Test func run_request_minimal() throws {
    let req = try JSONDecoder().decode(ContainerRunRequest.self, from: Data(#"{"image":"alpine"}"#.utf8))
    #expect(req.image == "alpine")
    #expect(req.name == nil)
    #expect(req.ports == [])
}

@Test func run_request_full() throws {
    let json = #"{"image":"alpine","name":"smoke","ports":["8080:80"],"env":["FOO=bar"],"volumes":["/h:/d"],"cpus":2,"memory":"512M","args":["sh","-c","echo hi"],"rm":true}"#
    let req = try JSONDecoder().decode(ContainerRunRequest.self, from: Data(json.utf8))
    #expect(req.name == "smoke")
    #expect(req.ports.first?.argv == "127.0.0.1:8080:80/tcp")
    #expect(req.env.first?.argv == "FOO=bar")
    #expect(req.cpus == 2)
    #expect(req.memory?.argv == "512M")
    #expect(req.args == ["sh", "-c", "echo hi"])
    #expect(req.rm == true)
}

@Test func run_request_rejects_bad_image() {
    #expect(throws: (any Error).self) {
        try JSONDecoder().decode(ContainerRunRequest.self, from: Data(#"{"image":"foo bar"}"#.utf8))
    }
}

@Test func run_request_rejects_bad_name() {
    #expect(throws: (any Error).self) {
        try JSONDecoder().decode(ContainerRunRequest.self, from: Data(#"{"image":"alpine","name":"-bad"}"#.utf8))
    }
}

@Test func run_request_rejects_bad_port() {
    #expect(throws: (any Error).self) {
        try JSONDecoder().decode(ContainerRunRequest.self, from: Data(#"{"image":"alpine","ports":["0.0.0.0:80:80"]}"#.utf8))
    }
}
