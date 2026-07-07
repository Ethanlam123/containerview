import Foundation
import Vapor

/// `container machine ls --format json` / `machine inspect <id>`. The live
/// system returned `[]` for both, so the shape is unknown. Fields are filled in
/// during the Phase 11 capture against a real machine; until then this struct
/// decodes the empty-array case and degrades gracefully.
struct MachineList: Content, Sendable {
    let id: String?
    let configuration: Configuration?
    let status: Status?

    struct Configuration: Codable, Sendable {
        let name: String?
        let image: String?
        let resources: Resources?
        let creationDate: String?

        struct Resources: Codable, Sendable {
            let cpus: Int?
            let memoryInBytes: Int64?
        }
    }

    struct Status: Codable, Sendable {
        let state: String?
        let ipv4Address: String?
    }
}
