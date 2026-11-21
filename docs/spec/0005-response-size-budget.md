# SDD 0005 · Response Size Budget

Status · Proposed
Issue · [#4](https://github.com/oozoofrog/aistats/issues/4)

## Purpose and scope

This specification covers the size of successful results from the eight `aistats` MCP tools. A Result goes into the context of an AI agent. Today only `find_processes`, `track_processes`, and error text have a size limit. Other Results can exceed 10 KB per line. This specification sets one Payload Budget for Structured content and a limit for the Summary. It defines how the server trims a Result that would exceed the budget. It removes one redundant per-point field from `get_stats_history`. It does not cover `tools/list`, the server instructions, CLI output, or files on disk.

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
| Summary | The part of the Text block before the serialized JSON. See [SDD 0004](0004-summary-facts-in-json.md). |
| Payload Size | The UTF-8 byte count of Structured content as the server writes it in the response line. |
| Payload Budget | 4,096 bytes. |
| Line Size | The UTF-8 byte count of the whole JSON-RPC response line, including the trailing newline. |
| Trimming | The removal of list items, or the shortening of strings, so that a Result fits the Payload Budget. |
| Omitted count | An integer field named `<list>Omitted` that gives the number of items that Trimming removed from `<list>`. |
| Worst-case Fixture | Test input with the maximum list lengths that the server accepts and the longest strings that it can read. Table 3 defines it. |

## Background and evidence

### Table 1 · Measured sizes

Measured on the built binary of version 0.3.0 with compact JSON. One measurement per row.

| Call | Line Size | Payload Size |
| --- | --- | --- |
| `get_stats_history`, default arguments (10 minutes, 20 points) | 10,487 B | 4,848 B |
| `get_top_processes`, `limit` 50 | about 10.7 KB | 3,932 B |
| `tools/list` (for reference, out of scope) | about 8,653 B | Not applicable |

Token counts in this document are estimates at about 4 bytes per token. No tokenizer measurement exists. At that rate, the Payload Budget is about 1,000 tokens (estimate).

### Current limits

- `maxResponseBytes` is 4,096. Its comment says that every tool response stays within it. See [MCPServer.swift:13](../../Sources/StatsCore/MCPServer.swift#L13) to [MCPServer.swift:14](../../Sources/StatsCore/MCPServer.swift#L14).
- The server enforces the limit on the Line Size only in three places:
  - `find_processes` drops rows until the line fits. See [MCPServer.swift:471](../../Sources/StatsCore/MCPServer.swift#L471) to [MCPServer.swift:475](../../Sources/StatsCore/MCPServer.swift#L475).
  - `track_processes` trims the report. See [MCPServer.swift:533](../../Sources/StatsCore/MCPServer.swift#L533) to [MCPServer.swift:539](../../Sources/StatsCore/MCPServer.swift#L539) and [ProcessTracker.swift:224](../../Sources/StatsCore/ProcessTracker.swift#L224) to [ProcessTracker.swift:313](../../Sources/StatsCore/ProcessTracker.swift#L313).
  - Error text is clipped. See [MCPServer.swift:668](../../Sources/StatsCore/MCPServer.swift#L668) to [MCPServer.swift:698](../../Sources/StatsCore/MCPServer.swift#L698).
- These tools have no limit: `get_system_stats` ([MCPServer.swift:427](../../Sources/StatsCore/MCPServer.swift#L427)), `get_top_processes` ([MCPServer.swift:433](../../Sources/StatsCore/MCPServer.swift#L433)), `get_stats_history` ([MCPServer.swift:441](../../Sources/StatsCore/MCPServer.swift#L441)), `diagnose_system` ([MCPServer.swift:459](../../Sources/StatsCore/MCPServer.swift#L459)), `get_environment` ([MCPServer.swift:481](../../Sources/StatsCore/MCPServer.swift#L481)), and `wait_for` ([MCPServer.swift:585](../../Sources/StatsCore/MCPServer.swift#L585)).
- The `track_processes` description promises responses under 4 KiB with `…Omitted` counts. See [MCPServer.swift:375](../../Sources/StatsCore/MCPServer.swift#L375).
- Existing tests check the 4,096-byte Line Size for track status and error lines. See [MCPAndRegistrationTests.swift:304](../../Tests/StatsCoreTests/MCPAndRegistrationTests.swift#L304) and [ReReviewRegressionTests.swift:255](../../Tests/StatsCoreTests/ReReviewRegressionTests.swift#L255).

### Why the Line Size is about twice the Payload Size

The Text block holds the Summary and the same JSON as Structured content. See [MCPServer.swift:605](../../Sources/StatsCore/MCPServer.swift#L605) to [MCPServer.swift:624](../../Sources/StatsCore/MCPServer.swift#L624). [SDD 0004](0004-summary-facts-in-json.md) keeps this copy. One observation on Claude Code 2.1.328 showed that the model receives only Structured content. A client that reads the Text block receives the Summary and the JSON. The Payload Budget therefore limits what the model receives in both cases. The Summary limit adds a bound for Text block readers.

### History points

- Each history point has both `memoryUsedPercent` and `memoryUsedBytes`. See [Store.swift:114](../../Sources/StatsCore/Store.swift#L114) to [Store.swift:115](../../Sources/StatsCore/Store.swift#L115) and [Store.swift:127](../../Sources/StatsCore/Store.swift#L127) to [Store.swift:128](../../Sources/StatsCore/Store.swift#L128).
- `get_stats_history` accepts `maxPoints` from 0 to 60, default 20. See [MCPServer.swift:347](../../Sources/StatsCore/MCPServer.swift#L347).
- The downsampler averages buckets, and its last point ends with the newest sample. See [Store.swift:225](../../Sources/StatsCore/Store.swift#L225) to [Store.swift:244](../../Sources/StatsCore/Store.swift#L244).
- Estimate: one point is about 230 bytes. This is (4,848 B minus the range fields) divided by 20. It is not measured per field.
- Estimate: without `memoryUsedBytes`, 20 points still exceed the budget by a few hundred bytes. The default `maxPoints` must therefore go down, or each point must get smaller.

### Process rows

- A `get_top_processes` row has `pid`, `name`, `cpuPercent`, and `memoryBytes`. See [Snapshot.swift:110](../../Sources/StatsCore/Snapshot.swift#L110) to [Snapshot.swift:117](../../Sources/StatsCore/Snapshot.swift#L117).
- The name is the executable file name. See [Proc.swift:68](../../Sources/StatsCore/Proc.swift#L68) to [Proc.swift:77](../../Sources/StatsCore/Proc.swift#L77). A file name can have up to 255 bytes.
- `limit` accepts 1 to 50, default 10. See [MCPServer.swift:334](../../Sources/StatsCore/MCPServer.swift#L334).
- [SDD 0003](0003-top-process-identity.md) adds `startToken` and `ppid` to each row. Estimate: this adds about 40 bytes per row. With `limit` 50, the estimated Payload Size is about 5.9 KB, which exceeds the budget.
- The `get_top_processes` Summary is a table with one line per row. See [MCPServer.swift:806](../../Sources/StatsCore/MCPServer.swift#L806) to [MCPServer.swift:814](../../Sources/StatsCore/MCPServer.swift#L814). With `limit` 50, the table is longer than the JSON.

## Requirements

### Budget

| ID | Requirement | Acceptance check |
| --- | --- | --- |
| RSZ-001 | Each Result MUST have a Payload Size of at most 4,096 bytes. | Test `payloadBudgetHoldsForAllTools`: call each tool with default arguments, maximum arguments, and the Worst-case Fixture. Assert the Payload Size of each Result. |
| RSZ-002 | RSZ-001 MUST apply to each argument combination that the input schema accepts. | Same test. Include `maxPoints` 60 with `minutes` 60, and `limit` 50 with each `sort` value. |
| RSZ-003 | The Summary MUST NOT exceed 512 bytes. | Same test. Remove the trailing JSON from the Text block. Measure the remainder. |
| RSZ-004 | The Line Size of a Result MUST NOT exceed 9,216 bytes. | Same test. Measure each response line. |
| RSZ-005 | `find_processes` and `track_processes` MUST keep their Line Size limit of 4,096 bytes. | The existing tests at [MCPAndRegistrationTests.swift:304](../../Tests/StatsCoreTests/MCPAndRegistrationTests.swift#L304) and [ReReviewRegressionTests.swift:255](../../Tests/StatsCoreTests/ReReviewRegressionTests.swift#L255) pass. Add a `find_processes` test with the Table 3 Fixture. Assert its Line Size. |
| RSZ-006 | Error responses MUST keep their Line Size limit of 4,096 bytes. | Send a `track_processes` status call with a 6,000-character `trackId`. Assert the Line Size. |

The 9,216-byte Line Size limit is two Payload Budgets, one Summary, and 512 bytes for the JSON-RPC envelope. The JSON copy in the Text block is a JSON string, so each quote in it is escaped with one more byte. This escape overhead is not in the sum. See Open questions.

### Trimming

| ID | Requirement | Acceptance check |
| --- | --- | --- |
| RSZ-007 | When Trimming removes list items, the Result MUST give an Omitted count for that list. | Worst-case Fixture for each tool. Assert that the sum of the shown items and the Omitted count equals the untrimmed count. |
| RSZ-008 | Trimming MUST NOT remove identifiers, states, verdicts, timestamps, or aggregate values. | Worst-case Fixture. Assert that `status`, `state`, `trackId`, `recording`, `sampleCount`, and the range fields are present. |
| RSZ-009 | Trimming MAY shorten a string only when list Trimming cannot make the Result fit. | Fixture with one process name of 255 bytes and one list item. Assert that the list item stays. |
| RSZ-010 | Trimming MUST mark each shortened string with `…`. | Same Fixture. Assert that each shortened string ends or starts with `…`. |
| RSZ-011 | Trimming MUST give the same output for the same input. | Run each Worst-case Fixture twice. Compare the Structured content bytes. |
| RSZ-012 | For the tools without Trimming today, default arguments MUST NOT cause Trimming in the Worst-case Fixture. | Worst-case Fixture with default arguments for `get_system_stats`, `get_top_processes`, `get_stats_history`, `diagnose_system`, `get_environment`, and `wait_for`. Assert that Structured content has no Omitted count and no `…` mark. |

### get_top_processes

| ID | Requirement | Acceptance check |
| --- | --- | --- |
| RSZ-013 | `get_top_processes` MUST trim rows from the lowest rank first. | Fixture with 50 processes with 255-byte names. Call with `limit` 50. Assert that the shown rows are a prefix of the untrimmed order. |
| RSZ-014 | `get_top_processes` MUST give the count of removed rows in `processesOmitted`. | Same Fixture. Assert `processes.count + processesOmitted == 50`. |
| RSZ-015 | The `get_top_processes` Summary MUST satisfy RSZ-003 for each `limit`. | Same Fixture. Measure the Summary. |

### get_stats_history

| ID | Requirement | Acceptance check |
| --- | --- | --- |
| RSZ-016 | Points in a `get_stats_history` Result MUST NOT include `memoryUsedBytes`. | Fixture with 300 points. Assert that no point has `memoryUsedBytes` and each point with memory has `memoryUsedPercent`. |
| RSZ-017 | `get_stats_history` SHOULD give the physical memory size once, as `memoryTotalBytes`. | Same Fixture. Assert one top-level `memoryTotalBytes` that equals the `get_environment` `memoryBytes`. |
| RSZ-018 | To fit the Payload Budget, `get_stats_history` MUST return fewer points, not fewer range fields. | Fixture with 1,800 points. Call with `minutes` 60 and `maxPoints` 60. Assert that all range fields are present. |
| RSZ-019 | Fewer points MUST still cover the whole window with evenly spaced buckets. | Same call. Assert that the last point time equals the newest sample time. Fixture samples are 2 seconds apart. Assert that the gaps between consecutive point times differ by at most 2 seconds. |
| RSZ-020 | `get_stats_history` MUST give `pointsOmitted`, the requested point count minus the returned point count. | Same call. The requested point count is the smaller of `maxPoints` and `sampleCount`. Assert the arithmetic. |
| RSZ-021 | The default `maxPoints` MUST fit the Worst-case Fixture without Trimming. | Fixture with 300 points and all metrics present. Call with default arguments. Assert that `pointsOmitted` is absent. |
| RSZ-022 | The default `maxPoints` SHOULD be at least 10. | Read the `maxPoints` default in the `tools/list` schema. |
| RSZ-023 | The input schema MUST keep the current maximum values of `maxPoints` and `limit`. | Compare the `tools/list` schema with version 0.3.0 for these two properties. |

### Description

| ID | Requirement | Acceptance check |
| --- | --- | --- |
| RSZ-024 | The server SHOULD state the Payload Budget and the Omitted count rule once, not in each tool description. | Count occurrences of the budget statement in `initialize` and `tools/list`. Expect one. |

### Table 3 · Worst-case Fixture

| Tool | Input |
| --- | --- |
| `get_system_stats` | 5 or more processes with 255-byte executable file names, all at high CPU. Battery present. |
| `get_top_processes` | 50 or more processes with 255-byte executable file names. |
| `get_stats_history` | A history file with 1,800 points within 60 minutes. Each point has all metrics, `memoryPressure` `critical`, rates of at least 10^9 bytes per second, and `batteryPercent`. |
| `diagnose_system` | The Fixture snapshot gives all six evidence kinds. 3 or more busy processes have 255-byte names. |
| `get_environment` | `DEVELOPER_DIR` set to a 1,024-byte path. Toolchain probe errors present. |
| `wait_for` | `cpu_idle` with a timeout. 3 or more busy processes have 255-byte names. |
| `find_processes` | 15 or more matching processes with long paths. |
| `track_processes` | A status report with all lists at their maximum and long names and paths. |

Tests can create long process names with a copy of a short-lived system binary under a 255-byte file name in a temporary directory.

## Non-goals

- Removal of the JSON copy from the Text block. This is rejected. See [SDD 0004](0004-summary-facts-in-json.md).
- The size of `tools/list`. See [SDD 0012](0012-schema-dedup.md).
- The size of the server instructions. See [SDD 0011](0011-instructions-priority.md).
- An argument that raises or disables the Payload Budget.
- CLI output and the history file format. The app writes `memoryUsedBytes` to the history file ([Store.swift:150](../../Sources/StatsCore/Store.swift#L150)), and this specification does not change it.
- New units for byte fields. Memory and disk fields stay integer byte counts.
- Delta results for repeated calls. See [SDD 0010](0010-delta-responses.md).

## Dependencies and related specs

- [SDD 0003](0003-top-process-identity.md) makes process rows larger. RSZ-001 applies to Results after that change.
- [SDD 0004](0004-summary-facts-in-json.md) adds fields to Structured content. Those fields count against the Payload Budget.
- [SDD 0002](0002-port-lookup.md) and [SDD 0006](0006-wait-for-conditions.md) add selectors and conditions. Their Results follow RSZ-001.
- [SDD 0009](0009-agent-sessions-mcp.md) adds session and call lists over MCP. Those lists follow RSZ-007.
- [SDD 0010](0010-delta-responses.md) makes repeated Results smaller. Full Results still follow this specification.
- [SDD 0011](0011-instructions-priority.md) and [SDD 0012](0012-schema-dedup.md) decide where RSZ-024 puts the budget statement.

## Open questions

- The Payload Budget of 4,096 bytes copies the current constant. No measurement shows that it is the best value for agent accuracy or cost.
- Only one client was observed. It is not known which other clients give the model the Text block, Structured content, or both.
- The default `maxPoints` value is not chosen. An estimate gives 12 points as a fit. The Worst-case Fixture must confirm the value.
- Per-point `memoryPressure` strings and ISO 8601 timestamps also repeat. A more compact point format would change the JSON schema. This specification does not require it.
- The escape overhead of the Text block copy was not measured. A Result at the Payload Budget and the Summary limit can therefore exceed the 9,216-byte Line Size limit. It is not decided whether the server trims more or the Line Size limit goes up.
- The 255-byte name length in Table 3 is the file name limit. Real process names were not surveyed.
- The Worst-case sizes for `get_system_stats`, `diagnose_system`, `get_environment`, and `wait_for` are estimates from the field lists. They were not measured.
- `get_system_stats` always includes network totals and interface names. They are not needed to meet the budget. Their value to agents is not known.
