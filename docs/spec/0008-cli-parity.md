# SDD 0008 · CLI Parity

Status · Proposed
Issue · [#7](https://github.com/oozoofrog/aistats/issues/7)

## Purpose and scope

This specification adds four CLI commands: `aistats find`, `aistats diagnose`, `aistats env`, and `aistats wait`. They mirror the MCP tools `find_processes`, `diagnose_system`, `get_environment`, and `wait_for`. An agent without the MCP server, a shell script, a hook, or a person can then get the same results from a shell. Each command has a text output, a `--json` output, and exit statuses that a script can test.

The scope is command names, options, output formats, and exit statuses. The existing commands keep their current behavior.

The key words "MUST", "MUST NOT", "SHOULD", "SHOULD NOT", and "MAY" in this document are to be interpreted as described in BCP 14 [RFC2119] [RFC8174] when, and only when, they appear in all capitals.

[RFC2119]: https://www.rfc-editor.org/rfc/rfc2119.html
[RFC8174]: https://www.rfc-editor.org/rfc/rfc8174.html

## Terms

| Term | Meaning |
| --- | --- |
| Mirrored Tool | One of `find_processes`, `diagnose_system`, `get_environment`, and `wait_for`. |
| New Command | One of `find`, `diagnose`, `env`, and `wait`. |
| Structured Result | The `structuredContent` object that a Mirrored Tool returns for a successful call. |
| Summary Line | The first line of the text content of a Mirrored Tool result. |
| Outcome | The result state of a command: positive, negative, or unknown, as in Table 2. |

## Background and evidence

| Fact | Evidence |
| --- | --- |
| The CLI commands are stats, top, history, agents, mcp, status, install, uninstall, track, and setup. No command mirrors the four Mirrored Tools. | [main.swift:4](../../Sources/aistats/main.swift#L4) to [main.swift:28](../../Sources/aistats/main.swift#L28), [main.swift:95](../../Sources/aistats/main.swift#L95) to [main.swift:181](../../Sources/aistats/main.swift#L181) |
| `find_processes` reads a selector and a limit from 1 to 15, default 8. | [MCPServer.swift:466](../../Sources/StatsCore/MCPServer.swift#L466) to [MCPServer.swift:476](../../Sources/StatsCore/MCPServer.swift#L476), [ProcessFinder.swift:43](../../Sources/StatsCore/ProcessFinder.swift#L43) |
| `find_processes` drops rows until the response line fits 4,096 bytes. | [MCPServer.swift:471](../../Sources/StatsCore/MCPServer.swift#L471) to [MCPServer.swift:475](../../Sources/StatsCore/MCPServer.swift#L475), [MCPServer.swift:14](../../Sources/StatsCore/MCPServer.swift#L14) |
| A find row lists unreadable fields in `unreadable` and never reports them as 0. | [ProcessFinder.swift:5](../../Sources/StatsCore/ProcessFinder.swift#L5) to [ProcessFinder.swift:17](../../Sources/StatsCore/ProcessFinder.swift#L17) |
| `diagnose_system` takes `purpose` `slowdown` or `heavy_work` and measures for about 1 s. | [MCPServer.swift:459](../../Sources/StatsCore/MCPServer.swift#L459) to [MCPServer.swift:464](../../Sources/StatsCore/MCPServer.swift#L464), [Diagnosis.swift:101](../../Sources/StatsCore/Diagnosis.swift#L101) to [Diagnosis.swift:107](../../Sources/StatsCore/Diagnosis.swift#L107) |
| Diagnosis status is `issue_detected`, `no_clear_issue`, or `insufficient_data`. Heavy work readiness is `ready`, `caution`, or `unknown`. | [Diagnosis.swift:15](../../Sources/StatsCore/Diagnosis.swift#L15) to [Diagnosis.swift:18](../../Sources/StatsCore/Diagnosis.swift#L18) |
| `get_environment` takes `includeToolchain`, default true. The toolchain probe runs `xcrun swift --version` with a 15 s timeout. Its cache lives 300 s in one process, so each CLI run probes again. | [MCPServer.swift:481](../../Sources/StatsCore/MCPServer.swift#L481) to [MCPServer.swift:492](../../Sources/StatsCore/MCPServer.swift#L492), [Diagnosis.swift:150](../../Sources/StatsCore/Diagnosis.swift#L150), [Diagnosis.swift:212](../../Sources/StatsCore/Diagnosis.swift#L212) |
| `wait_for` parses `condition`, `belowPercent`, `trackId`, a selector, and `timeoutSeconds` from 1 to 55, default 20. | [MCPServer.swift:566](../../Sources/StatsCore/MCPServer.swift#L566) to [MCPServer.swift:567](../../Sources/StatsCore/MCPServer.swift#L567), [MCPServer.swift:773](../../Sources/StatsCore/MCPServer.swift#L773) to [MCPServer.swift:803](../../Sources/StatsCore/MCPServer.swift#L803), [Waiter.swift:71](../../Sources/StatsCore/Waiter.swift#L71) |
| Wait states are `met`, `timed_out`, and `unavailable`. A blocking `Waiter.run()` exists for the CLI and tests. | [Waiter.swift:41](../../Sources/StatsCore/Waiter.swift#L41) to [Waiter.swift:42](../../Sources/StatsCore/Waiter.swift#L42), [Waiter.swift:148](../../Sources/StatsCore/Waiter.swift#L148) to [Waiter.swift:155](../../Sources/StatsCore/Waiter.swift#L155) |
| Track ids belong to the track manager of one MCP session. `aistats track` runs a track in the foreground. | [MCPServer.swift:785](../../Sources/StatsCore/MCPServer.swift#L785) to [MCPServer.swift:787](../../Sources/StatsCore/MCPServer.swift#L787), [main.swift:312](../../Sources/aistats/main.swift#L312) to [main.swift:380](../../Sources/aistats/main.swift#L380) |
| The selector rules (exactly one of pid, name, path; `startToken` only with pid; `argsContain` only with name or path) are shared by the MCP server and `aistats track`. Their messages use MCP argument names. | [Proc.swift:316](../../Sources/StatsCore/Proc.swift#L316) to [Proc.swift:346](../../Sources/StatsCore/Proc.swift#L346), [main.swift:318](../../Sources/aistats/main.swift#L318) to [main.swift:320](../../Sources/aistats/main.swift#L320) |
| `wait_for` applies condition-specific argument rules. `process_exit` needs `pid`. `argsContain` goes only with a name or path selector of `cpu_idle`. `trackId` excludes a selector. | [MCPServer.swift:777](../../Sources/StatsCore/MCPServer.swift#L777) to [MCPServer.swift:797](../../Sources/StatsCore/MCPServer.swift#L797) |
| The argument parser stores an unknown `--option` as a flag without an error. `aistats track` rejects unknown flags itself. | [main.swift:44](../../Sources/aistats/main.swift#L44) to [main.swift:46](../../Sources/aistats/main.swift#L46), [main.swift:331](../../Sources/aistats/main.swift#L331) to [main.swift:332](../../Sources/aistats/main.swift#L332) |
| The argument parser rejects every positional argument. | [main.swift:37](../../Sources/aistats/main.swift#L37) |
| Every CLI error exits with status 1 and writes `aistats: <message>` to stderr. | [main.swift:184](../../Sources/aistats/main.swift#L184) to [main.swift:189](../../Sources/aistats/main.swift#L189) |
| CLI JSON is pretty-printed with sorted keys and ISO 8601 dates. | [main.swift:65](../../Sources/aistats/main.swift#L65) to [main.swift:74](../../Sources/aistats/main.swift#L74) |

Claude Code documents that exit status 2 from a `PreToolUse` command hook blocks the tool call. A New Command can run inside a hook. Exit status 2 is therefore reserved.

### Table 1 · Exit statuses

| Status | Meaning |
| --- | --- |
| 0 | Success with a positive Outcome. |
| 1 | Error: an invalid argument, an unreadable data source, or an internal failure. This is the current CLI behavior. |
| 3 | Negative Outcome. |
| 4 | Unknown Outcome. |
| 130 | Interrupted by SIGINT. |

Status 2 is not used.

### Table 2 · Outcomes

| Command | Status 0 | Status 3 | Status 4 |
| --- | --- | --- | --- |
| `find` | one or more rows | no row | not used |
| `diagnose` (purpose `slowdown`) | `no_clear_issue` | `issue_detected` | `insufficient_data` |
| `diagnose --purpose heavy_work` | readiness `ready` | readiness `caution` | readiness `unknown` |
| `env` | report printed | not used | not used |
| `wait` | `met` | `timed_out` | `unavailable` |

### Table 3 · Options

Ranges and defaults equal the MCP input schema. A wait condition added by another spec adds its arguments here with the same rule.

| Mirrored Tool argument | CLI option | Values |
| --- | --- | --- |
| `find_processes.pid` | `find --pid N` | 1 or more |
| `find_processes.startToken` | `find --start-token T` | token from a find result |
| `find_processes.name` | `find --name NAME` | 1 to 64 characters |
| `find_processes.path` | `find --path PATH` | absolute path |
| `find_processes.match` | `find --match exact\|glob` | default `exact` |
| `find_processes.argsContain` | `find --args-contain TEXT` | 1 to 128 characters |
| `find_processes.limit` | `find --limit N` | 1 to 15, default 8 |
| `diagnose_system.purpose` | `diagnose --purpose slowdown\|heavy_work` | default `slowdown` |
| `get_environment.includeToolchain` | `env --no-toolchain` | sets the value to false |
| `wait_for.condition` | `wait CONDITION` (positional) | the `wait_for` condition names |
| `wait_for.belowPercent` | `wait --below P` | 0 to 10000, default 20 |
| `wait_for.timeoutSeconds` | `wait --timeout S` | 1 to 55, default 20 |
| `wait_for` selector | `wait --pid`, `--start-token`, `--name`, `--path`, `--match`, `--args-contain` | values as for `find`; combination rules as `wait_for` |
| `wait_for.trackId` | none | rejected, see CLI-016 |

## Requirements

### Commands and options

| ID | Requirement | Acceptance check |
| --- | --- | --- |
| CLI-001 | The CLI MUST provide the `find`, `diagnose`, `env`, and `wait` commands. | Run each command with valid options. Verify a result and an exit status from Table 1. |
| CLI-002 | `aistats help` MUST list each New Command with its options. | Run `aistats help`. Compare the listed options with Table 3. |
| CLI-003 | Each New Command MUST accept the Table 3 options with the Table 3 ranges and defaults. | Boundary probes: `find --limit` 0, 1, 15, 16; `wait --timeout` 0.9, 1, 55, 55.1; `wait --below` -1, 0, 10000, 10001. Verify status 1 outside each range and a result inside it. |
| CLI-004 | Each New Command MUST reject an option that Table 3 does not list for it, with status 1. | Run `aistats find --name zsh --bogus`. Verify status 1 and a stderr message that names `--bogus`. Repeat for each New Command. |
| CLI-005 | Each New Command except `wait` MUST reject a positional argument with status 1. | Run `aistats diagnose now`. Verify status 1. |
| CLI-006 | `find` and `wait` MUST apply the same argument rules as their Mirrored Tool. | For `find`, probe two selectors, `--start-token` without `--pid`, `--args-contain` with `--pid`, and `--match glob` with `--pid`. For `wait`, probe `process_exit --name zsh` and `process_exit --pid 1 --args-contain x`. Verify status 1 for each, and the same accept or reject result as the MCP tool. |
| CLI-007 | A selector error message SHOULD name the CLI option, such as `--start-token`, not the MCP argument. | Run `aistats find --name zsh --start-token 1`. Verify that stderr contains `--start-token`. |
| CLI-008 | `env --no-toolchain` MUST NOT start a subprocess. | Inspect the call graph for `--no-toolchain`. Verify that the JSON output has no `toolchain` key. |
| CLI-009 | The New Commands MUST work without the AIStats app and without an MCP session. | Set `AISTATS_HOME` to a new empty folder with the app not running. Run each New Command. Verify a status other than 1. |

### Output

| ID | Requirement | Acceptance check |
| --- | --- | --- |
| CLI-010 | With `--json`, stdout MUST be one JSON object with the key paths and value types of the Structured Result. | For each Mirrored Tool, call it over stdio with fixed arguments and run the New Command with the same arguments. Compare the sets of key paths and the JSON type at each path. Values can differ. |
| CLI-011 | `--json` output SHOULD use the existing CLI JSON format: pretty-printed, sorted keys, ISO 8601 dates. | Compare the format with `aistats stats --json`. |
| CLI-012 | `find` MUST NOT drop rows to fit a byte limit. | Run `aistats find --name '*' --match glob --limit 15 --json` when more than 15 processes match. Verify 15 rows and `truncated` true. |
| CLI-013 | Without `--json`, the first stdout line MUST be the Summary Line of the Mirrored Tool. | Unit test the text renderer with a fixture result. Compare its first line with the `summaryLine` of the same result. |
| CLI-014 | Without `--json`, `find` MUST print a table with the columns PID, START TOKEN, PPID, MEMORY, and NAME. It MUST add PATH when the selector is `--path`. | Run with `--pid` of the shell and with `--path`. Verify the header and one row per process. |
| CLI-015 | `find` text output MUST print `?` for an unreadable field, never 0. | Run `aistats find --pid 1`. Verify `?` in the START TOKEN and MEMORY columns. |

### Wait

| ID | Requirement | Acceptance check |
| --- | --- | --- |
| CLI-016 | `wait` MUST reject `--track-id` with status 1 and a message that tracks exist only in an MCP session. | Run `aistats wait cpu_idle --track-id t1`. Verify status 1 and the message. |
| CLI-017 | `wait` MUST accept every condition that `wait_for` accepts in the same release. | Unit test: read the `condition` enum from the `wait_for` input schema. Verify that the CLI parser accepts each value. |
| CLI-018 | `wait` MUST write its result once, after the wait ends. | Run `aistats wait memory_pressure_normal --timeout 5` through a pipe. Verify one result and no output before the end. |
| CLI-019 | On SIGINT, `wait` MUST stop, write nothing to stdout, and exit with status 130. | Start `aistats wait cpu_idle --below 0 --timeout 30`. Send SIGINT after 2 s. Verify status 130, empty stdout, and an exit within 1 s of the signal. |

### Exit status and parity

| ID | Requirement | Acceptance check |
| --- | --- | --- |
| CLI-020 | Each New Command MUST exit with the status that Table 1 and Table 2 give for its Outcome. | Probes: `find --name no-such-process-xyz` gives 3. `find --pid` of the shell gives 0. `wait process_exit --pid` of a process that exits in 1 s gives 0. `wait cpu_idle --below 0 --timeout 3` gives 3. `wait process_exit --pid 999999` gives 4. `env` gives 0. |
| CLI-021 | A New Command MUST NOT exit with status 2. | Review every exit path. Run the CLI-020 probes and the error probes. Verify that no run gives status 2. |
| CLI-022 | A New Command MUST write error messages to stderr with the prefix `aistats: `. | Run each error probe. Verify empty stdout and the prefix on stderr. |
| CLI-023 | A release that adds an argument to a Mirrored Tool MUST add its CLI option in the same release. | Unit test: compare the input schema property names of each Mirrored Tool with a CLI option table in StatsCore. The test fails for a property without a mapped option. `wait_for.trackId` is the only allowed exception. |

## Non-goals

- New exit statuses for the existing commands.
- CLI commands for `get_system_stats`, `get_top_processes`, and `get_stats_history`. `stats`, `top`, and `history` exist.
- Background tracks or a CLI form of `track_processes` actions `status`, `stop`, and `list`.
- A wait longer than the `wait_for` maximum of 55 s.
- Records of CLI runs in the agents activity log.
- Fixes to the silent acceptance of unknown flags by the existing commands.
- Shell completion scripts.

## Dependencies and related specs

- [SDD 0002](0002-port-lookup.md) adds a `port` selector and the `port_listening` condition. CLI-017 and CLI-023 then require `find --port N` and `wait port_listening`.
- [SDD 0006](0006-wait-for-conditions.md) adds wait conditions and their arguments. CLI-017 and CLI-023 apply to them.
- [SDD 0004](0004-summary-facts-in-json.md) moves summary-only facts into the Structured Result. `--json` output then carries the same facts as the text output.
- [SDD 0005](0005-response-size-budget.md) sets an MCP byte budget. It does not apply to the CLI (CLI-012).
- [SDD 0007](0007-preflight-hook.md) uses Table 1 and names `aistats wait` and `aistats diagnose` in its hook output.

## Open questions

- Should the CLI allow a wait longer than 55 s? Agent shells have their own command timeouts, and these are not measured here.
- Should the existing commands adopt statuses 3 and 4 in a later release?
- CLI-010 compares key paths and types only. Optional keys that are absent in one run can make the comparison noisy. The check needs fixtures that produce each optional key.
- The selector error messages come from shared code that the MCP server also uses. CLI-007 can need a mapping layer in the CLI.
