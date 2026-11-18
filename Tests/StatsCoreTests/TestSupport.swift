import Foundation

/// Where this test process keeps its temporary folders: `$TMPDIR` when it is on an external volume,
/// else /Volumes/eyedisk/tmp when that exists (test files stay off the small internal disk), else the
/// system temporary directory. The whole folder is removed when the test process exits.
enum TestTemp {
    nonisolated(unsafe) private static var rootPath: UnsafeMutablePointer<CChar>?

    static let root: URL = {
        let fm = FileManager.default
        var base = fm.temporaryDirectory
        if let t = ProcessInfo.processInfo.environment["TMPDIR"], t.hasPrefix("/Volumes/") {
            base = URL(fileURLWithPath: t, isDirectory: true)
        } else if fm.fileExists(atPath: "/Volumes/eyedisk/tmp") {
            base = URL(fileURLWithPath: "/Volumes/eyedisk/tmp", isDirectory: true)
        }
        let url = base.appendingPathComponent("aistats-tests-\(getpid())", isDirectory: true)
        try? fm.createDirectory(at: url, withIntermediateDirectories: true)
        rootPath = strdup(url.path)
        atexit {
            guard let p = TestTemp.rootPath else { return }
            try? FileManager.default.removeItem(atPath: String(cString: p))
        }
        return url
    }()

    /// A new folder (created unless `create` is false) under `root`.
    static func dir(create: Bool = true) -> URL {
        let url = root.appendingPathComponent("t-\(UUID().uuidString.prefix(12))", isDirectory: true)
        if create { try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        return url
    }
}
