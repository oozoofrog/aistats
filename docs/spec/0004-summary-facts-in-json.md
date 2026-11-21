# SDD 0004 · Summary Facts in Structured Content

Status · Proposed
Issue · [#3](https://github.com/oozoofrog/aistats/issues/3)

## Purpose and scope

This specification covers the successful results of the eight `aistats` MCP tools and the output of `aistats history --json`. Each tool result has a Summary in its Text block and a JSON object in Structured content. Some MCP clients give the model only Structured content. In those clients, a Fact that exists only in the Summary does not reach the model. This specification requires every Fact in a Summary to be present in Structured content. It keeps the serialized JSON copy in the Text block, as the MCP specification recommends. It does not change tool names, tool arguments, sampling, or the Summary wording.

The key words "MUST", "MUST NOT", "SHOULD", "SHOULD NOT", and "MAY" in this document are to be interpreted as described in BCP 14 [RFC2119] [RFC8174] when, and only when, they appear in all capitals.

[RFC2119]: https://www.rfc-editor.org/rfc/rfc2119.html
[RFC8174]: https://www.rfc-editor.org/rfc/rfc8174.html

Requirements use the ASD-STE100 sentence rules and the Terms below. Each active ID identifies one requirement sentence. A Withdrawn ID remains reserved.

## Terms

| Term | Meaning |
| --- | --- |
| Result | The `result` object of a `tools/call` response with `isError` false. |
| Structured content | The `structuredContent` object of a Result. |
| Text block | `content[0]` of a Result. Its type is `text`. |
| Summary | The part of the Text block before the serialized JSON. |
| Fact | A value, state, cause, or next action that a reader can act on. A different format or unit of a value that is already in Structured content is not a separate Fact. |
| Summary-only Fact | A Fact in the Summary that a reader cannot derive from Structured content. |
| Placeholder | A value that the server writes into a field for a metric that it could not read. |
| Hint | A Fact that tells the reader a next action or an interpretation, not a measured value. |

## Background and evidence

### Result construction

- `toolResult` writes a multi-line Summary, a blank line, and the JSON into the Text block. It puts the same JSON bytes into Structured content. See [MCPServer.swift:605](../../Sources/StatsCore/MCPServer.swift#L605) to [MCPServer.swift:613](../../Sources/StatsCore/MCPServer.swift#L613).
- `leanResult` writes one summary line, a newline, and the compact JSON. It also puts the JSON into Structured content. See [MCPServer.swift:615](../../Sources/StatsCore/MCPServer.swift#L615) to [MCPServer.swift:624](../../Sources/StatsCore/MCPServer.swift#L624).
- `get_system_stats`, `get_top_processes`, and `get_stats_history` use `toolResult`. See [MCPServer.swift:431](../../Sources/StatsCore/MCPServer.swift#L431), [MCPServer.swift:439](../../Sources/StatsCore/MCPServer.swift#L439), [MCPServer.swift:451](../../Sources/StatsCore/MCPServer.swift#L451), and [MCPServer.swift:457](../../Sources/StatsCore/MCPServer.swift#L457). The other five tools use `leanResult`.
- Structured content is present only when the JSON starts with `{`. See [MCPServer.swift:611](../../Sources/StatsCore/MCPServer.swift#L611) and [MCPServer.swift:622](../../Sources/StatsCore/MCPServer.swift#L622). All current result types encode as objects.
- Error results carry only text and no Structured content. See [MCPServer.swift:626](../../Sources/StatsCore/MCPServer.swift#L626).
- No tool declares `outputSchema`. See the tool list at [MCPServer.swift:318](../../Sources/StatsCore/MCPServer.swift#L318).

### Client behavior

- The MCP specification, revisions 2025-06-18 and 2025-11-25, says that a tool that returns structured content SHOULD also return the serialized JSON in a TextContent block. [MCP tools: structured content](https://modelcontextprotocol.io/specification/2025-06-18/server/tools#structured-content)
- One observation on Claude Code 2.1.328 showed that the model received only Structured content. The Summary did not reach the model. This was observed once. It was not checked for other clients.
- Consequence: removal of the JSON copy from the Text block saves no model tokens in that client. That proposal is rejected. A Summary-only Fact is lost in that client.

### Table 1 · Summary audit of current source

| Tool and branch | Fact in the Summary | Summary source | Structured content today | Gap |
| --- | --- | --- | --- | --- |
| `get_stats_history`, no points in the window | The window length in minutes | [MCPServer.swift:452](../../Sources/StatsCore/MCPServer.swift#L452) | `recording` only ([MCPServer.swift:453](../../Sources/StatsCore/MCPServer.swift#L453)) | Summary-only Fact |
| `get_stats_history`, no points, `recording` false | Start command `open -b <appBundleIdentifier>` | [MCPServer.swift:450](../../Sources/StatsCore/MCPServer.swift#L450), [Store.swift:15](../../Sources/StatsCore/Store.swift#L15) | None | Summary-only Fact |
| `get_stats_history`, no points | `get_system_stats` works without the app | [MCPServer.swift:452](../../Sources/StatsCore/MCPServer.swift#L452) | None | Summary-only Fact |
| `get_stats_history`, no points, `recording` true | The app runs but has not recorded this window | [MCPServer.swift:449](../../Sources/StatsCore/MCPServer.swift#L449) | `recording` true, `summary` absent | None. The state is derivable. |
| `get_stats_history`, points present, `recording` false | The history ends at the last recorded sample | [MCPServer.swift:456](../../Sources/StatsCore/MCPServer.swift#L456) | `recording` false, `summary.to` | Hint wording only |
| `get_system_stats`, CPU unreadable | CPU usage could not be measured | [Snapshot.swift:156](../../Sources/StatsCore/Snapshot.swift#L156) | `unavailable` has `cpu`. `cpu.usagePercent`, `userPercent`, and `systemPercent` are 0 ([SystemSampler.swift:116](../../Sources/StatsCore/SystemSampler.swift#L116) to [SystemSampler.swift:122](../../Sources/StatsCore/SystemSampler.swift#L122)) | Placeholder contradicts the Summary |
| `get_system_stats`, memory unreadable | Memory usage could not be read | [Snapshot.swift:163](../../Sources/StatsCore/Snapshot.swift#L163) | Used, app, wired, compressed, and cached bytes are 0. `usedPercent` is 0 ([SystemSampler.swift:166](../../Sources/StatsCore/SystemSampler.swift#L166) to [SystemSampler.swift:169](../../Sources/StatsCore/SystemSampler.swift#L169)) | Placeholder contradicts the Summary |
| `get_system_stats`, swap unreadable | Swap is unknown | [Snapshot.swift:159](../../Sources/StatsCore/Snapshot.swift#L159) | `swapUsedBytes` is 0 ([SystemSampler.swift:161](../../Sources/StatsCore/SystemSampler.swift#L161) to [SystemSampler.swift:162](../../Sources/StatsCore/SystemSampler.swift#L162)) | Placeholder contradicts the Summary |
| `get_system_stats`, network unreadable or first reading | Network throughput not measured | [Snapshot.swift:173](../../Sources/StatsCore/Snapshot.swift#L173) | Rates are 0. Totals are 0 and `interfaces` is empty when the counters are unreadable ([SystemSampler.swift:261](../../Sources/StatsCore/SystemSampler.swift#L261), [SystemSampler.swift:271](../../Sources/StatsCore/SystemSampler.swift#L271)) | Placeholder contradicts the Summary |
| `get_system_stats`, memory pressure unreadable | Pressure is unknown | [Snapshot.swift:158](../../Sources/StatsCore/Snapshot.swift#L158) | `memory.pressure` is `unknown` | None |
| `get_system_stats`, disk unreadable | Disk free space could not be read | [Snapshot.swift:168](../../Sources/StatsCore/Snapshot.swift#L168) | `disk` absent, `unavailable` has `disk` ([SystemSampler.swift:76](../../Sources/StatsCore/SystemSampler.swift#L76)) | None |
| `get_top_processes` | Table of pid, CPU, memory, and name | [MCPServer.swift:806](../../Sources/StatsCore/MCPServer.swift#L806) | Same rows in `processes` | None |
| `diagnose_system` | Status, readiness, evidence, busiest process | [Diagnosis.swift:35](../../Sources/StatsCore/Diagnosis.swift#L35) | Same fields | None |
| `find_processes` | Match count, shown rows, note, skipped count | [ProcessFinder.swift:32](../../Sources/StatsCore/ProcessFinder.swift#L32) | Same fields | None |
| `track_processes` | Track state, members, CPU, footprint, restarts, forks, spikes | [ProcessTracker.swift:199](../../Sources/StatsCore/ProcessTracker.swift#L199) | Same fields | None |
| `wait_for` | State, elapsed time, last observation, culprits, reason | [Waiter.swift:55](../../Sources/StatsCore/Waiter.swift#L55) | Same fields | None |
| `get_environment` | macOS, chip, RAM, cores, Xcode, Swift | [Diagnosis.swift:136](../../Sources/StatsCore/Diagnosis.swift#L136) | Same fields | None |

The `Snapshot` type documents that Placeholder fields "must not be read as real zeros". See [Snapshot.swift:103](../../Sources/StatsCore/Snapshot.swift#L103). The model does not see that source comment.

### CLI

`aistats history --json` prints only the history summary object. It has no `recording` field. When the window has no points, the output has no history object. See [main.swift:114](../../Sources/aistats/main.swift#L114) to [main.swift:115](../../Sources/aistats/main.swift#L115). The start Hint exists only in the text output. See [main.swift:118](../../Sources/aistats/main.swift#L118) and [main.swift:120](../../Sources/aistats/main.swift#L120).

## Requirements

### General rule

| ID | Requirement | Acceptance check |
| --- | --- | --- |
| SUM-001 | Each Fact in a Summary MUST also be present in the Structured content of the same Result. | For each row of Table 1, drive the branch with a Fixture. Assert the field named by SUM-004 to SUM-012. Repeat the Table 1 audit for each change to a Summary builder. |
| SUM-002 | Each Result MUST include Structured content as a JSON object. | Call each of the eight tools with default arguments in the MCP test harness. Assert that `structuredContent` is an object. |
| SUM-003 | The Text block MUST end with the JSON serialization of the Structured content. | Split the Text block at the start of the trailing JSON. Decode both JSON values. Assert that they are equal. |
| SUM-004 | A Hint without a typed field MUST appear as one string in a `notes` array in Structured content. | Fixture with points and `recording` false. Assert that `notes` has the history-end Hint. |

### get_stats_history

| ID | Requirement | Acceptance check |
| --- | --- | --- |
| SUM-005 | Structured content MUST include `minutes`, the window length that the server used. | Call with `minutes` 7 and an empty history directory. Assert `minutes` is 7. |
| SUM-006 | When `recording` is false, Structured content MUST include `startCommand`. | Empty history directory. Assert `startCommand` is present. |
| SUM-007 | The `startCommand` value MUST be `open -b` followed by `AIStatsPaths.appBundleIdentifier`. | Compare the value with the constant at [Store.swift:15](../../Sources/StatsCore/Store.swift#L15). |
| SUM-008 | When the window has no points, Structured content MUST include `fallbackTool` with the value `get_system_stats`. | Empty history directory. Assert `fallbackTool`. Write one point that is 2 hours old. Call with `minutes` 60. Assert `fallbackTool` again. |
| SUM-009 | When the window has points, Structured content MUST NOT include `fallbackTool`. | Fixture with 300 recent points. Assert that `fallbackTool` is absent. |

### get_system_stats

| ID | Requirement | Acceptance check |
| --- | --- | --- |
| SUM-010 | For each metric in `unavailable`, Structured content MUST NOT give a Placeholder as a number. | Force each read in Table 2 to fail through a test seam. Assert that no listed field is a number. |
| SUM-011 | Each Placeholder field in Table 2 MUST be `null` in Structured content. | Same test. Assert `null` for each listed field. |
| SUM-012 | Fields that the server read successfully MUST keep their current names and types. | Same test. Assert that `memory.totalBytes`, `cpu.logicalCores`, and the load averages are numbers. |

### Table 2 · Placeholder fields

| Metric in `unavailable` | Fields that become `null` |
| --- | --- |
| `cpu` | `cpu.usagePercent`, `cpu.userPercent`, `cpu.systemPercent` |
| `memory` | `memory.usedBytes`, `memory.appBytes`, `memory.wiredBytes`, `memory.compressedBytes`, `memory.cachedBytes`, `memory.usedPercent` |
| `swap` | `memory.swapUsedBytes` |
| `network`, counters readable | `network.receivedBytesPerSecond`, `network.sentBytesPerSecond` |
| `network`, counters unreadable | The two rates, `network.receivedTotalBytes`, `network.sentTotalBytes`, `network.interfaces` |

`memory.pressure` keeps the string `unknown`. `disk` stays absent. These fields already agree with the Summary.

### Size and CLI

| ID | Requirement | Acceptance check |
| --- | --- | --- |
| SUM-013 | Fields added by this specification MUST keep each Result within the budget of [SDD 0005](0005-response-size-budget.md). | Run the SDD 0005 size checks after this change. |
| SUM-014 | `aistats history --json` SHOULD print the same object as the `get_stats_history` Structured content for the same window. | Run the command with an empty `AISTATS_HOME`. Assert `recording` false and `startCommand`. Compare with an MCP call on the same directory. |

## Non-goals

- Removal of the JSON copy from the Text block. This is rejected. It saves no model tokens in the observed client, and the MCP specification recommends the copy.
- Changes to the Summary wording.
- An `outputSchema` declaration for any tool. It would add bytes to `tools/list`. See [SDD 0012](0012-schema-dedup.md).
- Structured content for error results.
- New CLI commands. See [SDD 0008](0008-cli-parity.md).

## Dependencies and related specs

- [SDD 0005](0005-response-size-budget.md) sets the byte budget that new fields must fit.
- [SDD 0003](0003-top-process-identity.md) adds process identity fields. Its new rows follow SUM-001.
- [SDD 0006](0006-wait-for-conditions.md) and [SDD 0002](0002-port-lookup.md) add `wait_for` conditions and `find_processes` selectors. Their Summaries follow SUM-001.
- [SDD 0008](0008-cli-parity.md) adds CLI commands with `--json`. Their JSON SHOULD match the MCP Structured content, as SUM-014 states for `history`.
- [SDD 0010](0010-delta-responses.md) collapses unchanged sections. Its `unchanged` and `deltaReset` fields put the delta state into Structured content.

## Open questions

- The Structured-content-only behavior was observed once, on Claude Code 2.1.328. The behavior of Codex, Gemini CLI, Cursor, and other clients was not checked.
- It is not verified which content an error result delivers to the model in clients that drop the Summary.
- One fresh-process call to `get_system_stats` once returned `usagePercent` 0 with `unavailable` set to `["cpu"]`. The cause is unknown. `measure` takes a priming reading before the reported one ([SystemSampler.swift:47](../../Sources/StatsCore/SystemSampler.swift#L47)), so the second reading should have previous CPU ticks.
- `null` changes the JSON type of the Table 2 fields. A JSON consumer that expects numbers can fail. No external consumer is known. The app decodes `Snapshot` in its own Fixtures ([PanelFixtures.swift:17](../../Sources/AIStatsMenu/PanelFixtures.swift#L17)).
- The exact wording of `notes` strings is not fixed. Tests can match a stable prefix.
