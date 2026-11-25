import CryptoKit
import Darwin
import Foundation

// MARK: - AIStats-owned folders

/// Folders AIStats keeps its own files in (locks, backups). Each must be a real directory (never a
/// symlink) owned by this user; one AIStats creates gets mode 0700, an existing one keeps its mode.
enum OwnedDirectory {
    /// Creates `root` (normally, with parents) if missing, then checks or creates each of `dirs` in order.
    static func ensure(_ dirs: [URL], root: URL) throws {
        if !FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        for dir in dirs { try ensure(dir) }
    }

    static func ensure(_ dir: URL) throws {
        var st = stat()
        if lstat(dir.path, &st) != 0 {
            guard errno == ENOENT else { throw ConfigError("can't use \(dir.path): \(String(cString: strerror(errno)))") }
            if mkdir(dir.path, 0o700) == 0 {
                chmod(dir.path, 0o700)
                return
            }
            guard errno == EEXIST, lstat(dir.path, &st) == 0 else {
                throw ConfigError("can't create \(dir.path): \(String(cString: strerror(errno)))")
            }
        }
        try check(dir, st)
    }

    /// True when `dir` exists as a real directory owned by this user.
    static func isOwned(_ dir: URL) -> Bool {
        var st = stat()
        return lstat(dir.path, &st) == 0 && (try? check(dir, st)) != nil
    }

    private static func check(_ dir: URL, _ st: stat) throws {
        guard (st.st_mode & S_IFMT) == S_IFDIR else {
            throw ConfigError("\(dir.path) is not a real folder (a symlink or a file); AIStats keeps its files only in its own folders (left unchanged)")
        }
        guard st.st_uid == geteuid() else {
            throw ConfigError("\(dir.path) is owned by another user; AIStats keeps its files only in its own folders (left unchanged)")
        }
    }
}

// MARK: - Locks

/// An exclusive `flock` on a lock file in AIStats's own folder, acquired with a deadline.
final class FileLock {
    private var fd: Int32

    init(_ url: URL, timeout: TimeInterval) throws {
        let dir = url.deletingLastPathComponent()
        try OwnedDirectory.ensure([dir], root: dir.deletingLastPathComponent())
        fd = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK, 0o600)
        guard fd >= 0 else { throw ConfigError("can't open lock \(url.lastPathComponent): \(String(cString: strerror(errno)))") }
        let end = Date().addingTimeInterval(timeout)
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            if errno != EWOULDBLOCK && errno != EINTR {
                close(fd)
                throw ConfigError("can't lock \(url.lastPathComponent): \(String(cString: strerror(errno)))")
            }
            if Date() >= end {
                close(fd)
                throw ConfigError("another AIStats process is changing this configuration; try again")
            }
            usleep(50_000)
        }
    }

    func release() {
        guard fd >= 0 else { return }
        flock(fd, LOCK_UN)
        close(fd)
        fd = -1
    }

    deinit { release() }
}

// MARK: - Backups

/// Byte-exact copies of config files, kept in one AIStats-owned folder per agent
/// (`$AISTATS_HOME/backups/<agent>/<UTC stamp>[-n]-<file name>`, 0600). Every backup AIStats writes is
/// listed in `manifest.jsonl` there (name, size, SHA-256); pruning only ever deletes a listed file whose
/// content still matches, so other files in the folder are never touched.
struct BackupStore {
    let directory: URL
    let keep: Int

    static let manifestName = "manifest.jsonl"
    var manifestURL: URL { directory.appendingPathComponent(Self.manifestName) }

    struct Record: Codable, Equatable {
        var file: String
        var size: Int
        var sha256: String
        var stamp: String
        var seq: Int
    }

    static func stamp(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return f.string(from: date)
    }

