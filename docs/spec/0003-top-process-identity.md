# SDD 0003 · Top Process Identity

Status · Proposed
Issue · [#2](https://github.com/oozoofrog/aistats/issues/2)

## Purpose and scope

This specification adds Instance identity to the process rows that `aistats` returns. Each row of `get_top_processes` gets `startToken` and `ppid`. The embedded process lists of `get_system_stats`, `diagnose_system`, and `wait_for` get the same fields where the cost is low.

An agent can then pass a pid and `startToken` from `get_top_processes` directly to `wait_for` or `track_processes`. It does not need an extra `find_processes` call. The `startToken` guards against pid reuse between the calls.

The scope is the MCP tools and the CLI JSON output that share the row type. The text table and the AIStatsMenu Panel do not change.

The key words "MUST", "MUST NOT", "SHOULD", "SHOULD NOT", and "MAY" in this document are to be interpreted as described in BCP 14 [RFC2119] [RFC8174] when, and only when, they appear in all capitals.

[RFC2119]: https://www.rfc-editor.org/rfc/rfc2119.html
[RFC8174]: https://www.rfc-editor.org/rfc/rfc8174.html

Requirements use the ASD-STE100 sentence rules and the Terms below. Each active ID identifies one requirement sentence. A Withdrawn ID remains reserved. Tables named by a requirement give the acceptance data for that requirement. [ASD-STE100 Issue 9](https://www.asd-ste100.org/assets/files/ASD-STE100_ISSUE9.pdf)

## Terms

| Term | Meaning |
| --- | --- |
| Instance | One process, identified by pid and process start time. A reused pid is a different Instance. |
| startToken | The decimal string of the process start time (`ri_proc_start_abstime`). `find_processes` returns it now. |
| Process Row | One element of a process list in a tool result. |
| Top Row | A Process Row of `get_top_processes`. |
| Embedded List | A process list inside another result: `topProcesses` of `get_system_stats` and `diagnose_system`, and `culprits` of `wait_for`. |
| Returned Row | A Process Row that is in the result after sorting and the limit. |
| Compact JSON | JSON without insignificant white space, as in `structuredContent`. |

## Background and evidence

Current row content:

- A Top Row has only `pid`, `name`, `cpuPercent`, and `memoryBytes` ([Snapshot.swift:110-117](../../Sources/StatsCore/Snapshot.swift#L110-L117)).
- A `find_processes` row also has `startToken` and `ppid` ([ProcessFinder.swift:6-17](../../Sources/StatsCore/ProcessFinder.swift#L6-L17)). `startToken` is `String(ri_proc_start_abstime)` ([ProcessFinder.swift:82-91](../../Sources/StatsCore/ProcessFinder.swift#L82-L91)).
- The `startToken` argument says "From find_processes" ([MCPServer.swift:310](../../Sources/StatsCore/MCPServer.swift#L310)). The server instructions send the agent to `find_processes` for a `startToken` ([MCPServer.swift:293](../../Sources/StatsCore/MCPServer.swift#L293)).
- Thus a safe pid-based `wait_for` or `track_processes` after `get_top_processes` needs one more `find_processes` call.

Cost evidence:

- The process sampler already reads `ri_proc_start_abstime` for every process ([SystemSampler.swift:320](../../Sources/StatsCore/SystemSampler.swift#L320)). It drops the value when it builds the row ([SystemSampler.swift:328-329](../../Sources/StatsCore/SystemSampler.swift#L328-L329)). `startToken` needs no new system call.
- The sampler re-reads names only for Returned Rows ([SystemSampler.swift:93-106](../../Sources/StatsCore/SystemSampler.swift#L93-L106)). A ppid read for Returned Rows can follow the same pattern.
- `Proc.parent` reads the ppid with one `proc_pidinfo` call ([Proc.swift:105-110](../../Sources/StatsCore/Proc.swift#L105-L110)).

Where the row type appears:

- `get_top_processes` returns up to 50 rows ([MCPServer.swift:433-439](../../Sources/StatsCore/MCPServer.swift#L433-L439)).
- `get_system_stats` embeds the top 5 rows ([MCPServer.swift:430](../../Sources/StatsCore/MCPServer.swift#L430)).
- `diagnose_system` embeds the top 3 rows ([Diagnosis.swift:22](../../Sources/StatsCore/Diagnosis.swift#L22), [Diagnosis.swift:97](../../Sources/StatsCore/Diagnosis.swift#L97)).
- `wait_for` culprits have `pid`, `name`, and `cpuPercent` ([Waiter.swift:34-39](../../Sources/StatsCore/Waiter.swift#L34-L39)). The server builds them from an Instance key that holds the start time ([Waiter.swift:392-394](../../Sources/StatsCore/Waiter.swift#L392-L394)).
- The CLI `top` and `stats` commands print the same rows as JSON ([main.swift:96-108](../../Sources/aistats/main.swift#L96-L108)). CLI `top` accepts a limit up to 200 ([main.swift:104](../../Sources/aistats/main.swift#L104)).
- AIStatsMenu keeps the top rows for the Panel ([AppModel.swift:14](../../Sources/AIStatsMenu/AppModel.swift#L14)). A Panel Fixture decodes rows without the new fields ([PanelFixtures.swift:20-24](../../Sources/AIStatsMenu/PanelFixtures.swift#L20-L24)).

Size evidence (built binary v0.3.0, one machine):

- `get_top_processes` with limit 50 produced 3,932 bytes of `structuredContent`. That is about 79 bytes per row.
- Estimate, not measured: `startToken` adds about 30 to 40 bytes per row, and `ppid` adds about 10 to 15 bytes. The token length depends on uptime and the timebase.

## Requirements

### Top Rows

| ID | Requirement | Acceptance check |
| --- | --- | --- |
| TOP-001 | Each Top Row MUST include `startToken` when the start time is readable. | Stdio probe: `get_top_processes` with limit 10. Expect a string `startToken` in each row. |
| TOP-002 | The `startToken` of a Top Row MUST equal the `find_processes` `startToken` of the same Instance. | Unit test: find the test process in `get_top_processes` output. Compare with `ProcessFinder.find(.pid(ownPid, startToken: nil))`. |
| TOP-003 | The `startToken` MUST identify the Instance whose `cpuPercent` and `memoryBytes` the row reports. | Unit test with an injected process source that reuses a pid between sampling and output. Expect the sampled start time in the row, or no row. |
| TOP-004 | Each Top Row MUST include the integer `ppid` when the parent pid is readable. | Inspect the TOP-001 result. Compare each `ppid` with `ps -o ppid= -p <pid>`. |
| TOP-005 | A row MUST omit `startToken` or `ppid` when the value cannot be read. | Unit test with an injected reader that fails for one pid. Expect the key to be absent. |
| TOP-006 | A row MUST NOT report 0, -1, or an empty string as a placeholder for an unreadable value. | Covered by the TOP-005 test. Expect no placeholder value. |
| TOP-007 | The server MUST read `ppid` only for Returned Rows. | Unit test with a counting parent reader. Call with limit 5 on a list of 300 processes. Expect at most 5 reads. |
| TOP-008 | Each Top Row SHOULD grow by 60 bytes or less in Compact JSON. | Encode 50 rows before and after the change. Divide the difference by 50. The 60-byte value is a budget. |

### Embedded Lists

| ID | Requirement | Acceptance check |
| --- | --- | --- |
| TOP-009 | The `topProcesses` rows of `get_system_stats` MUST follow TOP-001 to TOP-007. | Stdio probe: `get_system_stats`. Inspect each `topProcesses` row. |
| TOP-010 | The `topProcesses` rows of `diagnose_system` MUST follow TOP-001 to TOP-007. | Stdio probe: `diagnose_system`. Inspect each `topProcesses` row. |
| TOP-011 | Each `wait_for` culprit MUST include `startToken`. | Stdio probe: `cpu_idle` with `belowPercent` 0 and `timeoutSeconds` 3. Expect a `startToken` in each culprit. |
| TOP-012 | Each `wait_for` culprit SHOULD include `ppid` when the Instance still runs. | Inspect the TOP-011 result. A culprit that exited has no `ppid`. |

### Agent workflow and compatibility

| ID | Requirement | Acceptance check |
| --- | --- | --- |
| TOP-013 | `wait_for` and `track_processes` MUST accept the pid and `startToken` of a Top Row without a `find_processes` call. | Stdio probe: spawn a busy child, such as `yes > /dev/null`. Read its Top Row. Call `wait_for` `process_exit` with that pid and `startToken`. Stop the child. Expect `met`. Repeat with `track_processes` `start`. |
| TOP-014 | The CLI JSON output of `top` and `stats` MUST include the same fields. | Run `aistats top --json` and `aistats stats --json`. Inspect each row. |
| TOP-015 | The CLI text table of `aistats top` SHOULD NOT change. | Compare the text output columns before and after the change. |
| TOP-016 | The row decoder MUST accept rows without `startToken` and `ppid`. | `PanelFixtures.screen()` decodes without error. A unit test decodes a v0.3.0 `get_system_stats` JSON sample. |
| TOP-017 | AIStatsMenu SHOULD NOT read `ppid` for the Panel. | Run the 60-second CPU check of SDD 0001. Expect no increase over its budget. |
| TOP-018 | The `startToken` argument description SHOULD name `get_top_processes` as a source. | Read the `startToken` property description in `tools/list`. |

## Non-goals

- Executable path or arguments in Top Rows. `find_processes` gives the path.
- New fields in `track_processes` member rows. They already have `startToken` ([ProcessTracker.swift:45-47](../../Sources/StatsCore/ProcessTracker.swift#L45-L47)).
- Changes to the sort order, the limits, or the CPU measurement.
- New columns in the AIStatsMenu Panel.
- Process rows for other users.

## Dependencies and related specs

- [SDD 0005 · Response Size Budget](0005-response-size-budget.md) sets the byte budget for `structuredContent`. This specification adds about 40 to 55 bytes per row (estimate). With limit 50, `get_top_processes` can grow from 3,932 bytes to more than 4 KiB. RSZ-001 of SDD 0005 applies to the larger rows.
- [SDD 0002 · Port Lookup](0002-port-lookup.md) and [SDD 0006 · Wait-for Conditions](0006-wait-for-conditions.md) return process rows with the same `startToken` and `ppid` fields.
- [SDD 0009 · Agent Sessions over MCP](0009-agent-sessions-mcp.md) attributes processes to agent sessions by ancestor walk. `ppid` in Top Rows is the first step of that walk.
- [SDD 0011 · Instructions Priority](0011-instructions-priority.md) controls the server instructions. The `find_processes` line at [MCPServer.swift:293](../../Sources/StatsCore/MCPServer.swift#L293) can mention `get_top_processes` as a `startToken` source within the 0011 size cap.
- [SDD 0012 · Schema Deduplication](0012-schema-dedup.md) controls description growth. TOP-018 changes a shared selector description.
- [SDD 0001 · Cyberpunk Panel](0001-cyberpunk-panel.md) owns the AIStatsMenu CPU budget that TOP-017 protects.

## Open questions

- The `startToken` length was not measured. It depends on uptime and the Mach timebase.
- The `ppid` of a Top Row can be stale when the parent exits after the read. The process then has ppid 1. This specification does not require a recheck.
- The name of a Top Row is re-read after sampling ([SystemSampler.swift:99-105](../../Sources/StatsCore/SystemSampler.swift#L99-L105)). After a pid reuse in that interval, the name can belong to the new Instance. TOP-003 makes the row consistent. The exact rule, drop the row or skip the name refresh, is not decided.
- The extra latency of `ppid` reads for 50 rows was not measured. One `proc_pidinfo` call per row is expected to be cheap.
