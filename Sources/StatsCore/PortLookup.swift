import Darwin
import Foundation

public enum PortLookup {
    static let visibilityNote = "Listeners of other users are invisible."

    public static func find(_ port: UInt16, probeFree: Bool = false, limit: Int = 8) -> FindResult {
        var result = FindResult(observedAt: Date(), scope: "current_user", selector: "port",
                                processes: [], matched: 0, truncated: false)
        let entries = Proc.currentUserTable()
        result.scanAvailable = entries != nil
        let rows = (entries ?? []).compactMap { entry -> FindResult.Row? in
            guard listens(entry.pid, port: port) else { return nil }
            let row = ProcessFinder.read(pid: entry.pid, ppid: Proc.parent(entry.pid), name: Proc.name(entry.pid), path: nil)
            guard Proc.matches(entry.pid, startSec: entry.startSec, startUsec: entry.startUsec) else { return nil }
            return row
        }.sorted { ($0.footprintBytes ?? 0, $0.pid) > ($1.footprintBytes ?? 0, $1.pid) }
        result.matched = rows.count
        result.processes = Array(rows.prefix(min(ProcessFinder.maxLimit, max(1, limit))))
        result.truncated = rows.count > result.processes.count
        if !rows.isEmpty {
            result.portState = "listening"
        } else {
            result.portState = "unknown"
            result.note = entries == nil ? "Process table unavailable. " + visibilityNote : visibilityNote
            if probeFree {
                let errors = [AF_INET, AF_INET6].map { bindError(port, family: $0) }
                if errors.contains(EADDRINUSE) { result.portState = "in_use" }
                else if let error = errors.first(where: { $0 != 0 }) {
                    result.note = visibilityNote + " Bind: " + (error == EACCES ? "EACCES" : String(cString: strerror(error))) + " (errno " + String(error) + ")."
                } else { result.portState = "free" }
            }
        }
        return result
    }

    private static func listens(_ pid: Int32, port: UInt16) -> Bool {
        let stride = MemoryLayout<proc_fdinfo>.stride
        let estimate = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard estimate > 0 else { return false }
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(estimate) / stride + 32)
        var bytes: Int32
        repeat {
            bytes = fds.withUnsafeMutableBytes {
                proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count))
            }
            if Int(bytes) < fds.count * stride { break }
            fds.append(contentsOf: repeatElement(proc_fdinfo(), count: fds.count))
        } while true
        guard bytes > 0 else { return false }
        for fd in fds.prefix(Int(bytes) / stride) where fd.proc_fdtype == PROX_FDTYPE_SOCKET {
            var socket = socket_fdinfo()
            let size = Int32(MemoryLayout.size(ofValue: socket))
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &socket, size) == size,
                  socket.psi.soi_kind == SOCKINFO_TCP else { continue }
            let tcp = socket.psi.soi_proto.pri_tcp
            if tcp.tcpsi_state == TSI_S_LISTEN,
               UInt16(bigEndian: UInt16(truncatingIfNeeded: tcp.tcpsi_ini.insi_lport)) == port { return true }
        }
        return false
    }

    private static func bindError(_ port: UInt16, family: Int32) -> Int32 {
        let fd = socket(family, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { return errno }
        defer { close(fd) }
        func attempt<T>(_ address: inout T) -> Int32 {
            withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, socklen_t(MemoryLayout<T>.size)) == 0 ? 0 : errno
                }
            }
        }
        if family == AF_INET {
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout.size(ofValue: address))
            address.sin_family = sa_family_t(family)
            address.sin_port = port.bigEndian
            return attempt(&address)
        }
        var address = sockaddr_in6()
        address.sin6_len = UInt8(MemoryLayout.size(ofValue: address))
        address.sin6_family = sa_family_t(family)
        address.sin6_port = port.bigEndian
        return attempt(&address)
    }
}
