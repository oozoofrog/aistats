import Darwin
import Foundation
import StatsCore
import Testing
@testable import AIStatsMenu

private let bootOnly = [StorageMount(path: "/", local: true)]

/// A fixture folder with no symbolic link in its path, on the external scratch volume when one is set.
private func fixture() throws -> URL {
    var base = FileManager.default.temporaryDirectory
    if let t = ProcessInfo.processInfo.environment["TMPDIR"], t.hasPrefix("/Volumes/") { base = URL(fileURLWithPath: t, isDirectory: true) }
    let url = base.appendingPathComponent("aistats-storage-\(UUID().uuidString.prefix(12))", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return URL(fileURLWithPath: try #require(realpath(url.path, nil).map { p in defer { free(p) }; return String(cString: p) }), isDirectory: true)
}

private func file(_ url: URL, _ bytes: Int) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    var data = Data(count: bytes)
    data.withUnsafeMutableBytes { arc4random_buf($0.baseAddress, bytes) }
    try data.write(to: url)
}

private func dir(_ url: URL) throws { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }

private func environment(home: URL, aistats: URL, preference: Any? = nil, mounts: [StorageMount] = bootOnly,
                         now: @escaping () -> Date = Date.init, cpu: @escaping () -> TimeInterval = { 0 },
                         process: @escaping () -> TimeInterval? = { nil }, onEntry: @escaping () -> Void = {}) -> StorageEnvironment {
    StorageEnvironment(home: home.path, aistatsHome: aistats, now: now, threadCPU: cpu, processCPU: process,
                       preference: { preference }, mounts: { mounts }, macOSMajor: 27, onEntry: onEntry)
}

private func run(_ env: StorageEnvironment) throws -> StorageReport {
    let pass = StoragePass(env)
    for _ in 0..<10_000 where pass.slice() { break }
    return try #require(pass.report)
}

private func encoded(_ report: StorageReport) -> String {
    String(decoding: try! JSONEncoder().encode(report), as: UTF8.self)
}

final class VirtualTimeline: StorageTimeline {
    var current: Date
    private var events: [(at: Date, seq: Int, block: () -> Void)] = []
    private var seq = 0
    private var cancelled = Set<Int>()
    /// Start and end of every event that advanced the clock (a slice that walked entries).
    private(set) var slices: [(start: Date, end: Date)] = []

    init(_ start: Date) { current = start }

    func now() -> Date { current }

    func after(_ delay: TimeInterval, _ block: @escaping () -> Void) -> () -> Void {
        seq += 1
        let id = seq
        events.append((current.addingTimeInterval(max(0, delay)), id, block))
        return { [weak self] in self?.cancelled.insert(id) }
    }

    func run(until end: Date) {
        while true {
            events.removeAll { cancelled.contains($0.seq) }
            guard let i = events.indices.min(by: { (events[$0].at, events[$0].seq) < (events[$1].at, events[$1].seq) }),
                  events[i].at <= end else { break }
            let event = events.remove(at: i)
            current = max(current, event.at)
            let start = current
            event.block()
            if current > start { slices.append((start, current)) }
        }
        current = max(current, end)
    }
}

/// One App run: a scheduler on its own virtual timeline, with recorded passes.
private final class AppRun {
    let timeline: VirtualTimeline
    var passes: [StoragePass] = []
    var deferred = false
    var cpu: TimeInterval = 0
    var appCPU: TimeInterval?
    var onEntry: () -> Void = {}
    private(set) var scheduler: StorageScheduler!

    init(at start: Date, home: URL, aistats: URL, cpuPerEntry: TimeInterval = 0, wallPerEntry: TimeInterval = 0) {
        timeline = VirtualTimeline(start)
        let env = environment(home: home, aistats: aistats, now: { [unowned self] in timeline.current }, cpu: { [unowned self] in cpu },
                              process: { [unowned self] in appCPU }, onEntry: { [unowned self] in
            cpu += cpuPerEntry
            timeline.current += wallPerEntry
            onEntry()
        })
        scheduler = StorageScheduler(timeline: timeline, home: aistats, deferred: { [unowned self] in deferred }) { [unowned self] in
            let pass = StoragePass(env)
            passes.append(pass)
            return pass
        }
        scheduler.start()
    }

    func run(_ seconds: TimeInterval) { timeline.run(until: timeline.current.addingTimeInterval(seconds)) }
    var started: [Date] { passes.compactMap(\.startedAt) }
}

@Test func normalizedPathsCompareByComponentAfterFoldingAndDecomposition() {
    let home = "/Users/fixture"
    #expect(StoragePath.normalize("~/./Documents/DD/", home: home) == "/Users/fixture/Documents/DD")
    #expect(StoragePath.normalize("/System/Volumes/Data/Users/fixture//Documents/DD", home: home) == "/Users/fixture/Documents/DD")
    #expect(StoragePath.normalize("/System/Volumes/Data", home: home) == "/")
    #expect(StoragePath.normalize("~", home: home) == home && StoragePath.normalize("relative/DD", home: home) == nil)
    #expect(StoragePath.keys("/Users/fixture/documents/dd") == StoragePath.keys("/Users/fixture/Documents/DD"))
    #expect(StoragePath.keys("/x/caf\u{E9}") == StoragePath.keys("/x/Cafe\u{301}"))
    #expect(StoragePath.report("/Users/FIXTURE/Library/Developer", home: home) == "~/Library/Developer")
    #expect(StoragePath.report("/Volumes/External/DD", home: home) == "/Volumes/External/DD")
}

@Test func excludedLocationsAndVolumeClassesNeedNoAccess() {
    let home = "/Users/fixture"
    let mounts = [StorageMount(path: "/", local: true), StorageMount(path: "/System/Volumes/Data", local: true),
                  StorageMount(path: "/Volumes/Net", local: false), StorageMount(path: "/Volumes/Ext", local: true)]
    let cases: [(String, String?)] = [
        ("~/Documents/DD", "protected_location"), ("~/documents/DD", "protected_location"), ("~/./Documents/DD/", "protected_location"),
        ("/System/Volumes/Data/Users/fixture/Documents/DD", "protected_location"), ("~/Library/Cookies/DD", "protected_location"),
        ("~", "protected_location"), ("~/Library", "protected_location"), ("~/Library/Caches", "protected_location"),
        ("/", "protected_location"), ("/Users/other/DD", "protected_location"), ("/private/var/DD", "protected_location"),
        ("/Volumes/Net/DD", "network_volume"), ("/Volumes", "network_volume"), ("/Volumes/Ext/DD", "volume_unqualified"),
        ("/tmp/DD", nil), ("~/Library/Caches/org.swift.swiftpm", nil), ("~/Library/Developer/Xcode/DerivedData", nil),
    ]
    for (raw, expected) in cases {
        let path = StoragePath.normalize(raw, home: home)!
        let (reason, mount) = StoragePass.classify(path, home: home, mounts: mounts, major: 27)
        #expect(reason == expected, "\(raw)")
        if expected == nil { #expect(mount == "/System/Volumes/Data") }
    }
    #expect(StoragePass.access("/tmp/aistats-\(UUID().uuidString)") == .redirected, "STO-044: /tmp is a symbolic link")
    #expect(StoragePass.enabled(.bootData, major: 14) && StoragePass.enabled(.bootData, major: 27) && StoragePass.enabled(.bootData, major: 30))
    #expect(!StoragePass.enabled(.bootData, major: 15) && !StoragePass.enabled(.localOther, major: 27) && !StoragePass.enabled(.localOther, major: 30))
}

@Test func passMeasuresOnlyTheAllowlistInOrder() throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let home = root.appendingPathComponent("home"), aistats = root.appendingPathComponent("aistats")
    let lib = home.appendingPathComponent("Library")
    try file(lib.appendingPathComponent("Caches/org.swift.swiftpm/repo.bin"), 300_000)
    try file(lib.appendingPathComponent("Developer/Xcode/Archives/a.xcarchive/Info.plist"), 50_000)
    try file(lib.appendingPathComponent("Developer/Xcode/DerivedData/App/build.o"), 200_000)
    try file(lib.appendingPathComponent("Developer/CoreSimulator/Caches/dyld/cache"), 120_000)
    try file(lib.appendingPathComponent("Developer/CoreSimulator/Devices/device_set.plist"), 400_000)
    let support = ["iOS DeviceSupport", "watchOS DeviceSupport", "tvOS DeviceSupport", "visionOS DeviceSupport", "macOS DeviceSupport",
                   "A DeviceSupport", "Zeta DeviceSupport", "B DeviceSupport", "alpha DeviceSupport", "C DeviceSupport"]
    for (i, name) in support.enumerated() { try file(lib.appendingPathComponent("Developer/Xcode/\(name)/f"), 10_000 + i * 1000) }
    for other in [".npm/x", "Library/Caches/Yarn/x", "Library/pnpm/x", ".gradle/caches/x", "Library/Caches/CocoaPods/x",
                  "Library/Caches/Homebrew/x", ".cargo/registry/x", "go/pkg/mod/x", "Documents/x"] {
        try file(home.appendingPathComponent(other), 1000)
    }
    try file(home.appendingPathComponent("Build/DD/obj"), 80_000)

    let report = try run(environment(home: home, aistats: aistats, preference: "~/Build/DD/"))
    let ordered = support.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
    let fixed = ["~/Library/Caches/org.swift.swiftpm", "~/Library/Developer/Xcode/Archives"] + ordered.prefix(8).map { "~/Library/Developer/Xcode/" + $0 }
        + ["~/Library/Developer/CoreSimulator/Caches", "~/Library/Developer/Xcode/DerivedData", "~/Build/DD", "~/Library/Developer/CoreSimulator/Devices"]
    #expect(Set(report.directories.map(\.path)) == Set(fixed), "STO-041")
    #expect(report.notMeasured.isEmpty && report.deviceSupportOmitted == 2 && report.endReason == "complete")
    let text = encoded(report)
    for name in ordered.suffix(2) { #expect(!text.contains(name)) }
    #expect(!text.contains(home.path) && !text.contains("Documents"), "STO-023")
    #expect(report.scope == "current_user" && report.sizeKind == "allocated_blocks" && report.schemaVersion == 1, "STO-006, STO-024")
    #expect(report.passSeconds >= 0 && report.measuredAt >= report.passStartedAt && report.slices >= 1, "STO-028")
    #expect(zip(report.directories, report.directories.dropFirst()).allSatisfy { $0.sizeBytes >= $1.sizeBytes }, "STO-029")
    #expect(report.directories.allSatisfy { $0.complete && $0.mountPath == "/" && $0.sizeBytes > 0 }, "STO-022")
    #expect(report.directories.filter { $0.source != nil }.map(\.path) == ["~/Build/DD"] && report.derivedDataLocation == "custom")
    #expect(report.directories.first?.path == "~/Library/Developer/CoreSimulator/Devices")

    let body = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    for entry in try #require(body["directories"] as? [[String: Any]]) {
        #expect(entry["path"] is String && entry["sizeBytes"] is Int && entry["complete"] is Bool && entry["mountPath"] is String)
    }
    #expect(StorageFiles.readReport(home: aistats).report == report || StorageFiles.readReport(home: aistats).report?.directories == report.directories)

    try FileManager.default.removeItem(at: lib.appendingPathComponent("Developer/Xcode/Archives"))
    let missing = try run(environment(home: home, aistats: aistats))
    #expect(!encoded(missing).contains("Archives") && missing.directories.count == 12, "STO-025")
}

@Test func xcodeSettingValuesMapToTheReportedLocation() throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let home = root.appendingPathComponent("home"), aistats = root.appendingPathComponent("aistats")
    let outside = root.appendingPathComponent("outside/DD")
    try file(outside.appendingPathComponent("obj"), 20_000)
    try file(home.appendingPathComponent("Library/Developer/Xcode/DerivedData/x"), 20_000)
    let values: [(Any?, String)] = [(nil, "default"), (home.path + "/Library/Developer/Xcode/DerivedData/", "default"),
                                    (outside.path, "custom"), ("relative/DD", "unresolved"), (5, "unresolved"),
                                    (root.path + "/a/../DD", "unresolved")]
    for (value, expected) in values {
        let report = try run(environment(home: home, aistats: aistats, preference: value))
        #expect(report.derivedDataLocation == expected, "STO-045 \(String(describing: value))")
        let text = encoded(report)
        #expect(!text.contains("relative") && !text.contains(".."))
        switch expected {
        case "custom":
            let custom = try #require(report.directories.first { $0.source == "xcode_setting" })
            #expect(custom.path == outside.path, "STO-023: a path outside the home stays absolute")
        case "unresolved":
            let item = try #require(report.notMeasured.first)
            #expect(item.reason == "unresolved_setting" && item.path == nil && item.source == "xcode_setting", "STO-046")
            #expect(!text.contains("\"path\":null"))
        default:
            #expect(report.directories.map(\.path) == ["~/Library/Developer/Xcode/DerivedData"] && report.notMeasured.isEmpty)
        }
    }
    let mounts = bootOnly + [StorageMount(path: "/Volumes/Ext", local: true), StorageMount(path: "/Volumes/Net", local: false)]
    for (value, reason, path) in [("/Volumes/Ext/DD", "volume_unqualified", "/Volumes/Ext/DD"), ("/Volumes/Net/DD", "network_volume", "/Volumes/Net/DD"),
                                  ("~/Documents/DD", "protected_location", "~/Documents/DD"), ("/tmp/aistats-\(UUID().uuidString)/DD", "redirected", nil)] {
        let report = try run(environment(home: home, aistats: aistats, preference: value, mounts: mounts))
        let item = try #require(report.notMeasured.first, "STO-044 \(value)")
        #expect(item.reason == reason && item.source == "xcode_setting" && report.derivedDataLocation == "custom")
        #expect(item.path == (path ?? StoragePath.normalize(value, home: home.path)), "STO-023")
        #expect(!encoded(report).contains(home.path))
    }
}

