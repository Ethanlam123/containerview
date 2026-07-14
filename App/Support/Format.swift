// Formatting helpers ported from Resources/Public/api.js.

import Foundation

func formatBytes(_ n: Int64?) -> String {
    guard let n, n != 0 else { return "-" }
    let sign = n < 0 ? "-" : ""
    var v = abs(Double(n))
    let units = ["B", "KB", "MB", "GB", "TB"]
    var i = 0
    while v >= 1024, i < units.count - 1 { v /= 1024; i += 1 }
    let fraction = (v >= 100 || i == 0) ? 0 : 1
    return String(format: "%@%.\(fraction)f %@", sign, v, units[i])
}

func formatPercent(_ p: Double?) -> String {
    guard let p else { return "-" }
    let fraction = p >= 100 ? 0 : 1
    return String(format: "%.\(fraction)f%%", p)
}

func shortHash(_ s: String?, len: Int = 12) -> String {
    guard let s, !s.isEmpty else { return "-" }
    return s.replacingOccurrences(of: "sha256:", with: "").prefix(len).description
}

extension Optional where Wrapped == String {
    var nonEmpty: String? { flatMap { $0.isEmpty ? nil : $0 } }
}

/// Pretty-print raw JSON bytes (for inspect sheets / advanced disclosure).
func prettyJSON(_ data: Data) -> String {
    guard let obj = try? JSONSerialization.jsonObject(with: data),
          let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
          let s = String(data: pretty, encoding: .utf8) else {
        return String(data: data, encoding: .utf8) ?? "(binary)"
    }
    return s
}