    static func hex(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    /// Writes `contents` to a new file (exclusive create, never overwriting) and lists it in the manifest.
    /// Pruning is separate, so an aborted change can't cost an older backup.
    func create(contents: Data, name: String) throws -> URL {
        let backups = directory.deletingLastPathComponent()
        try OwnedDirectory.ensure([backups, directory], root: backups.deletingLastPathComponent())
        let stamp = Self.stamp()
        let safeName = String(name.map { $0 == "/" || $0 == "\0" ? "_" : $0 }.prefix(100))
        // Numbers within one second only grow, so they keep the order the backups were made in.
        let first = (readManifest().filter { $0.stamp == stamp }.map(\.seq).max() ?? 0) + 1
        for n in first...(first + 1000) {
            let file = n == 1 ? "\(stamp)-\(safeName)" : "\(stamp)-\(n)-\(safeName)"
            let url = directory.appendingPathComponent(file)
            let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
            if fd < 0 {
                if errno == EEXIST { continue }
                throw ConfigError("could not create a backup in \(directory.path): \(String(cString: strerror(errno)))")
            }
            let written = contents.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            let synced = fsync(fd) == 0
            close(fd)
            guard written == contents.count, synced else {
                unlink(url.path)
                throw ConfigError("could not write the backup in \(directory.path)")
            }
            do {
                try append(Record(file: file, size: contents.count, sha256: Self.hex(contents), stamp: stamp, seq: n))
            } catch {
                unlink(url.path)
                throw error
            }
            return url
        }
        throw ConfigError("could not create a backup in \(directory.path): too many backups this second")
    }

    /// Our backups that still exist, newest first.
    func list() -> [URL] { readManifest().reversed().map { directory.appendingPathComponent($0.file) }.filter(Self.isRegular) }

    /// Keeps the newest `keep` listed backups; `except` (the backup just made) is never removed. A listed
    /// file is deleted only if it is still the regular file AIStats wrote (same size and SHA-256);
    /// anything else is dropped from the manifest and left alone.
    func prune(except: URL? = nil) {
        guard OwnedDirectory.isOwned(directory) else { return }
        let all = readManifest()
        let present = all.filter { Self.isRegular(directory.appendingPathComponent($0.file)) }
        var kept: [Record] = []
        for (i, r) in present.enumerated() {
            let url = directory.appendingPathComponent(r.file)
            if i >= present.count - max(0, keep) || url.path == except?.path {
                kept.append(r)
                continue
            }
            if let data = Self.readRegular(url), data.count == r.size, Self.hex(data) == r.sha256 { unlink(url.path) }
        }
        if kept != all { try? rewrite(kept) }
    }

    // MARK: Manifest

    static func isRegular(_ url: URL) -> Bool {
        var st = stat()
        return lstat(url.path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFREG
    }

    /// Contents of a regular file (not following a symlink), nil otherwise.
    static func readRegular(_ url: URL) -> Data? {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_uid == geteuid() else { return nil }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(fd, &buffer, buffer.count)
            if n < 0 { if errno == EINTR { continue }; return nil }
            if n == 0 { return data }
            data.append(buffer, count: n)
        }
    }

    static func validName(_ s: String) -> Bool {
        !s.isEmpty && s != "." && s != ".." && s != manifestName && !s.contains("/") && !s.contains("\0") && !s.hasPrefix(".")
    }

    func readManifest() -> [Record] {
        guard let data = Self.readRegular(manifestURL) else { return [] }
        var seen = Set<String>()
        return data.split(separator: UInt8(ascii: "\n")).compactMap { line in
            guard let r = try? JSONDecoder().decode(Record.self, from: Data(line)), Self.validName(r.file),
                  seen.insert(r.file).inserted else { return nil }
            return r
        }
    }

    private func line(_ r: Record) throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var d = try e.encode(r)
        d.append(UInt8(ascii: "\n"))
        return d
    }

    private func append(_ r: Record) throws {
        let data = try line(r)
        let fd = open(manifestURL.path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw ConfigError("could not record the backup in \(manifestURL.path): \(String(cString: strerror(errno)))") }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_uid == geteuid() else {
            throw ConfigError("\(manifestURL.path) is not AIStats's manifest file")
        }
        let written = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        guard written == data.count, fsync(fd) == 0 else { throw ConfigError("could not record the backup in \(manifestURL.path)") }
    }

    private func rewrite(_ records: [Record]) throws {
        var data = Data()
        for r in records { data.append(try line(r)) }
        let temp = directory.appendingPathComponent(".\(Self.manifestName).\(UUID().uuidString.prefix(8))")
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw ConfigError("could not update \(manifestURL.path)") }
        let written = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        let ok = written == data.count && fsync(fd) == 0
        close(fd)
        guard ok, rename(temp.path, manifestURL.path) == 0 else {
            unlink(temp.path)
            throw ConfigError("could not update \(manifestURL.path)")
        }
    }
}

// MARK: - Reading JSON configs

/// A JSON config's top level, `mcpServers` and the `aistats` entry (with its exact bytes and layout).
struct ConfigDocument {
    var root: [String: Any] = [:]
    var servers: [String: Any] = [:]
    var entry: Any?
    var entrySource: Data?
    var layout: JSONKeyScan.Layout?

    static func isBlank(_ data: Data) -> Bool { data.allSatisfy { $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 } }

    /// Refuses (throws) anything it can't judge unambiguously: invalid JSON (including comments),
    /// a non-object top level or `mcpServers`, and duplicate keys on the way to the entry (parsers disagree
    /// on which one wins).
    static func parse(_ data: Data?, name: String) throws -> ConfigDocument {
        guard let data, !isBlank(data) else { return ConfigDocument() }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            if let stripped = JSONComments.strip(data), stripped != data,
               (try? JSONSerialization.jsonObject(with: stripped)) != nil {
                throw ConfigError("\(name) contains comments, which this file format doesn't allow; AIStats won't edit it (left unchanged)")
            }
            throw ConfigError("\(name) is not valid JSON")
        }
        let layout = try JSONKeyScan.layout(data, name: name)
        var doc = ConfigDocument(root: root, layout: layout)
        if let existing = root["mcpServers"] {
            guard let dict = existing as? [String: Any] else { throw ConfigError("mcpServers in \(name) is not an object") }
            doc.servers = dict
        }
        doc.entry = doc.servers[AgentRegistrar.serverName]
        if doc.entry != nil, let span = layout.entry { doc.entrySource = data.subdata(in: span) }
        return doc
    }
}

