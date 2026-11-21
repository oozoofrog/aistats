# SDD 0017 · Live Process Origin

Status · Proposed
Issue · [#16](https://github.com/oozoofrog/aistats/issues/16)

## Purpose and scope

Explain resource use with the parent links visible now. Extend the optional busy-process report in SDD 0009. Preserve its default CPU ranking and response shape when no origin option is requested.

The key words "MUST", "MUST NOT", "SHOULD", "SHOULD NOT", and "MAY" in this document are to be interpreted as described in BCP 14 [RFC2119] [RFC8174] when, and only when, they appear in all capitals.

[RFC2119]: https://www.rfc-editor.org/rfc/rfc2119.html
[RFC8174]: https://www.rfc-editor.org/rfc/rfc8174.html

## Terms

| Term | Meaning |
| --- | --- |
| Instance | A current-user process identified by PID and startToken. |
| Chain | The observed sequence from an Instance toward its parents, ending at the SDD 0009 walk boundary. |
| Disk rate | Sum of read and written byte deltas divided by measured monotonic seconds for the same Instance. |
| Session selector | Server PID and startToken of a live presence record. Sessions with the same Agent Identity share attribution. |

## Background and evidence

- Presence identifies the server. SDD 0009 records the parent's identity at initialization. Its CPU rows give the first matching agent PID or a reason. [Store.swift:280](../../Sources/StatsCore/Store.swift#L280) · [MCPServer.swift:300](../../Sources/StatsCore/MCPServer.swift#L300) · [AGT-030 through AGT-041](0009-agent-sessions-mcp.md#attribution)
- The current-user table supplies parent PIDs and start times. A detached job can acquire PID 1 as its parent. The lost link cannot be recovered from this table. [Proc.swift:155](../../Sources/StatsCore/Proc.swift#L155) · [SDD 0009 observations](0009-agent-sessions-mcp.md#background-and-evidence)
- The sampler already reads RUSAGE_INFO_V4. The macOS SDK declares proc_pid_rusage and the ri_diskio_bytesread and ri_diskio_byteswritten fields. In a current-user probe, a synchronized 2 MiB file write increased the written counter by 2,097,152 bytes. [SystemSampler.swift:314](../../Sources/StatsCore/SystemSampler.swift#L314)
- The panel specification shows a CPU table. SDD 0003 adds process identity. Neither provides origin search. [Panel component inventory](0001-cyberpunk-panel.md#component-inventory) · [Top row requirements](0003-top-process-identity.md#requirements)

## Tool contract

Set `origin: true` on `get_agent_sessions`. Optional `sort` values are `cpu` (default), `memory`, and `disk`. Supply at most one filter, `session` or `ancestor`, each an object containing integer `pid` and string `startToken`. Origin requests require attribution. Extra origin arguments without origin mode, invalid values and conflicting arguments return a tool error.

Origin mode adds `serverStartToken` to session rows when available. Omit the token for an unverifiable session. Its identity cannot select workers. Each busy row adds `chain`, an array of identity objects with names. Disk rows also contain `readBytes`, `writtenBytes`, and `diskBytesPerSecond`. Remove oldest calls first. Shorten chain tails before removing lowest-ranked rows. Report `omittedNodes` per shortened chain and `omittedRows` for budget trimming.

## Requirements

| ID | Requirement | Acceptance check |
| --- | --- | --- |
| ORG-001 | An origin request to get_agent_sessions MUST return a Chain for each returned busy row. | For agent → shell → child, request origins. Read child, shell, agent in order with name, pid and startToken. |
| ORG-002 | Chain construction MUST follow AGT-032 through AGT-038, including their identity checks and stop reasons. | Test nested agents, a common host, a cycle, and a replaced Instance. No row crosses the first live agent or uses a replacement's identity. |
| ORG-003 | An origin request MUST support descending rankings by CPU percentage, physical memory footprint, or Disk rate. | Rank three fixtures whose leaders differ. Check each leader, value and unit. Break ties by ascending PID. |
| ORG-004 | A disk ranking MUST use two successful counter reads for the same Instance over the AGT-030 measurement. | Use unequal read/write deltas. Verify both byte deltas and the elapsed-time rate. Exclude missing, replaced or decreasing counters. Include measured zero. |
| ORG-005 | The report MUST distinguish unavailable disk measurements from a measured idle system. | Fail every read. Check a disk-unavailable reason and no ranked rows. With two equal reads expect a zero rate. |
| ORG-006 | Origin search MUST filter all measured candidates before applying the requested rank and limit. | Query by Session selector, then by ancestor pid/startToken. Put the only matching child below the unfiltered limit. Both queries return it. |
| ORG-007 | Session search MUST match only the first live Agent Identity in each Chain. | With nested agents, request the outer session. Exclude the inner agent and its workers. An expired session returns no matches. |
| ORG-008 | Ancestor search MUST require an exact Instance match within the observed Chain, including the candidate itself. | Supply a reused PID with the old token. Expect no matches. Supply the live token and verify the matching subtree up to agent boundaries. |
| ORG-009 | Unattributed rows MUST retain the SDD 0009 reason and observed Chain prefix. | Test a launchd service and a reparented job with parent 1. Expect no_agent_ancestor. Test an unreadable link and expect ancestry_unreadable. |
| ORG-010 | The report MUST keep compact structuredContent within 4,096 bytes and identify omitted rows or chain nodes. | Request long chains and names. Check serialized size, retained subject identity, attribution result, and omission counts. |
| ORG-011 | The Korean panel MUST provide ranking selection and an accessible Chain detail for a selected row. | Switch between CPU, 메모리 and 디스크 I/O. Open a row by keyboard. Read its value, units, intermediate processes and agent or origin reason. |
| ORG-012 | Origin details MUST distinguish a launchd boundary from unreadable ancestry in Korean. | For a PID 1 boundary show “launchd에서 추적 종료”. For a missing link show “상위 프로세스를 확인할 수 없음”. Neither fixture names an agent. |
| ORG-013 | The app MUST keep local origin notifications off until enabled with notification permission. | A fresh profile and denied permission each produce zero notifications. Disabling the setting stops delivery. Closing both hosts stops process sampling under PERF-010. |
| ORG-014 | On exposed-host samples, enabled notifications MUST identify the process, metric, measured value and observed origin on a configured threshold crossing. | Set a threshold for each metric. Replay below, above, above, below, above for one Instance. Expect two alerts and no repeated alert while above. |
| ORG-015 | Origin reporting MUST use only current-user evidence without root privileges, command arguments, or private APIs. | Inspect responses and notifications for secret fixture arguments and other-user nodes. Verify neither appears. |

## Non-goals

Historical reconstruction, conversation-level attribution, and assigning XPC services to clients by executable name are outside this report. A responsible process may differ from the parent. A supported public API for linking an arbitrary service to the requesting agent remains unverified.

## Dependencies

[SDD 0009](0009-agent-sessions-mcp.md) owns the shared walk, live Session identity, CPU interval and reason codes. [SDD 0003](0003-top-process-identity.md) defines row identity. [SDD 0005](0005-response-size-budget.md) defines byte accounting. [SDD 0001](0001-cyberpunk-panel.md) owns panel accessibility and sampling budgets. [SDD 0013](0013-orphan-report.md) owns evidence retained after a Session ends.

## Open questions

Which threshold presets should the panel offer? Does a documented macOS API establish responsibility at agent-session granularity for any XPC service?
