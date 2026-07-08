import Foundation

/// Parsed, validated fields of a `POST /api/containers/run` body.
///
/// Security framing (per review security-L4): the threat model is **argv-element
/// safety**, not "shell metachars" - `CommandRunner` uses argument arrays, never a
/// shell. Each spec parses its raw string into components, re-serializes a
/// canonical single argv element, and rejects NUL / CR / LF (which could let
/// `execvp` truncate or shift meaning) and a leading `-` (which the CLI option
/// parser could misread as a flag). `args` is the lone exception: it travels
/// after `image` as the container's init argv, so a leading `-` is legitimate.
///
/// Every field below is validated in `init(from:)`; decoding IS validation. A
/// failure throws `SpecError`, which the route maps to a generic 400 whose body
/// does not echo the offending value.

enum SpecError: Error, Equatable {
    case invalid(String)
}

// MARK: - Shared argv guards

/// Reject NUL / CR / LF and a leading `-`. The canonical form built from a value
/// that passes this is a single safe argv element that cannot be mistaken for a
/// flag.
private func assertArgvSafe(_ s: String) throws {
    guard !s.isEmpty else { throw SpecError.invalid("empty") }
    if s.hasPrefix("-") { throw SpecError.invalid("leading dash") }
    if s.contains("\u{0}") || s.contains("\n") || s.contains("\r") {
        throw SpecError.invalid("control char")
    }
}

/// IPv4 dotted-quad host bind (IPv6 host binds are not supported in v1).
private func assertIPv4(_ s: String) throws {
    let octets = s.split(separator: ".").compactMap { Int($0) }
    guard octets.count == 4, s.split(separator: ".").count == 4,
          octets.allSatisfy({ (0...255).contains($0) }) else {
        throw SpecError.invalid("host ip")
    }
}

private func isLoopback(_ s: String) -> Bool { s == "127.0.0.1" || s == "localhost" }

/// When unset, published ports are forced onto 127.0.0.1 and an explicit
/// non-loopback host bind is rejected - keeping the dashboard's loopback trust
/// boundary intact.
private let allowRemoteBind = ProcessInfo.processInfo.environment["CONTAINERDASHBOARD_ALLOW_REMOTE_BIND"] == "1"

// MARK: - PortSpec

/// One published port: `[host-ip:]host-port:container-port[/proto]`. Re-serialized
/// canonically with the host bind defaulting to 127.0.0.1.
struct PortSpec: Sendable, Equatable, Codable {
    let argv: String

    init(raw: String) throws {
        try assertArgvSafe(raw)
        var rest = raw
        var proto = "tcp"
        if let slash = rest.lastIndex(of: "/") {
            proto = String(rest[rest.index(after: slash)...]).lowercased()
            rest = String(rest[..<slash])
        }
        guard proto == "tcp" || proto == "udp" || proto == "sctp" else {
            throw SpecError.invalid("proto")
        }
        let parts = rest.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        let hostIP: String
        let hostPort: Int
        let containerPort: Int
        switch parts.count {
        case 2:
            hostIP = ""
            hostPort = Int(parts[0]) ?? -1
            containerPort = Int(parts[1]) ?? -1
        case 3:
            hostIP = parts[0]
            hostPort = Int(parts[1]) ?? -1
            containerPort = Int(parts[2]) ?? -1
            try assertIPv4(hostIP)
        default:
            throw SpecError.invalid("port shape")
        }
        guard (1...65535).contains(hostPort), (1...65535).contains(containerPort) else {
            throw SpecError.invalid("port range")
        }
        let bind = hostIP.isEmpty ? "127.0.0.1" : hostIP
        if !allowRemoteBind, !isLoopback(bind) {
            throw SpecError.invalid("remote bind disabled")
        }
        self.argv = "\(bind):\(hostPort):\(containerPort)/\(proto)"
    }

    init(from decoder: Decoder) throws { try self.init(raw: try decoder.singleValueContainer().decode(String.self)) }
    func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(argv) }
}

// MARK: - EnvSpec

/// `KEY=VALUE` (set) or `KEY` (inherit from host). KEY matches
/// `[A-Za-z_][A-Za-z0-9_]*`, so the assembled element cannot start with `-`.
struct EnvSpec: Sendable, Equatable, Codable {
    static let maxEntries = 64
    static let maxValueBytes = 32 * 1024

    let argv: String

    init(raw: String) throws {
        if let eq = raw.firstIndex(of: "=") {
            let key = String(raw[..<eq])
            let val = String(raw[raw.index(after: eq)...])
            try assertEnvKey(key)
            if val.contains("\u{0}") || val.contains("\n") || val.contains("\r") {
                throw SpecError.invalid("env value")
            }
            guard val.utf8.count <= Self.maxValueBytes else { throw SpecError.invalid("env value too long") }
        } else {
            try assertEnvKey(raw)
        }
        self.argv = raw
    }