/// `//` and `/* */` comments outside double-quoted strings, replaced by spaces (newlines kept) so byte
/// offsets don't move. Nil for an unterminated block comment.
enum JSONComments {
    static func strip(_ data: Data) -> Data? {
        var b = [UInt8](data)
        var i = 0, inString = false
        while i < b.count {
            let c = b[i]
            if inString {
                if c == UInt8(ascii: "\\") { i += 2; continue }
                if c == UInt8(ascii: "\"") { inString = false }
                i += 1
                continue
            }
            if c == UInt8(ascii: "\"") { inString = true; i += 1; continue }
            if c == UInt8(ascii: "/"), i + 1 < b.count, b[i + 1] == UInt8(ascii: "/") {
                while i < b.count, b[i] != 0x0A { b[i] = 0x20; i += 1 }
                continue
            }
            if c == UInt8(ascii: "/"), i + 1 < b.count, b[i + 1] == UInt8(ascii: "*") {
                b[i] = 0x20; b[i + 1] = 0x20; i += 2
                while i + 1 < b.count, !(b[i] == UInt8(ascii: "*") && b[i + 1] == UInt8(ascii: "/")) {
                    if b[i] != 0x0A && b[i] != 0x0D { b[i] = 0x20 }
                    i += 1
                }
                guard i + 1 < b.count else { return nil }
                b[i] = 0x20; b[i + 1] = 0x20; i += 2
                continue
            }
            i += 1
        }
        return Data(b)
    }
}

/// A structural pass over JSON (comments, single quotes, unquoted keys and trailing commas tolerated)
/// that finds duplicate keys in the top-level object, in `mcpServers`, and anywhere inside
/// `mcpServers.aistats`, and records where the top level, `mcpServers` and its members are.
enum JSONKeyScan {
    struct Member {
        var key: String
        var keyStart: Int
        var valueStart: Int
        var valueEnd: Int
    }

    struct Layout {
        /// Offsets of the top-level `{` and `}`.
        var rootOpen = 0, rootClose = 0
        var rootMembers: [Member] = []
        /// The top-level `mcpServers` member, and its object's `{`/`}` offsets if it is an object.
        var servers: Member?
        var serversOpen: Int?, serversClose: Int?
        var serverMembers: [Member] = []
        /// Byte range of the `aistats` entry's value.
        var entry: Range<Int>?
        var entryMember: Member? { serverMembers.first { $0.key == AgentRegistrar.serverName } }
    }

    static func entrySpan(_ data: Data, name: String) throws -> Range<Int>? { try layout(data, name: name).entry }

    static func layout(_ data: Data, name: String, server: String = AgentRegistrar.serverName) throws -> Layout {
        var s = Scanner(b: [UInt8](data), name: name, server: server)
        if s.b.starts(with: [0xEF, 0xBB, 0xBF]) { s.i = 3 }
        try s.value([], depth: 0)
        try s.skip()
        guard s.i == s.b.count else { throw s.malformed() }
        return s.layout
    }

    private struct Scanner {
        let b: [UInt8]
        let name: String
        let server: String
        var i = 0
        var layout = Layout()

        init(b: [UInt8], name: String, server: String) { self.b = b; self.name = name; self.server = server }

        func malformed() -> ConfigError { ConfigError("\(name) could not be checked for duplicate keys (unexpected input at byte \(i))") }

        mutating func skip() throws {
            while i < b.count {
                switch b[i] {
                case 0x20, 0x09, 0x0A, 0x0D: i += 1
                case UInt8(ascii: "/") where i + 1 < b.count && b[i + 1] == UInt8(ascii: "/"):
                    while i < b.count && b[i] != 0x0A { i += 1 }
                case UInt8(ascii: "/") where i + 1 < b.count && b[i + 1] == UInt8(ascii: "*"):
                    i += 2
                    while i + 1 < b.count && !(b[i] == UInt8(ascii: "*") && b[i + 1] == UInt8(ascii: "/")) { i += 1 }
                    guard i + 1 < b.count else { throw malformed() }
                    i += 2
                default: return
                }
            }
        }

        mutating func value(_ path: [String], depth: Int) throws {
            guard depth < 256 else { throw malformed() }
            try skip()
            guard i < b.count else { throw malformed() }
            switch b[i] {
            case UInt8(ascii: "{"): try object(path, depth: depth)
            case UInt8(ascii: "["):
                i += 1
                while true {
                    try skip()
                    guard i < b.count else { throw malformed() }
                    if b[i] == UInt8(ascii: "]") { i += 1; return }
                    try value(path + ["[]"], depth: depth + 1)
                    try skip()
                    guard i < b.count else { throw malformed() }
                    if b[i] == UInt8(ascii: ",") { i += 1; continue }
                    if b[i] == UInt8(ascii: "]") { i += 1; return }
                    throw malformed()
                }
            case UInt8(ascii: "\""), UInt8(ascii: "'"): _ = try string()
            default:
                let start = i
                while i < b.count, !Self.isDelimiter(b[i]) { i += 1 }
                guard i > start else { throw malformed() }
            }
        }

        static func isDelimiter(_ c: UInt8) -> Bool {
            [UInt8(ascii: ","), UInt8(ascii: "}"), UInt8(ascii: "]"), UInt8(ascii: ":"), UInt8(ascii: "/"), 0x20, 0x09, 0x0A, 0x0D].contains(c)
        }