@Test func walkCountsAllocatedBlocksOnceWithoutFollowingLinksOrChangingFiles() throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let home = root.appendingPathComponent("home"), aistats = root.appendingPathComponent("aistats")
    let dd = home.appendingPathComponent("Library/Developer/Xcode/DerivedData")
    let mib = 1 << 20
    try file(root.appendingPathComponent("target.bin"), 4 * mib)
    try file(dd.appendingPathComponent("a/hard.bin"), mib)
    #expect(link(dd.appendingPathComponent("a/hard.bin").path, dd.appendingPathComponent("hard-link.bin").path) == 0)
    try file(dd.appendingPathComponent("b/original.bin"), mib)
    #expect(clonefile(dd.appendingPathComponent("b/original.bin").path, dd.appendingPathComponent("b/clone.bin").path, 0) == 0)
    #expect(FileManager.default.createFile(atPath: dd.appendingPathComponent("sparse.bin").path, contents: nil))
    #expect(truncate(dd.appendingPathComponent("sparse.bin").path, 1 << 30) == 0)
    try FileManager.default.createSymbolicLink(atPath: dd.appendingPathComponent("loop").path, withDestinationPath: dd.path)
    try FileManager.default.createSymbolicLink(atPath: dd.appendingPathComponent("big").path, withDestinationPath: root.appendingPathComponent("target.bin").path)
    try FileManager.default.createSymbolicLink(atPath: dd.appendingPathComponent("a/self").path, withDestinationPath: "self")

    func manifest() throws -> [String] {
        let items = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?.compactMap { ($0 as? URL)?.path } ?? []
        return items.filter { !$0.hasPrefix(root.path + "/aistats") }.sorted().map { path in
            var st = stat()
            lstat(path, &st)
            return "\(path) \(st.st_size) \(st.st_mode) \(st.st_mtimespec.tv_sec).\(st.st_mtimespec.tv_nsec)"
        }
    }
    let before = try manifest()
    var sizes: Set<UInt64> = []
    for _ in 0..<3 {
        let report = try run(environment(home: home, aistats: aistats))
        let entry = try #require(report.directories.first)
        #expect(entry.complete && report.directories.count == 1)
        sizes.insert(entry.sizeBytes)
    }
    #expect(try manifest() == before, "STO-001")
    let size = try #require(sizes.first)
    #expect(sizes.count == 1)
    #expect(size >= UInt64(3 * mib) && size < UInt64(3 * mib + mib / 2), "one hard link, two clone inodes, no sparse holes, no link targets (STO-004)")
}

