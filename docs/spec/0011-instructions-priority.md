# SDD 0011 · Instructions Priority

Status · Proposed
Issue · [#10](https://github.com/oozoofrog/aistats/issues/10)

## Purpose and scope

This specification sets rules for the MCP server instructions that `initialize` returns. Some clients load only tool names and the instructions before the model selects a tool. One client is reported to give priority to the first 512 characters of the instructions. The first 512 characters must therefore route every task to the correct tool without the rest of the text. The total size must not grow.

The scope is the text of `MCPServer.instructions` and the checks for it. Tool descriptions and input schemas are in [SDD 0012](0012-schema-dedup.md).

The key words "MUST", "MUST NOT", "SHOULD", "SHOULD NOT", and "MAY" in this document are to be interpreted as described in BCP 14 [RFC2119] [RFC8174] when, and only when, they appear in all capitals.

[RFC2119]: https://www.rfc-editor.org/rfc/rfc2119.html
[RFC8174]: https://www.rfc-editor.org/rfc/rfc8174.html

## Terms

| Term | Meaning |
| --- | --- |
| Instructions | The `instructions` string in the `initialize` result. |
| Routing Prefix | The first 512 Unicode scalar values of the Instructions. |
| Routing Trigger | A short task description that tells the model when to use a tool, such as "Slow Mac". |
| Tool Set | The tool names in the `tools/list` result of the same release. |
| Baseline | The Instructions of v0.3.0. |

## Background and evidence

| Fact | Evidence |
| --- | --- |
| `initialize` returns the Instructions. | [MCPServer.swift:284](../../Sources/StatsCore/MCPServer.swift#L284) |
| The Baseline is 768 bytes and 768 characters, all ASCII. Measured from the source text. | [MCPServer.swift:289](../../Sources/StatsCore/MCPServer.swift#L289) to [MCPServer.swift:298](../../Sources/StatsCore/MCPServer.swift#L298) |
| Character 512 of the Baseline falls inside the `wait_for` line. The prefix ends with `Instead of sleeping or polling: wa`. | [MCPServer.swift:295](../../Sources/StatsCore/MCPServer.swift#L295) |
| The names `wait_for`, `get_environment`, and `get_stats_history` do not appear in the Baseline Routing Prefix. The sentence that limits the scope to the current user's processes is also outside it. | [MCPServer.swift:295](../../Sources/StatsCore/MCPServer.swift#L295) to [MCPServer.swift:297](../../Sources/StatsCore/MCPServer.swift#L297) |
| The Baseline names `lsof` as a replaced command. No tool lists listening ports or open files in v0.3.0. | [MCPServer.swift:290](../../Sources/StatsCore/MCPServer.swift#L290), [MCPServer.swift:318](../../Sources/StatsCore/MCPServer.swift#L318) to [MCPServer.swift:419](../../Sources/StatsCore/MCPServer.swift#L419) |
| The Baseline states "up to 55 s per call". The server limit is 55 s. | [MCPServer.swift:295](../../Sources/StatsCore/MCPServer.swift#L295), [Waiter.swift:71](../../Sources/StatsCore/Waiter.swift#L71) |
| The tool names come from the static tool table. | [MCPServer.swift:421](../../Sources/StatsCore/MCPServer.swift#L421) |

Client behavior:

- Claude Code 2.1.328 in its default configuration defers MCP tool schemas through tool search. Only tool names and server Instructions load before the model selects a tool. For aistats this is about 1 KB. The Instructions are therefore the main routing text before a schema loads.
- Claude Code caps the Instructions at 4,096 characters.
- Codex is reported to give priority to the first 512 characters of the Instructions. This statement comes from Codex. It is not in official documentation.

### Feasibility draft (informative)

This draft is 486 characters, all ASCII. It names all eight v0.3.0 tools and the scope limit. It is an example only. The requirements do not fix the wording.

```text
AIStats reads this Mac's load and processes; use it instead of ps/top/sleep loops. Current user's processes only.
- Slow Mac, or before heavy build/test: diagnose_system
- CPU/memory hogs now: get_top_processes; whole machine: get_system_stats
- Find a process by name/path/pid (gets startToken): find_processes
- Watch processes over minutes: track_processes
- Instead of sleep/polling: wait_for
- OS, chip, Xcode, Swift versions: get_environment
- Last hour's trend: get_stats_history
```

The remaining 282 bytes up to the Baseline size can hold secondary detail, such as the `wait_for` condition names, the 55 s limit, and the AIStats app requirement of `get_stats_history`.

## Requirements

| ID | Requirement | Acceptance check |
| --- | --- | --- |
| INS-001 | The Routing Prefix MUST contain every tool name in the Tool Set. | Unit test `instructionsPrefixNamesEveryTool`: take the first 512 Unicode scalars of `MCPServer.instructions`. Verify that it contains each name in `MCPServer.toolNames`. |
| INS-002 | The Routing Prefix MUST give at least one Routing Trigger for each tool name. | Review: for each tool name, find the trigger text on the same line within the Routing Prefix. |
| INS-003 | The Routing Prefix MUST state that only the current user's processes are readable. | Unit test: the Routing Prefix contains `current user`, compared case-insensitively. |
| INS-004 | The Instructions MUST be at most 768 bytes in UTF-8. | Unit test: `MCPServer.instructions.utf8.count <= 768`. |
| INS-005 | The Instructions SHOULD contain only ASCII characters. | Unit test: every Unicode scalar is below U+0080. Then the byte count and every character count are equal. |
| INS-006 | The Instructions MUST NOT name a shell command as replaced unless a tool performs that task. | Review each named command against the Tool Set. `lsof` is allowed only after [SDD 0002](0002-port-lookup.md) ships port lookup. |
| INS-007 | Each numeric limit in the Instructions MUST equal the server limit. | Unit test: for each limit in the text, compare it with its constant, such as `Waiter.timeoutRange.upperBound` for the wait limit. |
| INS-008 | Text after the Routing Prefix MAY give conditions, limits, and prerequisites. | Not applicable. |
| INS-009 | A change to the Instructions SHOULD pass the selection check of [SDD 0012](0012-schema-dedup.md) with no loss against the Baseline. | Run the SCH-009 selection check with the Baseline Instructions and with the candidate. Compare the correct counts. |
| INS-010 | The server MUST return the same Instructions to every client. | Stdio probe: send `initialize` with two different `clientInfo.name` values. Compare the two `instructions` strings. |

## Non-goals

- Changes to tool descriptions and input schemas. See [SDD 0012](0012-schema-dedup.md).
- Different Instructions per client.
- MCP resources or prompts. `resources/list` and `prompts/list` stay empty.
- A size increase above the Baseline to fit new tools. A new tool needs shorter wording for the existing tools.

## Dependencies and related specs

- [SDD 0002](0002-port-lookup.md) adds port lookup to `find_processes`. The Routing Prefix then needs a port trigger. INS-006 then permits `lsof`.
- [SDD 0006](0006-wait-for-conditions.md) adds `wait_for` conditions. Their names can stay after the Routing Prefix.
- [SDD 0009](0009-agent-sessions-mcp.md) can add a tool. INS-001 then applies to that tool.
- [SDD 0012](0012-schema-dedup.md) defines the selection check that INS-009 uses.

## Open questions

- The 512-character priority in Codex is reported, not documented. The counting unit (bytes, UTF-16 code units, or Unicode scalars) is unknown. INS-005 makes the unit irrelevant for ASCII text.
- No measurement shows that the Baseline routes tools worse than the draft. INS-009 is the planned measurement.
- Whether other clients cut or summarize the Instructions is not verified.
- A tool added by SDD 0009 can make 512 characters too few for nine Routing Triggers with the scope sentence. The draft has 26 characters of space left.