        mutating func object(_ path: [String], depth: Int) throws {
            let open = i
            i += 1
            let isRoot = path.isEmpty && depth == 0, isServers = path == ["mcpServers"] && depth == 1
            if isRoot { layout.rootOpen = open }
            if isServers { layout.serversOpen = open }
            let watched = isRoot || isServers || (path.count >= 2 && path[0] == "mcpServers" && path[1] == server)
            var keys = Set<String>()
            while true {
                try skip()
                guard i < b.count else { throw malformed() }
                if b[i] == UInt8(ascii: "}") { close(isRoot, isServers); i += 1; return }
                let keyStart = i
                let key: String
                if b[i] == UInt8(ascii: "\"") || b[i] == UInt8(ascii: "'") {
                    key = try string()
                } else {
                    let start = i
                    while i < b.count, !Self.isDelimiter(b[i]) { i += 1 }
                    guard i > start else { throw malformed() }
                    key = String(decoding: b[start..<i], as: UTF8.self)
                }
                if watched, !keys.insert(key).inserted {
                    let where_ = path.isEmpty ? "the top level" : path.joined(separator: ".")
                    throw ConfigError("\(name) has the key \"\(String(key.prefix(64)))\" twice in \(where_); remove the duplicate first (left unchanged)")
                }
                try skip()
                guard i < b.count, b[i] == UInt8(ascii: ":") else { throw malformed() }
                i += 1
                try skip()
                let start = i
                try value(path + [key], depth: depth + 1)
                let member = Member(key: key, keyStart: keyStart, valueStart: start, valueEnd: i)
                if isRoot {
                    layout.rootMembers.append(member)
                    if key == "mcpServers" { layout.servers = member }
                }
                if isServers {
                    layout.serverMembers.append(member)
                    if key == server { layout.entry = start..<i }
                }
                try skip()
                guard i < b.count else { throw malformed() }
                if b[i] == UInt8(ascii: ",") { i += 1; continue }
                if b[i] == UInt8(ascii: "}") { close(isRoot, isServers); i += 1; return }
                throw malformed()
            }
        }

        mutating func close(_ isRoot: Bool, _ isServers: Bool) {
            if isRoot { layout.rootClose = i }
            if isServers { layout.serversClose = i }
        }

        /// A quoted string at `i`, decoded (escapes resolved for double-quoted strings).
        mutating func string() throws -> String {
            let quote = b[i], start = i
            var escaped = false
            i += 1
            while i < b.count {
                if b[i] == UInt8(ascii: "\\") { escaped = true; i += 2; continue }
                if b[i] == quote {
                    i += 1
                    let inner = b[(start + 1)..<(i - 1)]
                    guard escaped else { return String(decoding: inner, as: UTF8.self) }
                    if quote == UInt8(ascii: "\""),
                       let s = try? JSONSerialization.jsonObject(with: Data(b[start..<i]), options: [.fragmentsAllowed]) as? String {
                        return s
                    }
                    return String(decoding: inner, as: UTF8.self)
                }
                i += 1
            }
            throw malformed()
        }
    }
}

// MARK: - JSON config edits (Claude Desktop, Cursor)

/// A JSON value AIStats writes, with its keys in the order they are written.
indirect enum JSONText: Equatable {
    case string(String)
    case array([JSONText])
    case object([Pair])

    struct Pair: Equatable { var key: String; var value: JSONText }

    var any: Any {
        switch self {
        case .string(let s): return s
        case .array(let a): return a.map(\.any)
        case .object(let o): return Dictionary(o.map { ($0.key, $0.value.any) }, uniquingKeysWith: { _, b in b })
        }
    }

    static func encode(_ s: String) -> String {
        let d = (try? JSONSerialization.data(withJSONObject: s, options: [.fragmentsAllowed, .withoutEscapingSlashes])) ?? Data("\"\"".utf8)
        return String(decoding: d, as: UTF8.self)
    }

    /// Objects one member per line when `multiline` (arrays always inline); `indent` is the line's indent.
    func render(indent: String, unit: String, multiline: Bool, newline: String) -> String {
        switch self {
        case .string(let s): return Self.encode(s)
        case .array(let a):
            return "[" + a.map { $0.render(indent: indent, unit: unit, multiline: false, newline: newline) }.joined(separator: ", ") + "]"
        case .object(let o):
            guard multiline, !o.isEmpty else {
                return "{" + o.map { Self.encode($0.key) + ": " + $0.value.render(indent: "", unit: unit, multiline: false, newline: newline) }
                    .joined(separator: ", ") + "}"
            }
            let inner = indent + unit
            return "{" + newline + o.map {
                inner + Self.encode($0.key) + ": " + $0.value.render(indent: inner, unit: unit, multiline: true, newline: newline)
            }.joined(separator: "," + newline) + newline + indent + "}"
        }
    }
}

/// Text edits that change only the `mcpServers.aistats` member: every byte outside the spliced range is
/// kept exactly (other keys, numbers, spacing, even duplicate keys elsewhere).
enum JSONSplice {
    struct Edit { var range: Range<Int>; var text: String }

    static func apply(_ data: Data, _ e: Edit) -> Data {
        var out = Data(data[data.startIndex..<(data.startIndex + e.range.lowerBound)])
        out.append(Data(e.text.utf8))
        out.append(data[(data.startIndex + e.range.upperBound)...])
        return out
    }

    /// Spaces/tabs before `pos` back to the start of its line, or nil if anything else is on that line first.
    static func lineIndent(_ b: [UInt8], _ pos: Int) -> String? {
        var j = pos
        while j > 0, b[j - 1] == 0x20 || b[j - 1] == 0x09 { j -= 1 }
        guard j == 0 || b[j - 1] == 0x0A else { return nil }
        return String(decoding: b[j..<pos], as: UTF8.self)
    }