@Test func unreadableItemsMarkTheEntryIncomplete() throws {
    let root = try fixture()
    let home = root.appendingPathComponent("home"), aistats = root.appendingPathComponent("aistats")
    let locked = home.appendingPathComponent("Library/Caches/org.swift.swiftpm/locked")
    try file(locked.appendingPathComponent("secret"), 1000)
    try file(home.appendingPathComponent("Library/Caches/org.swift.swiftpm/open"), 1000)
    try file(home.appendingPathComponent("Library/Developer/CoreSimulator/Caches/x"), 1000)
    chmod(locked.path, 0)
    defer { chmod(locked.path, 0o755); try? FileManager.default.removeItem(at: root) }
    let report = try run(environment(home: home, aistats: aistats))
    #expect(report.directories.first { $0.path == "~/Library/Caches/org.swift.swiftpm" }?.complete == false, "STO-026")
    #expect(report.directories.first { $0.path == "~/Library/Developer/CoreSimulator/Caches" }?.complete == true)
}

@Test func mountTableTimeoutEndsThePassWithoutAWalk() throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let home = root.appendingPathComponent("home"), aistats = root.appendingPathComponent("aistats")
    try file(home.appendingPathComponent("Library/Developer/Xcode/DerivedData/x"), 1000)
    var env = environment(home: home, aistats: aistats, preference: 1)
    env.mounts = { Thread.sleep(forTimeInterval: 30); return bootOnly }
    let start = Date()
    let pass = StoragePass(env)
    #expect(pass.slice())
    #expect(Date().timeIntervalSince(start) < 1, "STO-044")
    let report = try #require(pass.report)
    #expect(report.endReason == "mount_table_timeout" && report.directories.isEmpty)
    #expect(report.notMeasured.filter { $0.reason == "not_reached" }.map(\.path) == [
        "~/Library/Caches/org.swift.swiftpm", "~/Library/Developer/Xcode/Archives", "~/Library/Developer/CoreSimulator/Caches",
        "~/Library/Developer/Xcode/DerivedData", "~/Library/Developer/CoreSimulator/Devices",
    ])
    #expect(report.notMeasured.contains { $0.reason == "unresolved_setting" && $0.path == nil })
}

