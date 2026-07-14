// `POST /api/containers/run` encode body. The server decodes each argv-bound
// field (PortSpec/EnvSpec/VolumeSpec/MemorySpec) via a single-value container,
// i.e. as a bare JSON string, NOT an object. `Spec` is `RawRepresentable<String>`
// so its synthesized Codable uses a single-value container encoding `rawValue`
// as a string - matching the server exactly. A naive `struct { let argv: String }`
// would encode `{"argv":"..."}` and the server would 400.
//
// Optional fields (name/cpus/memory/rm) are omitted when nil (synthesized
// Codable uses encodeIfPresent), matching app.js#gatherCreate.

import Foundation

public struct ContainerRunRequest: Encodable, Sendable {
    public let image: String
    public let name: String?
    public let ports: [Spec]
    public let env: [Spec]
    public let volumes: [Spec]
    public let cpus: Int?
    public let memory: Spec?
    public let args: [String]
    public let rm: Bool?

    public init(image: String, name: String?, ports: [Spec], env: [Spec],
                volumes: [Spec], cpus: Int?, memory: Spec?, args: [String], rm: Bool?) {
        self.image = image; self.name = name
        self.ports = ports; self.env = env; self.volumes = volumes
        self.cpus = cpus; self.memory = memory; self.args = args; self.rm = rm
    }

    /// A single argv element encoded as a bare JSON string.
    public struct Spec: RawRepresentable, Encodable, Sendable {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
    }
}

public struct RunResponse: Decodable, Sendable {
    public let id: String
}