    static let key = JSONText.encode(AgentRegistrar.serverName) + ": "

    /// A complete new file holding only the entry.
    static func newFile(_ value: JSONText) -> Data {
        let entry = value.render(indent: "    ", unit: "  ", multiline: true, newline: "\n")
        return Data("{\n  \"mcpServers\": {\n    \(key)\(entry)\n  }\n}\n".utf8)
    }

    /// Sets the entry: replaces its value, or inserts it as the last member of `mcpServers` (or adds
    /// `mcpServers` as the last top-level member), following the file's newline and indentation style.
    static func set(_ data: Data, _ l: JSONKeyScan.Layout, _ value: JSONText) -> Edit {
        let b = [UInt8](data)
        let nl = data.range(of: Data("\r\n".utf8)) != nil ? "\r\n" : "\n"
        let multiline = b[l.rootOpen...l.rootClose].contains(0x0A)
        let unit: String = {
            if let first = l.rootMembers.first, let ind = lineIndent(b, first.keyStart), !ind.isEmpty { return ind }
            return "  "
        }()
        func render(_ indent: String) -> String { value.render(indent: indent, unit: unit, multiline: multiline, newline: nl) }

        if let span = l.entry {
            let indent = l.entryMember.flatMap { lineIndent(b, $0.keyStart) } ?? unit + unit
            return Edit(range: span, text: render(indent))
        }
        if let servers = l.servers, let open = l.serversOpen, let close = l.serversClose {
            let serversIndent = lineIndent(b, servers.keyStart) ?? unit
            if let last = l.serverMembers.last {
                let indent = lineIndent(b, last.keyStart) ?? serversIndent + unit
                return Edit(range: last.valueEnd..<last.valueEnd, text: "," + (multiline ? nl + indent : " ") + key + render(indent))
            }
            let indent = serversIndent + unit
            return Edit(range: (open + 1)..<close,
                        text: multiline ? nl + indent + key + render(indent) + nl + serversIndent : key + render(indent))
        }
        func serversText(_ indent: String) -> String {
            let inner = indent + unit
            return "\"mcpServers\": " + (multiline ? "{" + nl + inner + key + render(inner) + nl + indent + "}" : "{" + key + render(inner) + "}")
        }
        if let last = l.rootMembers.last {
            let indent = lineIndent(b, last.keyStart) ?? unit
            return Edit(range: last.valueEnd..<last.valueEnd, text: "," + (multiline ? nl + indent : " ") + serversText(indent))
        }
        return Edit(range: (l.rootOpen + 1)..<l.rootClose, text: multiline ? nl + unit + serversText(unit) + nl : serversText(unit))
    }

    /// Removes the entry member together with its separating comma.
    static func remove(_ l: JSONKeyScan.Layout) -> Edit? {
        guard let open = l.serversOpen, let close = l.serversClose,
              let idx = l.serverMembers.firstIndex(where: { $0.key == AgentRegistrar.serverName }) else { return nil }
        let m = l.serverMembers
        if m.count == 1 { return Edit(range: (open + 1)..<close, text: "") }
        if idx < m.count - 1 { return Edit(range: m[idx].keyStart..<m[idx + 1].keyStart, text: "") }
        return Edit(range: m[idx - 1].valueEnd..<m[idx].valueEnd, text: "")
    }
}

enum JSONConfigEditor {
    enum Decision { case keep, remove, set(JSONText) }
    struct Result { var changed: Bool; var backup: URL?; var target: URL }

    /// File identity and content: any change to it (including permissions, or a replacement by rename)
    /// makes the edit stop.
    struct Fingerprint: Equatable {
        var dev: Int32; var ino: UInt64; var mode: UInt16; var size: Int64; var mtimeSec: Int; var mtimeNsec: Int; var hash: Data
    }

    /// Test hooks by config path: run after the new file and the backup are written, right before the
    /// final check. Keyed by path so tests running in parallel don't see each other's hooks.
    nonisolated(unsafe) private static var commitHooks: [String: (URL) -> Void] = [:]
    private static let hookLock = NSLock()

    static func beforeCommit(_ path: String, _ hook: ((URL) -> Void)?) {
        hookLock.lock(); defer { hookLock.unlock() }
        commitHooks[path] = hook
    }

