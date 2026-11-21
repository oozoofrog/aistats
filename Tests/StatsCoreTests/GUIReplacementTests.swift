import Foundation
import Testing
@testable import StatsCore

@Suite struct GUIReplacementTests {
    enum Change: CaseIterable {
        case deletion, owned, differentConflict

        var text: String {
            switch self {
            case .deletion: return #"{"mcpServers":{}}"#
            case .owned:
                return #"{"mcpServers":{"aistats":{"command":"/fixtures/aistats","args":["mcp"],"env":{"AISTATS_MANAGED":"1"}}}}"#
            case .differentConflict: return #"{"mcpServers":{"aistats":{"command":"/different","args":[]}}}"#
            }
        }
    }

    private let foreign = #"{"mcpServers":{"aistats":{"command":"/foreign","args":[],"env":{"TOKEN":"fixture-secret"}}}}"#

    @Test(arguments: [AgentTarget.cursor, .claudeCode], Change.allCases)
    func guardRejectsWhenLockedInspectionDoesNotMatch(target: AgentTarget, change: Change) throws {
        try refuses(target: target, change: change, afterInspection: false)
    }

    @Test(arguments: [AgentTarget.cursor, .claudeCode], Change.allCases)
    func finalRecheckRejectsChangedEntry(target: AgentTarget, change: Change) throws {
        try refuses(target: target, change: change, afterInspection: true)
    }

    private func refuses(target: AgentTarget, change: Change, afterInspection: Bool) throws {
        let f = try FakeAgents()
        let url = target == .cursor ? f.cursorConfig : f.claudeConfig
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try foreign.write(to: url, atomically: true, encoding: .utf8)
        let registrar = AgentRegistrar(binaryPath: "/fixtures/aistats", environment: f.environment())
        let fingerprint = try #require(registrar.status(target).entryFingerprint)
        var changeCalls = 0
        var mutationError: Error?
        registrar.beforeCLIChange = { _ in changeCalls += 1 }
        if afterInspection {
            registrar.afterInspect = { _ in
                do { try change.text.write(to: url, atomically: true, encoding: .utf8) }
                catch { mutationError = error }
            }
        } else {
            try change.text.write(to: url, atomically: true, encoding: .utf8)
        }

        let outcome = registrar.replaceConfirmedConflict(target, fingerprint: fingerprint)
        #expect(mutationError == nil)
        #expect(!outcome.ok)
        #expect(try Data(contentsOf: url) == Data(change.text.utf8))
        #expect(f.backups(target).isEmpty)
        #expect(changeCalls == 0)
        #expect(!f.calls().contains { $0.contains("mcp add") || $0.contains("mcp remove") })
    }

    @Test func matchingConflictBacksUpAndReplaces() throws {
        let f = try FakeAgents()
        try f.writeDesktop(foreign)
        let registrar = AgentRegistrar(binaryPath: "/fixtures/aistats", environment: f.environment())
        let fingerprint = try #require(registrar.status(.claudeDesktop).entryFingerprint)
        let outcome = registrar.replaceConfirmedConflict(.claudeDesktop, fingerprint: fingerprint)
        #expect(outcome.ok)
        #expect(outcome.action == "replaced")
        let backup = try #require(outcome.backup)
        #expect(try Data(contentsOf: URL(fileURLWithPath: backup)) == Data(foreign.utf8))
    }
}
