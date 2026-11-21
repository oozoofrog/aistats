import Foundation
import os
import StatsCore

enum PanelTrace {
    static var now: Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }
    private static let signposter = OSSignposter(logHandle: OSLog(subsystem: AIStatsPaths.appBundleIdentifier, category: .pointsOfInterest))
    private static let writesMarkers = ProcessInfo.processInfo.environment["AISTATS_CPU_MARKERS"] == "1"
    private static let tracesPanel = ProcessInfo.processInfo.environment["AISTATS_PANEL_TRACE"] == "1"

    static var isEnabled: Bool { tracesPanel && signposter.isEnabled }

    static func event(_ name: StaticString, _ host: String = "", _ effect: String = "") {
        if isEnabled {
            signposter.emitEvent(name, "\(host, privacy: .public) \(effect, privacy: .public)")
        }
    }

    static func marker(_ name: String, host: String = "") {
        guard writesMarkers else { return }
        let line = "\(DispatchTime.now().uptimeNanoseconds) \(ProcessInfo.processInfo.processIdentifier) \(name) \(host)\n"
        FileHandle.standardError.write(Data(line.utf8))
    }
}

final class ProcessGeneration: @unchecked Sendable {
    enum Change: Equatable { case first, last, unchanged }

    private let lock = NSLock()
    private var exposed: Set<String> = []
    private var generation: UInt64 = 0

    func setExposed(_ id: String, _ visible: Bool) -> Change {
        lock.withLock {
            let wasEmpty = exposed.isEmpty
            if visible { exposed.insert(id) } else { exposed.remove(id) }
            if !wasEmpty && exposed.isEmpty {
                generation += 1
                return .last
            }
            return wasEmpty && !exposed.isEmpty ? .first : .unchanged
        }
    }

    func ticket() -> UInt64? {
        lock.withLock { exposed.isEmpty ? nil : generation }
    }

    func allows(_ ticket: UInt64?) -> Bool {
        lock.withLock { !exposed.isEmpty && ticket == generation }
    }

    func enumerate(_ ticket: UInt64?, _ readPIDs: () -> [Int32]) -> [Int32]? {
        guard let ticket else { return nil }
        return lock.withLock {
            guard !exposed.isEmpty, ticket == generation else { return nil }
            return readPIDs()
        }
    }
}