    /// Changes only `mcpServers.aistats` of a JSON config, as a text edit of that member:
    /// lock → read → `decide` on exactly those bytes → splice → check the result → backup of the bytes
    /// read → temp file (same mode) → final check that the file (and a symlink's target) is unchanged →
    /// rename. Anything unexpected stops the edit with the file untouched. A symlinked config is resolved
    /// once; the real file is edited.
    @discardableResult
    static func edit(_ url: URL, lockDirectory: URL, backups: BackupStore,
                     decide: (_ entry: Any?, _ source: Data?) throws -> Decision) throws -> Result {
        let fm = FileManager.default
        let target = try resolve(url)
        let dir = target.deletingLastPathComponent()
        let lock = try FileLock(lockDirectory.appendingPathComponent("json-\(RegistrationEntry.fingerprint(Data(target.path.utf8))).lock"), timeout: 10)
        defer { lock.release() }

        let original = try AgentRegistrar.readConfigData(target)
        let before = original.flatMap { fingerprint(target, data: $0) }
        if original != nil, before == nil { throw ConfigError("\(target.lastPathComponent) changed while it was being read; try again (left unchanged)") }
        let name = target.lastPathComponent
        let doc = try ConfigDocument.parse(original, name: name)
        let data: Data
        let intended: Any?
        switch try decide(doc.entry, doc.entrySource) {
        case .keep: return Result(changed: false, backup: nil, target: target)
        case .remove:
            guard doc.entry != nil, let original, let layout = doc.layout, let e = JSONSplice.remove(layout) else {
                return Result(changed: false, backup: nil, target: target)
            }
            data = JSONSplice.apply(original, e)
            intended = nil
        case .set(let value):
            if let original, let layout = doc.layout {
                data = JSONSplice.apply(original, JSONSplice.set(original, layout, value))
            } else {
                data = JSONSplice.newFile(value)
            }
            intended = value.any
        }
        try verify(data, from: doc, intended: intended, name: name)

        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        let mode = before.map { mode_t($0.mode) & 0o7777 } ?? 0o600
        let backup = try original.map { try backups.create(contents: $0, name: name) }
        let temp = dir.appendingPathComponent(".\(name).aistats-\(UUID().uuidString.prefix(8))")
        func abort(_ message: String) -> ConfigError {
            unlink(temp.path)
            if let backup { unlink(backup.path) }
            return ConfigError(message)
        }
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else {
            if let backup { unlink(backup.path) }
            throw ConfigError("could not write in \(dir.path): \(String(cString: strerror(errno))) (left unchanged)")
        }
        let written = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        let ok = written == data.count && fchmod(fd, mode) == 0 && fsync(fd) == 0
        close(fd)
        guard ok else { throw abort("could not write in \(dir.path) (left unchanged)") }

        hookLock.lock()
        let hook = commitHooks[target.path]
        hookLock.unlock()
        hook?(target)
        let changed = "\(name) changed while it was being edited; try again (left unchanged)"
        // The config path must still lead to the file we read, and that file must be exactly as read.
        guard (try? resolve(url)) == target else { throw abort("\(url.lastPathComponent) now points somewhere else; try again (left unchanged)") }
        if original == nil {
            // Create only if still absent.
            guard renamex_np(temp.path, target.path, UInt32(RENAME_EXCL)) == 0 else {
                throw abort(errno == EEXIST ? changed : "could not create \(name): \(String(cString: strerror(errno))) (left unchanged)")
            }
        } else {
            guard fingerprint(target, data: nil) == before else { throw abort(changed) }
            guard rename(temp.path, target.path) == 0 else {
                throw abort("could not replace \(name): \(String(cString: strerror(errno))) (left unchanged)")
            }
        }
        backups.prune(except: backup)
        return Result(changed: true, backup: backup, target: target)
    }

    /// The edited bytes must parse, hold exactly the intended entry (or none), and keep every other
    /// top-level key and every other server as they were.
    static func verify(_ data: Data, from doc: ConfigDocument, intended: Any?, name: String) throws {
        let fail = ConfigError("internal error: the edit of \(name) did not check out (left unchanged)")
        guard let after = try? ConfigDocument.parse(data, name: name) else { throw fail }
        func same(_ a: Any?, _ b: Any?) -> Bool {
            switch (a, b) {
            case (nil, nil): return true
            case let (x?, y?): return NSArray(object: x).isEqual(NSArray(object: y))
            default: return false
            }
        }
        guard same(after.entry, intended) else { throw fail }
        var r0 = doc.root, r1 = after.root
        r0["mcpServers"] = nil; r1["mcpServers"] = nil
        var s0 = doc.servers, s1 = after.servers
        s0[AgentRegistrar.serverName] = nil; s1[AgentRegistrar.serverName] = nil
        guard same(r0, r1), same(s0, s1) else { throw fail }
    }

    /// A symlinked config resolves (once) to its real file, which must be a regular file owned by us.
    static func resolve(_ url: URL) throws -> URL {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return url } // new file
        if (st.st_mode & S_IFMT) == S_IFLNK {
            guard let real = AgentRegistrar.realPath(url.path) else {
                throw ConfigError("\(url.lastPathComponent) is a broken symlink (left unchanged)")
            }
            var rst = stat()
            guard stat(real, &rst) == 0, (rst.st_mode & S_IFMT) == S_IFREG, rst.st_uid == geteuid() else {
                throw ConfigError("\(url.lastPathComponent) links to a file that isn't a regular file owned by you (left unchanged)")
            }
            return URL(fileURLWithPath: real)
        }
        guard (st.st_mode & S_IFMT) == S_IFREG else { throw ConfigError("\(url.lastPathComponent) is not a regular file (left unchanged)") }
        guard st.st_uid == geteuid() else { throw ConfigError("\(url.lastPathComponent) is owned by another user (left unchanged)") }
        return url
    }

    /// Identity, permissions, size, modification time and content hash (`data` if already read, else read now).
    static func fingerprint(_ url: URL, data: Data?) -> Fingerprint? {
        var st = stat()
        guard lstat(url.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { return nil }
        guard let content = data ?? (try? Data(contentsOf: url)) else { return nil }
        return Fingerprint(dev: st.st_dev, ino: st.st_ino, mode: st.st_mode, size: Int64(st.st_size),
                           mtimeSec: st.st_mtimespec.tv_sec, mtimeNsec: st.st_mtimespec.tv_nsec,
                           hash: Data(SHA256.hash(data: content)))
    }
}