    init(from decoder: Decoder) throws { try self.init(raw: try decoder.singleValueContainer().decode(String.self)) }
    func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(argv) }
}

private func assertEnvKey(_ k: String) throws {
    guard let r = try? Regex("^[A-Za-z_][A-Za-z0-9_]{0,127}$"), k.wholeMatch(of: r) != nil else {
        throw SpecError.invalid("env key")
    }
}

// MARK: - VolumeSpec

/// Bind/anonymous mount: `source:destination[:ro]` or `destination`. Each path
/// segment must be non-empty with no NUL/newline. (`..` rejection is not a
/// meaningful control here - bind sources are arbitrary host paths by design - so
/// it is not pretended to be one; the host-fs exposure is documented separately.)
struct VolumeSpec: Sendable, Equatable, Codable {
    let argv: String

    init(raw: String) throws {
        try assertArgvSafe(raw)
        let parts = raw.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        switch parts.count {
        case 1:
            try assertPath(parts[0])
        case 2:
            try assertPath(parts[0]); try assertPath(parts[1])
        case 3:
            try assertPath(parts[0]); try assertPath(parts[1])
            guard parts[2] == "ro" else { throw SpecError.invalid("volume option") }
        default:
            throw SpecError.invalid("volume shape")
        }
        self.argv = raw
    }

    init(from decoder: Decoder) throws { try self.init(raw: try decoder.singleValueContainer().decode(String.self)) }
    func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(argv) }
}

private func assertPath(_ s: String) throws {
    guard !s.isEmpty, !s.contains("\u{0}"), !s.contains("\n"), !s.contains("\r") else {
        throw SpecError.invalid("volume path")
    }
}

// MARK: - MemorySpec

/// `<unsigned>[K|M|G|T|P]` (KiB granularity per the CLI).
struct MemorySpec: Sendable, Equatable, Codable {
    let argv: String

    init(raw: String) throws {
        try assertArgvSafe(raw)
        guard let r = try? Regex("^[0-9]+[KMGTPE]?$"), raw.wholeMatch(of: r) != nil else {
            throw SpecError.invalid("memory")
        }
        self.argv = raw
    }

    init(from decoder: Decoder) throws { try self.init(raw: try decoder.singleValueContainer().decode(String.self)) }
    func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(argv) }
}

// MARK: - ContainerRunRequest

/// `POST /api/containers/run` body. Every argv-bound field is validated here.
struct ContainerRunRequest: Codable, Sendable {
    let image: String
    let name: String?
    let entrypoint: String?
    let ports: [PortSpec]
    let env: [EnvSpec]
    let volumes: [VolumeSpec]
    let cpus: Int?
    let memory: MemorySpec?
    let args: [String]
    let rm: Bool?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)

        let image = try c.decode(String.self, forKey: .image)
        guard ImageRefValidator.validate(image) else { throw SpecError.invalid("image") }
        self.image = image

        if let name = try c.decodeIfPresent(String.self, forKey: .name) {
            guard IDValidator.validate(name) else { throw SpecError.invalid("name") }
            self.name = name
        } else { self.name = nil }

        if let ep = try c.decodeIfPresent(String.self, forKey: .entrypoint) {
            guard !ep.contains("\u{0}"), !ep.contains("\n"), !ep.contains("\r"), ep.utf8.count <= 4096 else {
                throw SpecError.invalid("entrypoint")
            }
            self.entrypoint = ep
        } else { self.entrypoint = nil }

        let ports = try c.decodeIfPresent([PortSpec].self, forKey: .ports) ?? []
        guard ports.count <= 64 else { throw SpecError.invalid("too many ports") }
        self.ports = ports

        let env = try c.decodeIfPresent([EnvSpec].self, forKey: .env) ?? []
        guard env.count <= EnvSpec.maxEntries else { throw SpecError.invalid("too many env") }
        self.env = env

        let volumes = try c.decodeIfPresent([VolumeSpec].self, forKey: .volumes) ?? []
        guard volumes.count <= 64 else { throw SpecError.invalid("too many volumes") }
        self.volumes = volumes

        if let cpus = try c.decodeIfPresent(Int.self, forKey: .cpus) {
            guard (1...1024).contains(cpus) else { throw SpecError.invalid("cpus") }
            self.cpus = cpus
        } else { self.cpus = nil }

        self.memory = try c.decodeIfPresent(MemorySpec.self, forKey: .memory)

        let args = try c.decodeIfPresent([String].self, forKey: .args) ?? []
        guard args.count <= 64 else { throw SpecError.invalid("too many args") }
        for a in args {
            guard !a.contains("\u{0}"), !a.contains("\n"), !a.contains("\r"), a.utf8.count <= 4096 else {
                throw SpecError.invalid("arg")
            }
        }
        self.args = args

        self.rm = try c.decodeIfPresent(Bool.self, forKey: .rm)
    }

    private enum Keys: String, CodingKey {
        case image, name, entrypoint, ports, env, volumes, cpus, memory, args, rm
    }
}
