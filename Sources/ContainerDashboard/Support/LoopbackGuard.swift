import Foundation
import Darwin

/// Refuses to boot if the configured bind host does not resolve to loopback only,
/// unless `--allow-remote` is present. Resolves the hostname (macOS `localhost`
/// maps to BOTH `127.0.0.1` and `::1`) rather than string-matching, so a literal
/// `"127.0.0.1"` check would wrongly reject a legitimate loopback bind.
enum LoopbackGuard {
    enum Failure: Error, CustomStringConvertible {
        case notLoopback(String, resolved: [String])
        case unresolvable(String)

        var description: String {
            switch self {
            case .notLoopback(let host, let resolved):
                return "Refusing to bind '\(host)' (resolved: \(resolved)) to a non-loopback address without --allow-remote."
            case .unresolvable(let host):
                return "Could not resolve hostname '\(host)'."
            }
        }
    }

    static func validate(hostname: String, allowRemote: Bool) throws {
        if allowRemote { return }
        let resolved = resolve(hostname)
        guard !resolved.isEmpty else { throw Failure.unresolvable(hostname) }
        for addr in resolved {
            if !isLoopback(addr) {
                throw Failure.notLoopback(hostname, resolved: resolved)
            }
        }
    }

    static func isLoopback(_ addr: String) -> Bool {
        addr == "::1" || addr.hasPrefix("127.") || addr == "localhost"
    }

    /// `getaddrinfo` for the host; returns numeric address strings (e.g. ["127.0.0.1", "::1"]).
    static func resolve(_ host: String) -> [String] {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &res) == 0, let head = res else { return [] }
        defer { freeaddrinfo(head) }
        var out: [String] = []
        var cur: UnsafeMutablePointer<addrinfo>? = head
        while let ai = cur {
            var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(ai.pointee.ai_addr, ai.pointee.ai_addrlen, &buf, socklen_t(buf.count), nil, 0, NI_NUMERICHOST) == 0 {
                out.append(String(cString: buf))
            }
            cur = ai.pointee.ai_next
        }
        return Array(Set(out))
    }
}