// MARK: - Codex TOML (what `codex mcp get` doesn't show)

/// Finds the statements of Codex's config.toml that define `mcp_servers.aistats` (table headers and
/// key/value lines, any spelling of the keys), so the fingerprint covers settings `codex mcp get --json`
/// doesn't print (e.g. `required`) and ownership can see them. Nil when the file can't be analyzed.
enum CodexTOMLScan {
    struct Result {
        /// Exact text of every statement that defines part of the entry, in file order, newline-joined.
        var source: Data
        /// Settings of the entry other than `command`, `args` and `env.AISTATS_MANAGED`.
        var extras: [String]
        var defined: Bool
    }

    static let allowed: Set<[String]> = [["command"], ["args"], ["env", AgentRegistrar.marker.key]]

    static func scan(_ data: Data, server: String = AgentRegistrar.serverName) -> Result? {
        var s = Scanner(b: [UInt8](data))
        if s.b.starts(with: [0xEF, 0xBB, 0xBF]) { s.i = 3 }
        let entry = ["mcp_servers", server]
        var table: [String] = []
        var result = Result(source: Data(), extras: [], defined: false)
        func add(_ range: Range<Int>) {
            if !result.source.isEmpty { result.source.append(0x0A) }
            result.source.append(contentsOf: s.b[range])
            result.defined = true
        }
        do {
            while true {
                s.skipTrivia(newlines: true)
                guard s.i < s.b.count else { break }
                let start = s.i
                if s.b[s.i] == UInt8(ascii: "[") {
                    let array = s.i + 1 < s.b.count && s.b[s.i + 1] == UInt8(ascii: "[")
                    s.i += array ? 2 : 1
                    s.skipTrivia(newlines: false)
                    let path = try s.keyPath()
                    s.skipTrivia(newlines: false)
                    try s.expect("]")
                    if array { try s.expect("]") }
                    let end = s.i
                    try s.endOfLine()
                    table = path
                    if path.starts(with: entry) {
                        add(start..<end)
                        if array { result.extras.append(path.dropFirst(2).joined(separator: ".") + "[]") }
                    } else if array, entry.starts(with: path) {
                        return nil // [[mcp_servers]] — not a shape Codex accepts
                    }
                    continue
                }
                let key = try s.keyPath()
                s.skipTrivia(newlines: false)
                try s.expect("=")
                s.skipTrivia(newlines: false)
                let valueStart = s.i
                try s.skipValue(depth: 0)
                let end = s.i
                try s.endOfLine()
                let full = table + key
                let inline = s.b[valueStart] == UInt8(ascii: "{")
                if full.starts(with: entry) {
                    add(start..<end)
                    let rel = Array(full.dropFirst(2))
                    if inline || !allowed.contains(rel) {
                        result.extras.append(rel.isEmpty ? "(inline table)" : rel.joined(separator: ".") + (inline ? " (inline table)" : ""))
                    }
                } else if entry.starts(with: full), inline, s.b[valueStart..<end].contains(subsequence: Array(server.utf8)) {
                    // `mcp_servers = { aistats = … }`: defined, but not analyzed further.
                    add(start..<end)
                    result.extras.append("(inline table)")
                }
            }
        } catch {
            return nil
        }
        return result
    }

    private struct Scanner {
        let b: [UInt8]
        var i = 0
        struct Bad: Error {}

        init(b: [UInt8]) { self.b = b }

        mutating func skipTrivia(newlines: Bool) {
            while i < b.count {
                let c = b[i]
                if c == 0x20 || c == 0x09 { i += 1 }
                else if newlines, c == 0x0A || c == 0x0D { i += 1 }
                else if c == UInt8(ascii: "#") { while i < b.count, b[i] != 0x0A { i += 1 } }
                else { return }
            }
        }

        mutating func expect(_ c: Character) throws {
            guard i < b.count, b[i] == c.asciiValue! else { throw Bad() }
            i += 1
        }

        /// Only spaces, a comment and a newline (or the end) may follow a statement.
        mutating func endOfLine() throws {
            skipTrivia(newlines: false)
            if i == b.count { return }
            if b[i] == 0x0A { i += 1; return }
            if b[i] == 0x0D, i + 1 < b.count, b[i + 1] == 0x0A { i += 2; return }
            throw Bad()
        }