@Test func slicesAndThePassStopAtTheirWallBudgets() throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let home = root.appendingPathComponent("home"), aistats = root.appendingPathComponent("aistats")
    let dd = home.appendingPathComponent("Library/Developer/Xcode/DerivedData")
    try dir(dd)
    for i in 0..<4000 { FileManager.default.createFile(atPath: dd.appendingPathComponent("f\(i)").path, contents: nil) }
    try file(home.appendingPathComponent("Library/Developer/CoreSimulator/Devices/x"), 1000)
    let t0 = Date(timeIntervalSince1970: 2_000_000_000)
    let app = AppRun(at: t0, home: home, aistats: aistats, wallPerEntry: 0.001)
    var scheduled: Date??
    app.onEntry = { if scheduled == nil { scheduled = StorageFiles.readSchedule(home: aistats) } }
    app.run(119)
    #expect(app.started.isEmpty && StorageFiles.readSchedule(home: aistats) == nil)
    app.run(2)
    let start = try #require(app.started.first)
    #expect(start == t0.addingTimeInterval(120), "STO-043")
    #expect(scheduled == .some(.some(start)), "STO-042: persisted before the walk of the first slice")
    app.deferred = true
    app.timeline.run(until: start.addingTimeInterval(5 * 3600 - 1))
    app.deferred = false
    app.scheduler.conditionsChanged()
    app.timeline.run(until: start.addingTimeInterval(5 * 3600 + 10))

    let pass = try #require(app.passes.first)
    let report = try #require(pass.report)
    #expect(report.endReason == "pass_wall_cap" && report.measuredAt.timeIntervalSince(start) <= 5 * 3600 + 0.001, "STO-017")
    #expect(StorageFiles.readReport(home: aistats).report?.endReason == "pass_wall_cap")
    #expect(app.timeline.slices.count == 2 && app.timeline.slices.allSatisfy { $0.end.timeIntervalSince($0.start) <= 2.001 })
    for (a, b) in zip(app.timeline.slices, app.timeline.slices.dropFirst()) { #expect(b.start.timeIntervalSince(a.end) >= 60) }
    let interrupted = try #require(report.directories.first { $0.path == "~/Library/Developer/Xcode/DerivedData" })
    #expect(!interrupted.complete, "STO-027")
    #expect(report.notMeasured.contains { $0.path == "~/Library/Developer/CoreSimulator/Devices" && $0.reason == "not_reached" })
}

