import Darwin
import Foundation

/// Cancels a running `Subprocess.run` from another thread: the child's whole process group is
/// terminated and `run` returns promptly with `cancelled = true`.
public final class CancelToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    /// Self-pipe the runner polls; a byte written here wakes it.
    fileprivate let wakeRead: Int32
    fileprivate let wakeWrite: Int32

    public init() {
        var fds: [Int32] = [-1, -1]
        if pipe(&fds) == 0 {
            _ = fcntl(fds[0], F_SETFD, FD_CLOEXEC)
            _ = fcntl(fds[1], F_SETFD, FD_CLOEXEC)
            _ = fcntl(fds[1], F_SETFL, O_NONBLOCK)
        }
        wakeRead = fds[0]
        wakeWrite = fds[1]
    }

    deinit {
        if wakeRead >= 0 { close(wakeRead) }
        if wakeWrite >= 0 { close(wakeWrite) }
    }

    public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    public func cancel() {
        lock.lock()
        let first = !cancelled
        cancelled = true
        lock.unlock()
        if first, wakeWrite >= 0 {
            var b: UInt8 = 1
            _ = write(wakeWrite, &b, 1)
        }
    }
}

/// Runs a program with an argv array (no shell) and a timeout, in its own process group so a timeout
/// or cancellation also ends anything it started: SIGTERM to the group, then SIGKILL to whatever is
/// left of the group after a 1 s grace, whether or not the pipes are still open. (A descendant that
/// leaves the group with setsid/setpgid is out of reach.) Output is capped so a chatty child can't grow
/// memory without bound. Reads never block past the deadline: a grandchild that keeps the pipes open
/// after the child exited only delays the return by `pipeGrace`.
public enum Subprocess {
    public struct Result: Sendable {
        public var status: Int32
        public var stdout: String
        public var stderr: String
        public var timedOut: Bool
        public var cancelled = false
        public var succeeded: Bool { status == 0 && !timedOut && !cancelled }
    }

    public struct LaunchError: Error, CustomStringConvertible {
        public let description: String
    }

    static let outputCap = 256 * 1024
    static let pipeGrace: TimeInterval = 2

    public static func run(_ executable: String, _ arguments: [String], environment: [String: String]? = nil,
                           timeout: TimeInterval, currentDirectory: URL? = nil, cancel: CancelToken? = nil) throws -> Result {
        var outFDs: [Int32] = [-1, -1], errFDs: [Int32] = [-1, -1]
        guard pipe(&outFDs) == 0 else { throw LaunchError(description: "pipe failed: \(String(cString: strerror(errno)))") }
        guard pipe(&errFDs) == 0 else {
            close(outFDs[0]); close(outFDs[1])
            throw LaunchError(description: "pipe failed: \(String(cString: strerror(errno)))")
        }
        for fd in [outFDs[0], errFDs[0]] { _ = fcntl(fd, F_SETFD, FD_CLOEXEC); _ = fcntl(fd, F_SETFL, O_NONBLOCK) }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, outFDs[1], 1)
        posix_spawn_file_actions_adddup2(&actions, errFDs[1], 2)
        if let dir = currentDirectory { posix_spawn_file_actions_addchdir_np(&actions, dir.path) }

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        // Own process group (pgid = child pid); no inherited descriptors beyond 0–2; default signal
        // dispositions (the caller may ignore SIGINT/SIGPIPE).
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        posix_spawnattr_setpgroup(&attr, 0)
        var all = sigset_t(); sigfillset(&all)
        posix_spawnattr_setsigdefault(&attr, &all)
        var none = sigset_t(); sigemptyset(&none)
        posix_spawnattr_setsigmask(&attr, &none)

        let argv: [UnsafeMutablePointer<CChar>?] = ([executable] + arguments).map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        let envStrings = (environment ?? ProcessInfo.processInfo.environment).map { "\($0.key)=\($0.value)" }
        let envp: [UnsafeMutablePointer<CChar>?] = envStrings.map { strdup($0) } + [nil]
        defer { envp.forEach { free($0) } }

        var pid: pid_t = 0
        let rc = posix_spawn(&pid, executable, &actions, &attr, argv, envp)
        close(outFDs[1]); close(errFDs[1])
        guard rc == 0 else {
            close(outFDs[0]); close(errFDs[0])
            throw LaunchError(description: "could not start \((executable as NSString).lastPathComponent): \(String(cString: strerror(rc)))")
        }

