import Darwin
import Testing
@testable import StatsCore

@Test func portLookupsExcludeInvisibleProcessesAndReportBindErrors() {
    let denied = Proc.Entry(pid: 1, ppid: 0, comm: "other", startSec: 0, startUsec: 0)
    var inspected = 0
    var attempts: [Int32] = []
    func run(_ enabled: Bool, error: Int32) -> FindResult {
        PortLookup.find(443, probeFree: enabled, limit: 1, entries: [denied], visible: { _ in false },
                        listener: { _,_ in inspected += 1; return false },
                        probe: { _, family in attempts.append(family); return error })
    }
    #expect(run(false, error: 0).portState == "unknown")
    #expect(attempts.isEmpty)
    let result = run(true, error: EACCES)
    #expect(result.portState == "unknown" && result.note?.contains("EACCES") == true)
    #expect(attempts == [AF_INET, AF_INET6])
    #expect(run(true, error: EADDRINUSE).portState == "in_use")
    #expect(inspected == 0)
    let own = Proc.Entry(pid: getpid(), ppid: getppid(), comm: "self", startSec: 0, startUsec: 0)
    let callsBefore = attempts.count
    let listening = PortLookup.find(443, probeFree: true, limit: 1, entries: [own], visible: { _ in true },
                                    listener: { _,_ in true }, probe: { _, family in attempts.append(family); return EACCES })
    #expect(listening.portState == "listening" && attempts.count == callsBefore)
}

@Test func wildcardProbesUseFreshNonListeningSocketsWithoutReuse() {
    for family in [AF_INET, AF_INET6] {
        var captured: Int32 = -1
        let code = PortLookup.bindError(0, family: family) { fd, address, size in
            captured = fd
            #expect(Int32(address.pointee.sa_family) == family)
            if family == AF_INET {
                let value = UnsafeRawPointer(address).load(as: sockaddr_in.self)
                #expect(value.sin_addr.s_addr == 0)
            } else {
                var value = UnsafeRawPointer(address).load(as: sockaddr_in6.self)
                #expect(withUnsafeBytes(of: &value.sin6_addr) { $0.allSatisfy { $0 == 0 } })
            }
            for opt in [SO_REUSEADDR, SO_REUSEPORT] {
                var value: Int32 = -1
                var length = socklen_t(MemoryLayout.size(ofValue: value))
                let rc = getsockopt(fd, SOL_SOCKET, opt, &value, &length)
                #expect(rc == 0 && value == 0)
            }
            var socketInfo = socket_fdinfo()
            let bytes = Int32(MemoryLayout.size(ofValue: socketInfo))
            let read = proc_pidfdinfo(getpid(), fd, PROC_PIDFDSOCKETINFO, &socketInfo, bytes)
            #expect(read == bytes && socketInfo.psi.soi_proto.pri_tcp.tcpsi_state != TSI_S_LISTEN)
            return Darwin.bind(fd, address, size)
        }
        #expect(code == 0 && captured >= 0)
    }
}