@Test func passCPUCapAndAdmissionSkips() throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let home = root.appendingPathComponent("home"), aistats = root.appendingPathComponent("aistats")
    let dd = home.appendingPathComponent("Library/Developer/Xcode/DerivedData")
    try dir(dd)
    for i in 0..<2500 { FileManager.default.createFile(atPath: dd.appendingPathComponent("f\(i)").path, contents: nil) }
    try file(home.appendingPathComponent("Library/Developer/CoreSimulator/Devices/x"), 1000)
    let t0 = Date(timeIntervalSince1970: 2_000_000_000)
    let app = AppRun(at: t0, home: home, aistats: aistats, cpuPerEntry: 1.0 / 64)
    app.appCPU = 0
    app.run(121)
    let pass = try #require(app.passes.first)
    #expect(pass.slices == 1 && pass.slicesSkippedForCpu == 0)
    app.run(30)
    app.appCPU = 0.45
    app.run(31)
    #expect(pass.slices == 1 && pass.slicesSkippedForCpu == 1, "STO-019: 450 ms in the window skips the slice")
    app.run(60)
    #expect(pass.slices == 2)
    app.run(6 * 3600)
    let report = try #require(pass.report)
    #expect(report.endReason == "pass_cpu_cap" && report.cpuSeconds >= 30 && report.cpuSeconds <= 30.01 && report.slicesSkippedForCpu == 1, "STO-018")
    #expect(report.cpuSeconds / Double(report.slices) <= 0.110)
    #expect(report.notMeasured.contains { $0.path == "~/Library/Developer/CoreSimulator/Devices" && $0.reason == "not_reached" }, "STO-046")
    #expect(report.directories.first { $0.path == "~/Library/Developer/Xcode/DerivedData" }?.complete == false)
}

