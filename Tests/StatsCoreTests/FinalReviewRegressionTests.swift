import CryptoKit
import Darwin
import Foundation
import Testing
@testable import StatsCore

// Regression tests for the final registration review (A1–A5, A7). Each reproduces the reviewer's scenario
// with the fake agent CLIs in an isolated temp folder.

private func mode(_ url: URL) -> Int {
    ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions] as? Int) ?? -1
}

private func write(_ text: String, _ url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
}

private func bytes(_ url: URL) -> Data? { try? Data(contentsOf: url) }

private func entry(_ command: String, _ args: [String] = ["mcp"], env: [String: String] = [:], extras: [String] = []) -> RegistrationEntry {
    RegistrationEntry(command: command, args: args, env: env, extras: extras, raw: Data())
}

@Suite struct FinalReviewRegistrationTests {
    /// A1: relative overrides resolved once (against the working directory) and handed to the child as-is.
    @Test func relativeOverridesResolveOnceAndReachTheChild() throws {
        let f = try FakeAgents()
        let work = f.root.appendingPathComponent("work")
        for d in ["rel-claude", "rel-codex", "rel-gemini/.gemini", "rel-data"] {
            try FileManager.default.createDirectory(at: work.appendingPathComponent(d), withIntermediateDirectories: true)
        }
        // What the child would have used before (it runs in HOME): a foreign Gemini entry that must stay.
        let decoy = f.home.appendingPathComponent("rel-gemini/.gemini/settings.json")
        let foreign = #"{"mcpServers":{"aistats":{"command":"/foreign","args":["mcp"],"env":{"FOREIGN":"value"}}}}"#
        try write(foreign, decoy)
        let env = f.environment(["CLAUDE_CONFIG_DIR": "rel-claude", "CODEX_HOME": "rel-codex", "GEMINI_CLI_HOME": "rel-gemini",
                                 "AISTATS_HOME": "rel-data"], cwd: work.path)
        #expect(env.configURL(.claudeCode).path == work.path + "/rel-claude/.claude.json")
        #expect(env.configURL(.codex).path == work.path + "/rel-codex/config.toml")
        #expect(env.configURL(.gemini).path == work.path + "/rel-gemini/.gemini/settings.json")
        #expect(env.dataDirectory.path == work.path + "/rel-data")
        let child = env.childEnvironment
        for (k, v) in [("CLAUDE_CONFIG_DIR", "rel-claude"), ("CODEX_HOME", "rel-codex"), ("GEMINI_CLI_HOME", "rel-gemini"), ("AISTATS_HOME", "rel-data")] {
            #expect(child[k] == work.path + "/" + v, "\(k)")
        }
        #expect(RegistrationEnvironment.absolute("~/x", cwd: "/w", home: "/h") == "/h/x")
        #expect(RegistrationEnvironment.absolute("/abs", cwd: "/w", home: "/h") == "/abs")

        let r = AgentRegistrar(binaryPath: "/x/aistats", environment: env)
        for t in [AgentTarget.claudeCode, .codex, .gemini] {
            #expect(r.status(t).state == .notInstalled, "\(t)")
            let o = r.install(t)
            #expect(o.ok, "\(t): \(o.message)")
            #expect(r.status(t).state == .installed, "\(t): AIStats and the agent CLI agree on the file")
        }
        #expect(FileManager.default.fileExists(atPath: work.path + "/rel-claude/.claude.json"))
        #expect(FileManager.default.fileExists(atPath: work.path + "/rel-gemini/.gemini/settings.json"))
        #expect(bytes(decoy) == Data(foreign.utf8), "the file the child would have resolved on its own is untouched")
        #expect(!FileManager.default.fileExists(atPath: f.home.appendingPathComponent("rel-claude").path))
    }

