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

struct ContainerRunRequest: Encodable, Sendable {
    let image: String
    let name: String?
    let ports: [Spec]
    let env: [Spec]
    let volumes: [Spec]
    let cpus: Int?
    let memory: Spec?
    let args: [String]
    let rm: Bool?

    /// A single argv element encoded as a bare JSON string.
    struct Spec: RawRepresentable, Encodable, Sendable {
        let rawValue: String
    }
}

struct RunResponse: Decodable, Sendable {
    let id: String
}