@Test func deferralHoldsPassStartsAndSlices() throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let home = root.appendingPathComponent("home"), aistats = root.appendingPathComponent("aistats")
    let dd = home.appendingPathComponent("Library/Developer/Xcode/DerivedData")
    try dir(dd)
    for i in 0..<1000 { FileManager.default.createFile(atPath: dd.appendingPathComponent("f\(i)").path, contents: nil) }
    let t0 = Date(timeIntervalSince1970: 2_000_000_000)
    let app = AppRun(at: t0, home: home, aistats: aistats, cpuPerEntry: 0.01)
    app.deferred = true
    app.run(3 * 3600)
    #expect(app.started.isEmpty, "STO-021: no pass start while deferred")
    app.deferred = false
    let cleared = app.timeline.current
    app.run(15 * 60)
    let start = try #require(app.started.first)
    #expect(start.timeIntervalSince(cleared) <= 15 * 60)
    let pass = try #require(app.passes.first)
    let slices = pass.slices
    app.deferred = true
    app.run(2 * 3600)
    #expect(pass.slices == slices, "no slice while deferred mid-pass")
    app.deferred = false
    app.scheduler.conditionsChanged()
    app.run(1)
    #expect(pass.slices == slices + 1, "a notification starts the slice within 1 s")
    app.run(10)
    app.deferred = true
    app.run(10)
    app.deferred = false
    app.scheduler.conditionsChanged()
    app.run(1)
    #expect(pass.slices == slices + 1, "a cleared condition inside a pause waits for the pause end")
    app.run(40)
    #expect(pass.slices == slices + 2)
}