    /// A2: pruning deletes only backups AIStats listed in its manifest, and only while they are unchanged.
    @Test func pruneTouchesOnlyListedUnchangedBackups() throws {
        let f = try FakeAgents()
        let store = f.dataDir.appendingPathComponent("backups/cursor")
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        var foreign: [URL: String] = [:]
        for i in 0..<6 {
            let u = store.appendingPathComponent("20000101T00000\(i)Z-mcp.json")
            foreign[u] = "foreign \(i)"
            try write("foreign \(i)", u)
        }
        try write(#"{"mcpServers":{}}"#, f.cursorConfig)
        let r = AgentRegistrar(binaryPath: "/x/aistats", environment: f.environment())
        let first = r.install(.cursor)
        #expect(first.ok, "\(first.message)")
        // A listed backup that was changed afterwards is no longer AIStats's file: never deleted.
        let tampered = URL(fileURLWithPath: try #require(first.backup))
        try write("edited by someone", tampered)
        for _ in 0..<4 {
            #expect(r.uninstall(.cursor).ok)
            #expect(r.install(.cursor).ok)
        }
        for (u, text) in foreign { #expect(String(data: bytes(u) ?? Data(), encoding: .utf8) == text, "\(u.lastPathComponent)") }
        #expect(String(data: bytes(tampered) ?? Data(), encoding: .utf8) == "edited by someone")
        #expect(f.backups(.cursor).count == AgentRegistrar.maxBackups)
        #expect(f.backups(.cursor).allSatisfy { $0 != tampered })
        #expect(FileManager.default.fileExists(atPath: store.appendingPathComponent("manifest.jsonl").path))
        #expect(mode(store) == 0o755, "an existing folder keeps its mode")

        // Folders AIStats creates itself are 0700.
        let g = try FakeAgents()
        try write("{}", g.cursorConfig)
        #expect(AgentRegistrar(binaryPath: "/x/aistats", environment: g.environment()).install(.cursor).ok)
        #expect(mode(g.dataDir.appendingPathComponent("backups")) == 0o700)
        #expect(mode(g.dataDir.appendingPathComponent("backups/cursor")) == 0o700)
        #expect(mode(g.dataDir.appendingPathComponent("locks")) == 0o700)
    }

    /// A2: a symlinked backups or locks folder is refused; nothing is written through it or chmod'ed.
    @Test func symlinkedAIStatsFoldersAreRefused() throws {
        for link in ["backups/cursor", "backups", "locks"] {
            let f = try FakeAgents()
            let outside = f.root.appendingPathComponent("outside")
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
            chmod(outside.path, 0o755)
            let at = f.dataDir.appendingPathComponent(link)
            try FileManager.default.createDirectory(at: at.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: at, withDestinationURL: outside)
            let original = "{\"mcpServers\":{}}\n"
            try write(original, f.cursorConfig)
            let o = AgentRegistrar(binaryPath: "/x/aistats", environment: f.environment()).install(.cursor)
            #expect(!o.ok, "\(link): \(o.message)")
            #expect(o.message.contains("not a real folder"), "\(link): \(o.message)")
            #expect(bytes(f.cursorConfig) == Data(original.utf8), "\(link)")
            #expect(mode(outside) == 0o755, "\(link)")
            #expect((try FileManager.default.contentsOfDirectory(atPath: outside.path)).isEmpty, "\(link)")
        }
    }

    /// A3: the edit changes only the entry's text; every other byte (numbers, duplicate keys elsewhere,
    /// spacing, CRLF) stays, and removing the entry gives the original back.
    @Test func jsonEditsAreLosslessOutsideTheEntry() throws {
        let unrelated = #""untouched":{"x":1,"x":2,"n":12345678901234567890123456789012345678901234,"f":1.10}"#
        let shapes = [
            "{\"mcpServers\":{},\(unrelated)}\n",
            "{\n  \"mcpServers\": {},\n  \(unrelated)\n}\n",
            "{\n    \"mcpServers\": {\n        \"other\": {\"command\": \"/o\"}\n    },\n    \(unrelated)\n}",
            "{\r\n\t\"mcpServers\": {\r\n\t\t\"other\": {\"command\": \"/o\"}\r\n\t},\r\n\t\(unrelated)\r\n}\r\n",
            "{\"a\":[1, 2.50, true], \"mcpServers\" : { \"z\" : {} } , \(unrelated)}",
        ]
        for original in shapes {
            let f = try FakeAgents()
            try write(original, f.cursorConfig)
            let r = AgentRegistrar(binaryPath: "/x/aistats", environment: f.environment())
            let i = r.install(.cursor)
            #expect(i.ok, "\(i.message)")
            let after = String(decoding: bytes(f.cursorConfig) ?? Data(), as: UTF8.self)
            #expect(after.contains(unrelated), "\(after)")
            #expect(r.status(.cursor).state == .installed, "\(after)")
            #expect(original.contains("\r\n") == after.contains("\r\n"))
            let u = r.uninstall(.cursor)
            #expect(u.ok, "\(u.message)")
            #expect(bytes(f.cursorConfig) == Data(original.utf8), "round trip:\n\(original)\n→\n\(String(decoding: bytes(f.cursorConfig) ?? Data(), as: UTF8.self))")
        }
        // A config without mcpServers: everything before the insertion point and the closing brace stay.
        let f = try FakeAgents()
        let plain = "{\n  \(unrelated)\n}\n"
        try write(plain, f.cursorConfig)
        let r = AgentRegistrar(binaryPath: "/x/aistats", environment: f.environment())
        #expect(r.install(.cursor).ok)
        let after = bytes(f.cursorConfig) ?? Data()
        #expect(after.starts(with: Data("{\n  \(unrelated)".utf8)) && after.suffix(3) == Data("\n}\n".utf8))

        // Replacing a confirmed foreign entry changes only that member's value bytes.
        let g = try FakeAgents()
        let prefix = "{ \"mcpServers\" : {\"other\": {\"n\": 1e300}, \"aistats\": ", suffix = " }, \(unrelated) }"
        try write(prefix + #"{"command":"/foreign/aistats","args":["mcp"],"custom":1.00000000000000000000001}"# + suffix, g.cursorConfig)
        let rg = AgentRegistrar(binaryPath: "/x/aistats", environment: g.environment())
        let fp = try #require(rg.status(.cursor).entryFingerprint)
        let replaced = rg.install(.cursor, replacing: fp)
        #expect(replaced.ok, "\(replaced.message)")
        let text = String(decoding: bytes(g.cursorConfig) ?? Data(), as: UTF8.self)
        #expect(text.hasPrefix(prefix) && text.hasSuffix(suffix), "\(text)")
    }

    /// A3: what can't be edited without loss or doubt is refused, unchanged.
    @Test func ambiguousJSONIsRefused() throws {
        let cases = [
            "{\n  // a comment\n  \"mcpServers\": {}\n}\n",
            #"{"mcpServers":{},"mcpServers":{"aistats":{"command":"/foreign","args":["mcp"]}}}"#,
            #"{"mcpServers":{"aistats":{"command":"/x/aistats","args":["mcp"]},"aistats":{"command":"/foreign"}}}"#,
            #"{"mcpServers":null}"#,
        ]
        for original in cases {
            let f = try FakeAgents()
            try write(original, f.cursorConfig)
            let r = AgentRegistrar(binaryPath: "/x/aistats", environment: f.environment())
            guard case .checkFailed = r.status(.cursor).state else { Issue.record("expected check_failed: \(original)"); continue }
            #expect(!r.install(.cursor).ok)
            #expect(!r.uninstall(.cursor).ok)
            #expect(bytes(f.cursorConfig) == Data(original.utf8))
            #expect(f.backups(.cursor).isEmpty)
        }
    }

    /// A4: the fingerprint is the full SHA-256 of the entry's exact bytes; a digit or a hidden Codex
    /// setting changes it, and a stale consent is refused.
    @Test func fingerprintsCoverExactBytes() throws {
        let f = try FakeAgents()
        let first = #"{"mcpServers":{"aistats":{"command":"/foreign/aistats","args":["mcp"],"custom":1.00000000000000000000000000000000000000000000000000001}}}"#
        try write(first, f.cursorConfig)
        let r = AgentRegistrar(binaryPath: "/x/aistats", environment: f.environment())
        let a = try #require(r.status(.cursor).entryFingerprint)
        let second = first.replacingOccurrences(of: "01}}}", with: "02}}}")
        try write(second, f.cursorConfig)
        let b = try #require(r.status(.cursor).entryFingerprint)
        #expect(a != b)
        #expect(!r.install(.cursor, replacing: a).ok)
        #expect(bytes(f.cursorConfig) == Data(second.utf8))

        // Consent: 12–64 hex digits of the full digest, any case.
        let span = try #require(try JSONKeyScan.entrySpan(Data(second.utf8), name: "t"))
        let e = RegistrationEntry.fromJSONConfig([:] as [String: Any], source: Data(second.utf8).subdata(in: span))
        let full = SHA256.hash(data: Data(second.utf8).subdata(in: span)).map { String(format: "%02x", $0) }.joined()
        #expect(e.fullFingerprint == full && e.fingerprint == String(full.prefix(12)))
        #expect(e.matches(consent: e.fingerprint) && e.matches(consent: full) && e.matches(consent: full.uppercased()))
        #expect(!e.matches(consent: String(full.prefix(11))) && !e.matches(consent: "zz" + full.prefix(10)))

        // Codex prints the same JSON for required = false and true; the TOML text tells them apart.
        let reported = #"{"name":"aistats","enabled":true,"disabled_reason":null,"transport":{"type":"stdio","command":"/foreign/aistats","args":["mcp"],"env":null,"env_vars":[],"cwd":null},"enabled_tools":null,"disabled_tools":null,"startup_timeout_sec":null,"tool_timeout_sec":null}"#
        try write(reported, f.codexJSON)
        let base = "[mcp_servers.aistats]\ncommand = \"/foreign/aistats\"\nargs = [\"mcp\"]\nrequired = "
        try write(base + "false\n", f.codexConfig)
        let c1 = try #require(r.status(.codex).entryFingerprint)
        try write(base + "true\n", f.codexConfig)
        let c2 = try #require(r.status(.codex).entryFingerprint)
        #expect(c1 != c2)
        let stale = r.install(.codex, replacing: c1)
        #expect(!stale.ok && stale.message.contains("not the one confirmed"), "\(stale.message)")
        #expect(!f.calls().contains { $0.hasPrefix("codex mcp add") })
        #expect(bytes(f.codexConfig) == Data((base + "true\n").utf8))
    }

    /// A5: a command with a NUL, or one whose path doesn't resolve, is never this binary.
    @Test func ownershipNeedsResolvablePathsWithoutNUL() throws {
        let f = try FakeAgents()
        let dir = f.root.appendingPathComponent("real-bin")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let me = dir.appendingPathComponent("aistats").path
        try write("#!/bin/sh\n", URL(fileURLWithPath: me))
        let r = AgentRegistrar(binaryPath: me, environment: f.environment())
        #expect(r.classify(entry(me)) == .installed)
        #expect(r.classify(entry(dir.path + "/../real-bin/aistats")) == .installed, "a path that resolves to this binary")
        for command in [me + "\0unexpected", f.root.path + "/missing-component/../real-bin/aistats"] {
            guard case .nameConflict = r.classify(entry(command)) else { Issue.record("\(command.debugDescription) treated as ours"); continue }
        }
        // End to end: such an entry is not removed.
        let escaped = (try JSONSerialization.data(withJSONObject: me + "\0unexpected", options: [.fragmentsAllowed])).map { Character(UnicodeScalar($0)) }
        let text = "{\"mcpServers\":{\"aistats\":{\"command\":\(String(escaped)),\"args\":[\"mcp\"]}}}"
        try write(text, f.cursorConfig)
        #expect(!r.uninstall(.cursor).ok)
        #expect(bytes(f.cursorConfig) == Data(text.utf8))
    }

    /// A7: Codex failing on its config (even with "No MCP server named 'aistats' found" inside the error)
    /// or saying "not found" while the file defines the entry is check_failed, never not_installed.
    @Test func codexAbsenceIsTrustedOnlyWhenPlain() throws {
        let f = try FakeAgents()
        let toml = "\"No MCP server named 'aistats' found\" = ????\n[mcp_servers.aistats]\ncommand = \"/foreign\"\nargs = [\"mcp\"]\n"
        try write(toml, f.codexConfig)
        let err = "Error: failed to load bootstrap configuration\n  1 | \"No MCP server named 'aistats' found\" = ????"
        let r = AgentRegistrar(binaryPath: "/x/aistats", environment: f.environment(["FAKE_CODEX_GET_ERR": err]))
        guard case .checkFailed = r.status(.codex).state else { Issue.record("parse error taken as absence"); return }
        #expect(!r.install(.codex).ok)
        // Plain "not found" while the file still defines the entry (Codex reading something else).
        let plain = AgentRegistrar(binaryPath: "/x/aistats", environment: f.environment())
        try write("[mcp_servers.aistats]\ncommand = \"/foreign\"\nargs = [\"mcp\"]\n", f.codexConfig)
        guard case .checkFailed = plain.status(.codex).state else { Issue.record("not found taken despite the file"); return }
        #expect(!plain.install(.codex).ok)
        #expect(!f.calls().contains { $0.hasPrefix("codex mcp add") || $0.hasPrefix("codex mcp remove") })
        // A file that only mentions another server is fine.
        try write("[mcp_servers.aistats-dev]\ncommand = \"/usr/local/bin/aistats\"\n", f.codexConfig)
        #expect(plain.status(.codex).state == .notInstalled)
    }

    /// Codex hides unknown TOML keys from `mcp get`; an entry with one is not ours to remove.
    @Test func codexHiddenSettingMakesTheEntryForeign() throws {
        let f = try FakeAgents()
        let reported = #"{"name":"aistats","enabled":true,"disabled_reason":null,"transport":{"type":"stdio","command":"/x/aistats","args":["mcp"],"env":null,"env_vars":[],"cwd":null},"enabled_tools":null,"disabled_tools":null,"startup_timeout_sec":null,"tool_timeout_sec":null}"#
        try write(reported, f.codexJSON)
        let toml = "[mcp_servers.aistats]\ncommand = \"/x/aistats\"\nargs = [\"mcp\"]\ncustom = \"foreign option\"\n"
        try write(toml, f.codexConfig)
        let r = AgentRegistrar(binaryPath: "/x/aistats", environment: f.environment())
        guard case .nameConflict(let what) = r.status(.codex).state else { Issue.record("hidden key ignored: \(r.status(.codex).state)"); return }
        #expect(what.contains("toml:custom"))
        #expect(!r.uninstall(.codex).ok)
        #expect(bytes(f.codexConfig) == Data(toml.utf8))
        // The shape `codex mcp add` writes (with the marker table) stays ours.
        try write("model = \"x\" # note\n\n[mcp_servers.aistats]\ncommand = \"/x/aistats\"\nargs = [\"mcp\"]\n\n[mcp_servers.aistats.env]\nAISTATS_MANAGED = \"1\"\n", f.codexConfig)
        #expect(r.status(.codex).state == .installed)
        // Other spellings are scanned too.
        let scan = try #require(CodexTOMLScan.scan(Data("'mcp_servers'.\"aistats\".cwd = '/t'\n[mcp_servers]\naistats.required = true\nx = \"\"\"\n[mcp_servers.aistats]\n\"\"\"\n".utf8)))
        #expect(scan.defined && Set(scan.extras) == ["required", "cwd"], "\(scan.extras)")
    }

    /// A7: Gemini reads settings.json as JSON with comments; what it rejects is check_failed.
    @Test func geminiConfigTheCLIRejectsIsCheckFailed() throws {
        let f = try FakeAgents()
        let config = f.root.appendingPathComponent("gemini/.gemini/settings.json")
        let rejected = "{'mcpServers':{},'mcp\\u0053ervers':{'aistats':{'command':'/foreign','args':['mcp']}}}"
        try write(rejected, config)
        let r = AgentRegistrar(binaryPath: "/x/aistats", environment: f.environment())
        guard case .checkFailed = r.status(.gemini).state else { Issue.record("expected check_failed: \(r.status(.gemini).state)"); return }
        #expect(!r.install(.gemini).ok)
        #expect(bytes(config) == Data(rejected.utf8))
        #expect(!f.calls().contains { $0.hasPrefix("gemini mcp") })
        // Comments are fine (and an entry inside them doesn't count).
        try write("{\n  // \"aistats\": {}\n  /* x */ \"mcpServers\": {\"u\": \"http://a//b\"}\n}\n", config)
        #expect(r.status(.gemini).state == .notInstalled)
        try write("{\"mcpServers\": {}, \"mcpServers\": {}}", config)
        guard case .checkFailed = r.status(.gemini).state else { Issue.record("duplicate keys"); return }
    }
}
