import Foundation

/// Validates container/machine IDs before they reach `Process`. The threat model
/// is path-injection and control-char injection (CommandRunner uses argument
/// arrays, so shell injection is not in scope). IDs are simple identifiers.
enum IDValidator {
    static let pattern = #"^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$"#

    static func validate(_ id: String) -> Bool {
        guard let r = try? Regex(pattern) else { return false }
        return id.wholeMatch(of: r) != nil
    }
}

/// Validates OCI image references passed as a query param (refs contain `:`,
/// `/`, `@` legitimately, so the ID regex must NOT be applied to them). Because
/// `/` would also clash with Vapor path routing, image refs travel as `?name=`.
enum ImageRefValidator {
    static let pattern = #"^[A-Za-z0-9][A-Za-z0-9/:._@-]{0,255}$"#

    static func validate(_ ref: String) -> Bool {
        guard let r = try? Regex(pattern) else { return false }
        return ref.wholeMatch(of: r) != nil
    }
}