@Test func passesStartAtMostOncePerIntervalAcrossRestarts() throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let home = root.appendingPathComponent("home"), aistats = root.appendingPathComponent("aistats")
    try file(home.appendingPathComponent("Library/Developer/Xcode/DerivedData/x"), 1000)
    let t0 = Date(timeIntervalSince1970: 2_000_000_000)
    var starts: [Date] = []
    let first = AppRun(at: t0, home: home, aistats: aistats)
    first.run(3600)
    starts += first.started
    #expect(starts == [t0.addingTimeInterval(120)], "STO-043")
    for restart in stride(from: 3600.0, to: 18 * 3600, by: 2 * 3600) {
        let app = AppRun(at: t0.addingTimeInterval(restart), home: home, aistats: aistats)
        app.run(min(2 * 3600, 18 * 3600 - restart))
        starts += app.started
    }
    #expect(starts.count == 3, "STO-020: three intervals, one pass each")
    for (a, b) in zip(starts, starts.dropFirst()) { #expect(b.timeIntervalSince(a) >= 6 * 3600) }

    try FileManager.default.createDirectory(at: StorageFiles.directory(aistats), withIntermediateDirectories: true)
    let schedule = StorageFiles.directory(aistats).appendingPathComponent(StorageFiles.schedule)
    try Data(#"{"schemaVersion":99,"lastPassStartedAt":"2001-01-01T00:00:00Z"}"#.utf8).write(to: schedule)
    let launch = t0.addingTimeInterval(30 * 3600)
    let app = AppRun(at: launch, home: home, aistats: aistats)
    app.run(6 * 3600 - 1)
    #expect(app.started.isEmpty, "STO-050: an unknown schedule schema counts as a pass at launch")
    app.run(2)
    #expect(app.started == [launch.addingTimeInterval(6 * 3600)])
    #expect(StorageFiles.readSchedule(home: aistats) == .some(.some(launch.addingTimeInterval(6 * 3600))))
    let text = try String(contentsOf: schedule, encoding: .utf8)
    #expect(text.contains("\"schemaVersion\":1"))
    var st = stat()
    #expect(stat(schedule.path, &st) == 0 && st.st_mode & 0o777 == 0o600)
    #expect(stat(StorageFiles.directory(aistats).appendingPathComponent(StorageFiles.report).path, &st) == 0 && st.st_mode & 0o777 == 0o600)
    #expect(stat(StorageFiles.directory(aistats).path, &st) == 0 && st.st_mode & 0o777 == 0o700)
}

@Test func wallCapEndsThePassInAPauseAndWhileDeferred() throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let home = root.appendingPathComponent("home")
    let dd = home.appendingPathComponent("Library/Developer/Xcode/DerivedData")
    try dir(dd)
    for i in 0..<1000 { FileManager.default.createFile(atPath: dd.appendingPathComponent("f\(i)").path, contents: nil) }
    let t0 = Date(timeIntervalSince1970: 2_000_000_000)

    // One entry per second gives 2 s slices every 62 s, so the cap falls 20 s into a pause (18000 mod 62 = 20).
    let paced = AppRun(at: t0, home: home, aistats: root.appendingPathComponent("paced"), wallPerEntry: 1)
    paced.run(121)
    let start = try #require(paced.started.first)
    paced.timeline.run(until: start.addingTimeInterval(5 * 3600 + 120))
    let report = try #require(paced.passes.first?.report)
    #expect(report.endReason == "pass_wall_cap" && report.measuredAt.timeIntervalSince(start) <= 5 * 3600 + 0.001, "STO-017 in a pause")
    #expect(report.measuredAt.timeIntervalSince(start) >= 5 * 3600 - 0.001)
    for (a, b) in zip(paced.timeline.slices, paced.timeline.slices.dropFirst()) { #expect(b.start.timeIntervalSince(a.end) >= 60) }

    let held = AppRun(at: t0, home: home, aistats: root.appendingPathComponent("held"), wallPerEntry: 0.01)
    held.run(121)
    let heldStart = try #require(held.started.first)
    held.deferred = true
    held.timeline.run(until: heldStart.addingTimeInterval(5 * 3600 + 3600))
    let heldReport = try #require(held.passes.first?.report, "STO-017: the cap ends the pass while deferred")
    #expect(heldReport.endReason == "pass_wall_cap" && heldReport.measuredAt.timeIntervalSince(heldStart) <= 5 * 3600 + 0.001)
    #expect(StorageFiles.readReport(home: root.appendingPathComponent("held")).report?.endReason == "pass_wall_cap")
    #expect(held.passes.first?.slices == 1, "no slice walked while deferred")
}

@Test func admissionReadsTheLastSixtySecondsAfterADeferralOrSleep() throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let home = root.appendingPathComponent("home"), aistats = root.appendingPathComponent("aistats")
    let dd = home.appendingPathComponent("Library/Developer/Xcode/DerivedData")
    try dir(dd)
    for i in 0..<2000 { FileManager.default.createFile(atPath: dd.appendingPathComponent("f\(i)").path, contents: nil) }
    let t0 = Date(timeIntervalSince1970: 2_000_000_000)
    let app = AppRun(at: t0, home: home, aistats: aistats, cpuPerEntry: 0.01)
    app.appCPU = 0
    app.run(121)
    let pass = try #require(app.passes.first)
    #expect(pass.slices == 1)
    app.deferred = true
    for _ in 0..<15 {
        app.run(60)
        app.appCPU! += 0.2
    }
    app.appCPU! += 0.5
    app.deferred = false
    app.scheduler.conditionsChanged()
    app.run(1)
    #expect(pass.slices == 1 && pass.slicesSkippedForCpu == 1, "STO-019: 500 ms in the last 60 s skips the slice after a deferral")
    app.run(60)
    #expect(pass.slices == 2 && pass.slicesSkippedForCpu == 1)

    // An 8 h sleep: the late timer ends the pass at the cap and the next pass waits a full window before its first slice.
    let slept = app.timeline.current.addingTimeInterval(8 * 3600)
    app.timeline.current = slept
    app.run(1)
    #expect(pass.report?.endReason == "pass_wall_cap")
    app.run(58)
    #expect(app.passes.count == 2 && app.passes[1].startedAt == nil, "no slice within 60 s of the baseline")
    app.run(2)
    let next = try #require(app.passes.last)
    #expect(next.startedAt == slept.addingTimeInterval(60) && next.slices == 1)
}

