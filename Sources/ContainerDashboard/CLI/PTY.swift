import Foundation
import Darwin

/// POSIX pseudo-terminal helpers. All fd ownership is explicit: the caller is
/// the sole owner of both returned fds and must `close()` each. `FileHandle` on
/// macOS does not own its fd, so nothing else closes them.
enum PTY {
    enum OpenError: Error, Equatable {
        case openpt, grantpt, unlockpt, ptsname, openSlave
    }

    /// Open a master/slave PTY pair and return `(master, slave, slavePath)`.
    /// Uses `ptsname_r` (thread-safe); `ptsname` writes a shared static buffer
    /// and races between concurrent opens.
    static func openMaster() throws -> (master: Int32, slave: Int32, slavePath: String) {
        let master = posix_openpt(O_RDWR | O_NOCTTY)
        guard master >= 0 else { throw OpenError.openpt }
        guard grantpt(master) == 0 else { close(master); throw OpenError.grantpt }
        guard unlockpt(master) == 0 else { close(master); throw OpenError.unlockpt }
        var buf = [CChar](repeating: 0, count: 1024)
        guard ptsname_r(master, &buf, buf.count) == 0 else { close(master); throw OpenError.ptsname }
        // ptsname_r writes a NUL-terminated path into the zero-padded buffer;
        // truncate at the first NUL before decoding (String(cString:) on [CChar]
        // is deprecated, and the raw decode would include the padding).
        let path = String(decoding: buf.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
        let slave = open(path, O_RDWR | O_NOCTTY)
        guard slave >= 0 else { close(master); throw OpenError.openSlave }
        return (master, slave, path)
    }

    /// Set the slave's window size via `TIOCSWINSZ`. Best-effort (ioctl result
    /// ignored): a failure leaves the default size, not a hard error.
    static func setWinsize(_ fd: Int32, rows: UInt16, cols: UInt16) {
        var ws = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(fd, TIOCSWINSZ, &ws)
    }
}