        static func isBare(_ c: UInt8) -> Bool {
            (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == UInt8(ascii: "_") || c == UInt8(ascii: "-")
        }

        mutating func keyPath() throws -> [String] {
            var parts: [String] = []
            while true {
                skipTrivia(newlines: false)
                guard i < b.count else { throw Bad() }
                if b[i] == UInt8(ascii: "\"") { parts.append(try basicString()) }
                else if b[i] == UInt8(ascii: "'") { parts.append(try literalString()) }
                else {
                    let start = i
                    while i < b.count, Self.isBare(b[i]) { i += 1 }
                    guard i > start else { throw Bad() }
                    parts.append(String(decoding: b[start..<i], as: UTF8.self))
                }
                skipTrivia(newlines: false)
                guard i < b.count, b[i] == UInt8(ascii: ".") else { return parts }
                i += 1
            }
        }

        /// `"…"` on one line, escapes decoded.
        mutating func basicString() throws -> String {
            i += 1
            var out: [UInt8] = []
            while i < b.count {
                let c = b[i]
                if c == 0x0A { throw Bad() }
                if c == UInt8(ascii: "\"") { i += 1; return String(decoding: out, as: UTF8.self) }
                if c == UInt8(ascii: "\\") {
                    guard i + 1 < b.count else { throw Bad() }
                    let e = b[i + 1]
                    i += 2
                    switch e {
                    case UInt8(ascii: "\""): out.append(e)
                    case UInt8(ascii: "\\"): out.append(e)
                    case UInt8(ascii: "b"): out.append(0x08)
                    case UInt8(ascii: "t"): out.append(0x09)
                    case UInt8(ascii: "n"): out.append(0x0A)
                    case UInt8(ascii: "f"): out.append(0x0C)
                    case UInt8(ascii: "r"): out.append(0x0D)
                    case UInt8(ascii: "e"): out.append(0x1B)
                    case UInt8(ascii: "u"), UInt8(ascii: "U"):
                        let n = e == UInt8(ascii: "u") ? 4 : 8
                        guard i + n <= b.count, let v = UInt32(String(decoding: b[i..<(i + n)], as: UTF8.self), radix: 16),
                              let scalar = Unicode.Scalar(v) else { throw Bad() }
                        out.append(contentsOf: Array(String(Character(scalar)).utf8))
                        i += n
                    default: throw Bad()
                    }
                    continue
                }
                out.append(c)
                i += 1
            }
            throw Bad()
        }

        mutating func literalString() throws -> String {
            i += 1
            let start = i
            while i < b.count, b[i] != UInt8(ascii: "'") {
                if b[i] == 0x0A { throw Bad() }
                i += 1
            }
            guard i < b.count else { throw Bad() }
            i += 1
            return String(decoding: b[start..<(i - 1)], as: UTF8.self)
        }

        func at(_ s: String) -> Bool { b[i...].starts(with: Array(s.utf8)) }

        /// Skips `"""…"""` / `'''…'''` (the closing run may hold up to two extra quotes).
        mutating func multiline(_ quote: UInt8, escapes: Bool) throws {
            i += 3
            while i < b.count {
                if escapes, b[i] == UInt8(ascii: "\\") { i += 2; continue }
                if b[i] == quote, i + 2 < b.count, b[i + 1] == quote, b[i + 2] == quote {
                    i += 3
                    var extra = 0
                    while extra < 2, i < b.count, b[i] == quote { i += 1; extra += 1 }
                    return
                }
                i += 1
            }
            throw Bad()
        }

        mutating func skipValue(depth: Int) throws {
            guard depth < 64, i < b.count else { throw Bad() }
            switch b[i] {
            case UInt8(ascii: "\""):
                if at("\"\"\"") { try multiline(UInt8(ascii: "\""), escapes: true) } else { _ = try basicString() }
            case UInt8(ascii: "'"):
                if at("'''") { try multiline(UInt8(ascii: "'"), escapes: false) } else { _ = try literalString() }
            case UInt8(ascii: "["):
                i += 1
                while true {
                    skipTrivia(newlines: true)
                    guard i < b.count else { throw Bad() }
                    if b[i] == UInt8(ascii: "]") { i += 1; return }
                    try skipValue(depth: depth + 1)
                    skipTrivia(newlines: true)
                    guard i < b.count else { throw Bad() }
                    if b[i] == UInt8(ascii: ",") { i += 1; continue }
                    if b[i] == UInt8(ascii: "]") { i += 1; return }
                    throw Bad()
                }
            case UInt8(ascii: "{"):
                i += 1
                while true {
                    skipTrivia(newlines: true)
                    guard i < b.count else { throw Bad() }
                    if b[i] == UInt8(ascii: "}") { i += 1; return }
                    _ = try keyPath()
                    skipTrivia(newlines: false)
                    try expect("=")
                    skipTrivia(newlines: false)
                    try skipValue(depth: depth + 1)
                    skipTrivia(newlines: true)
                    guard i < b.count else { throw Bad() }
                    if b[i] == UInt8(ascii: ",") { i += 1; continue }
                    if b[i] == UInt8(ascii: "}") { i += 1; return }
                    throw Bad()
                }
            default:
                // Numbers, booleans, dates; a date-time may use a space before the time.
                let start = i
                func bare() { while i < b.count, !" \t\r\n,]}#".utf8.contains(b[i]) { i += 1 } }
                bare()
                guard i > start else { throw Bad() }
                let token = b[start..<i]
                if token.count == 10, token[token.startIndex + 4] == UInt8(ascii: "-"), i + 1 < b.count, b[i] == 0x20,
                   b[i + 1] >= 0x30, b[i + 1] <= 0x39 {
                    i += 1
                    bare()
                }
            }
        }
    }
}

extension Sequence where Element == UInt8 {
    /// True if the bytes contain `needle` as a contiguous run.
    func contains(subsequence needle: [UInt8]) -> Bool {
        let hay = Array(self)
        guard !needle.isEmpty, hay.count >= needle.count else { return needle.isEmpty }
        for start in 0...(hay.count - needle.count) where hay[start..<(start + needle.count)].elementsEqual(needle) { return true }
        return false
    }
}