@Test func inaccessibleRootsAreNotMeasured() throws {
    let root = try fixture()
    let home = root.appendingPathComponent("home"), aistats = root.appendingPathComponent("aistats")
    let simulator = home.appendingPathComponent("Library/Developer/CoreSimulator")
    let swiftpm = home.appendingPathComponent("Library/Caches/org.swift.swiftpm")
    try file(simulator.appendingPathComponent("Devices/x"), 1000)
    try file(simulator.appendingPathComponent("Caches/x"), 1000)
    try file(swiftpm.appendingPathComponent("x"), 1000)
    try file(home.appendingPathComponent("Library/Developer/Xcode/DerivedData/x"), 1000)
    chmod(simulator.path, 0)
    chmod(swiftpm.path, 0)
    defer { chmod(simulator.path, 0o755); chmod(swiftpm.path, 0o755); try? FileManager.default.removeItem(at: root) }
    let report = try run(environment(home: home, aistats: aistats))
    #expect(report.directories.map(\.path) == ["~/Library/Developer/Xcode/DerivedData"], "STO-025: no entry for a root that was not opened")
    let unreadable = report.notMeasured.filter { $0.reason == "unreadable" }.compactMap(\.path)
    #expect(Set(unreadable) == ["~/Library/Developer/CoreSimulator/Devices", "~/Library/Developer/CoreSimulator/Caches",
                                "~/Library/Caches/org.swift.swiftpm"], "STO-046")
}

@Test func aScheduleWriteFailureStartsNoPass() throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let home = root.appendingPathComponent("home"), aistats = root.appendingPathComponent("aistats")
    try file(home.appendingPathComponent("Library/Developer/Xcode/DerivedData/x"), 1000)
    try file(aistats, 10)
    let t0 = Date(timeIntervalSince1970: 2_000_000_000)
    var entries = 0
    let first = AppRun(at: t0, home: home, aistats: aistats)
    first.onEntry = { entries += 1 }
    first.run(6 * 3600 + 61)
    #expect(first.started.isEmpty && first.passes.allSatisfy { $0.slices == 0 && $0.report == nil }, "STO-042")
    #expect(first.passes.count == 2, "the next attempt waits one interval")
    let relaunch = AppRun(at: t0.addingTimeInterval(1800), home: home, aistats: aistats)
    relaunch.onEntry = { entries += 1 }
    relaunch.run(3600)
    #expect(relaunch.started.isEmpty && entries == 0, "STO-020: a relaunch walks nothing without a persisted start")
}