        var out = Data(), err = Data()
        var open: [Int32: Bool] = [outFDs[0]: true, errFDs[0]: false] // fd -> isStdout
        var status: Int32?
        var timedOut = false, cancelled = false
        let start = Proc.nowNs()
        let deadline = start + UInt64(max(0, timeout) * 1e9)
        var graceEnd: UInt64?
        var killStage = 0 // 0 none, 1 TERM sent, 2 KILL sent
        var killAt: UInt64 = 0
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)

        func reap(blocking: Bool) {
            guard status == nil else { return }
            var st: Int32 = 0
            let r = waitpid(pid, &st, blocking ? 0 : WNOHANG)
            if r == pid {
                if (st & 0x7f) == 0 { status = (st >> 8) & 0xff } else { status = 128 + (st & 0x7f) }
            } else if r < 0 && errno == ECHILD {
                status = -1
            }
        }

        func terminateGroup() {
            let now = Proc.nowNs()
            if killStage == 0 {
                killpg(pid, SIGTERM); kill(pid, SIGTERM)
                killStage = 1; killAt = now + 1_000_000_000
            } else if killStage == 1, now >= killAt {
                killpg(pid, SIGKILL); kill(pid, SIGKILL)
                killStage = 2
            }
        }

        while true {
            reap(blocking: false)
            let now = Proc.nowNs()
            if cancel?.isCancelled == true, status == nil || !open.isEmpty { cancelled = true }
            if (cancelled || timedOut) {
                if status == nil || !open.isEmpty { terminateGroup() }
            } else if status == nil, now >= deadline {
                timedOut = true
                terminateGroup()
            }
            if status != nil {
                if open.isEmpty { break }
                if graceEnd == nil { graceEnd = now + UInt64(pipeGrace * 1e9) }
                // Child gone but something still holds the pipes: stop reading after the grace period.
                if now >= graceEnd! || killStage == 2 { break }
            } else if killStage == 2, now >= killAt + 2_000_000_000 {
                // SIGKILL sent and still not reaped after 2 s: block on it (it can't outlive SIGKILL).
                reap(blocking: true)
                continue
            }

            var fds = open.keys.map { pollfd(fd: $0, events: Int16(POLLIN), revents: 0) }
            if let c = cancel, c.wakeRead >= 0, !cancelled { fds.append(pollfd(fd: c.wakeRead, events: Int16(POLLIN), revents: 0)) }
            // Short slices: waitpid is polled, and deadlines are checked between them.
            let r = poll(&fds, nfds_t(fds.count), 50)
            if r < 0 && errno != EINTR { break }
            for p in fds where p.revents != 0 {
                if p.fd == cancel?.wakeRead { cancelled = true; continue }
                guard let isOut = open[p.fd] else { continue }
                while true {
                    let n = read(p.fd, &buffer, buffer.count)
                    if n > 0 {
                        let chunk = buffer.prefix(n)
                        if isOut { if out.count < outputCap { out.append(contentsOf: chunk.prefix(outputCap - out.count)) } }
                        else if err.count < outputCap { err.append(contentsOf: chunk.prefix(outputCap - err.count)) }
                        continue
                    }
                    if n == 0 || (errno != EAGAIN && errno != EINTR) { open[p.fd] = nil; close(p.fd) }
                    break
                }
            }
        }
        for fd in open.keys { close(fd) }
        if status == nil {
            killpg(pid, SIGKILL); kill(pid, SIGKILL)
            reap(blocking: true)
        }
        if killStage > 0 {
            // Timed out or cancelled: the leader may be gone (and the pipes closed) while something it
            // started ignores SIGTERM. Give the group the rest of its grace period, then SIGKILL it.
            while killpg(pid, 0) == 0, Proc.nowNs() < killAt { usleep(20_000) }
            if killpg(pid, 0) == 0 { killpg(pid, SIGKILL) }
        }
        return Result(status: status ?? -1, stdout: String(decoding: out, as: UTF8.self),
                      stderr: String(decoding: err, as: UTF8.self), timedOut: timedOut, cancelled: cancelled)
    }
}
