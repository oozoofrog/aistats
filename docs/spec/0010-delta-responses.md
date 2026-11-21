# SDD 0010 · Delta Responses

Status · Proposed
Issue · [#9](https://github.com/oozoofrog/aistats/issues/9)

## Purpose and scope

This specification covers repeated calls to `get_system_stats` and to `track_processes` with action `status`. Today each call returns a Full Result, even when most values did not change. This specification adds a Cursor to each Result and an optional `since` argument. With a valid `since`, the server returns a Delta Result that omits the Sections that did not change since the Base. A call without `since` returns the same Full Result as today, plus the Cursor. Other tools, other `track_processes` actions, and the CLI are out of scope.

The key words "MUST", "MUST NOT", "SHOULD", "SHOULD NOT", and "MAY" in this document are to be interpreted as described in BCP 14 [RFC2119] [RFC8174] when, and only when, they appear in all capitals.

[RFC2119]: https://www.rfc-editor.org/rfc/rfc2119.html
[RFC8174]: https://www.rfc-editor.org/rfc/rfc8174.html

Requirements use the ASD-STE100 sentence rules and the Terms below. Each active ID identifies one requirement sentence. A Withdrawn ID remains reserved. Tables named by a requirement give the acceptance data for that requirement.

## Terms

| Term | Meaning |
| --- | --- |
| Result | The `result` object of a `tools/call` response with `isError` false. |
| Structured content | The `structuredContent` object of a Result. |
| Summary | The part of the Text block (`content[0]`) before the serialized JSON. See [SDD 0004](0004-summary-facts-in-json.md). |
| Payload Size | The UTF-8 byte count of Structured content. See [SDD 0005](0005-response-size-budget.md). |
| Session | One running `aistats mcp` server process and its client connection. |
| Cursor | An opaque string in a Result. It identifies the data that the caller holds after it reads that Result. |
| Base | The data that a Cursor identifies. |
| Full Result | A Result with all Sections, as in version 0.3.0. |
| Delta Result | A Result for a call with a usable `since`. It omits the Sections that did not change since the Base. |
| Section | A group of fields that the server omits or returns as a unit. Table 1 and Table 2 list the Sections. |
| Collapsed Section | A Section that a Delta Result omits and names in `unchanged`. |
| Tolerance | The largest difference from the Base value for which a field counts as unchanged. |
| Always field | A field that each Delta Result includes, also when its Section is a Collapsed Section. |

## Background and evidence

### get_system_stats

- The tool takes no arguments. See [MCPServer.swift:323](../../Sources/StatsCore/MCPServer.swift#L323).
- Each call measures for 0.5 seconds and adds the top 5 processes. See [MCPServer.swift:427](../../Sources/StatsCore/MCPServer.swift#L427) to [MCPServer.swift:431](../../Sources/StatsCore/MCPServer.swift#L431).
- The Result has CPU, memory, disk, network totals and interface names, battery, uptime, thermal state, and processes. See [Snapshot.swift:76](../../Sources/StatsCore/Snapshot.swift#L76) to [Snapshot.swift:105](../../Sources/StatsCore/Snapshot.swift#L105).
- Some values do not change between calls in normal use: `cpu.logicalCores`, `memory.totalBytes`, `disk.mountPath`, and `disk.totalBytes`. Network totals change on each call.

### track_processes status

- Each status call returns the whole report, trimmed to a 4,096-byte line. See [MCPServer.swift:517](../../Sources/StatsCore/MCPServer.swift#L517) to [MCPServer.swift:539](../../Sources/StatsCore/MCPServer.swift#L539).
- The track keeps the last 32 events and shows the last 8. It counts all events in `eventsTotal`. See [ProcessTracker.swift:583](../../Sources/StatsCore/ProcessTracker.swift#L583), [ProcessTracker.swift:1074](../../Sources/StatsCore/ProcessTracker.swift#L1074) to [ProcessTracker.swift:1077](../../Sources/StatsCore/ProcessTracker.swift#L1077), and [ProcessTracker.swift:1149](../../Sources/StatsCore/ProcessTracker.swift#L1149).
- The track keeps the last 3 spikes. Each spike gets an id from `spikesTotal`. See [ProcessTracker.swift:1038](../../Sources/StatsCore/ProcessTracker.swift#L1038) and [ProcessTracker.swift:1058](../../Sources/StatsCore/ProcessTracker.swift#L1058) to [ProcessTracker.swift:1059](../../Sources/StatsCore/ProcessTracker.swift#L1059).
- A `sample` capture can finish after the spike was reported. The capture then changes that spike. See [ProcessTracker.swift:1062](../../Sources/StatsCore/ProcessTracker.swift#L1062) to [ProcessTracker.swift:1070](../../Sources/StatsCore/ProcessTracker.swift#L1070).
- The report shows the top 5 members, the last 3 instances, and up to 8 executables. See [ProcessTracker.swift:1094](../../Sources/StatsCore/ProcessTracker.swift#L1094), [ProcessTracker.swift:1103](../../Sources/StatsCore/ProcessTracker.swift#L1103), and [ProcessTracker.swift:1122](../../Sources/StatsCore/ProcessTracker.swift#L1122).
- Status works after the Session that started the track ends. The server then loads the saved report. See [ProcessTracker.swift:1318](../../Sources/StatsCore/ProcessTracker.swift#L1318) to [ProcessTracker.swift:1321](../../Sources/StatsCore/ProcessTracker.swift#L1321).
- A track lasts up to 7,200 seconds. See [ProcessTracker.swift:14](../../Sources/StatsCore/ProcessTracker.swift#L14). An agent can call status many times during one track.

### Evidence gaps

- No measurement shows how often agents repeat these two calls. The activity log keeps the last 200 calls and records `status` for track status calls. See [Store.swift:278](../../Sources/StatsCore/Store.swift#L278) and [MCPServer.swift:519](../../Sources/StatsCore/MCPServer.swift#L519). It can supply that measurement.
- Byte savings in this document are estimates. Token counts use about 4 bytes per token. No tokenizer measurement exists.
- A client can drop old tool results from the model context, for example after context compaction. A Delta Result is then hard to use, because the model no longer has the Base.

## Requirements

### Cursor and argument

| ID | Requirement | Acceptance check |
| --- | --- | --- |
| DLT-001 | Each `get_system_stats` Result MUST include a `cursor` string. | Call twice. Assert that both Results have a non-empty `cursor`. |
| DLT-002 | Each `track_processes` status Result MUST include a `cursor` string. | Start a track. Call status twice. Assert `cursor`. |
| DLT-003 | A Cursor MUST NOT exceed 64 bytes. | Assert the UTF-8 length of each Cursor from DLT-001 and DLT-002. |
| DLT-004 | `get_system_stats` MUST accept an optional string argument `since`. | Read the `tools/list` schema. Call with a Cursor. Assert `isError` false. |
| DLT-005 | `track_processes` MUST accept an optional string argument `since` with action `status`. | Same check for `track_processes`. |
| DLT-006 | `track_processes` MUST return a tool error when `since` comes with another action. | Call `start`, `stop`, and `list` with `since`. Assert `isError` true. |
| DLT-007 | The `since` property description SHOULD NOT exceed 120 bytes in each tool schema. | Measure the description in `tools/list`. |

### Full and Delta Results

| ID | Requirement | Acceptance check |
| --- | --- | --- |
| DLT-008 | A call without `since` MUST return a Full Result. | Compare the key set with version 0.3.0. Expect only the added `cursor`. |
| DLT-009 | A call with a usable `since` MUST return a Delta Result with `delta` set to true. | Call twice with the first Cursor. Assert `delta`. |
| DLT-010 | A Delta Result MUST list each Collapsed Section in an `unchanged` array of Section names. | Fixture with no change. Assert that `unchanged` names each omitted Section. |
| DLT-011 | A Delta Result MUST NOT omit a Section that it does not list in `unchanged`. | Fixture with one changed Section. Assert that each Section is either present or listed. |
| DLT-012 | A Delta Result MUST include each Always field in Table 1 and Table 2. | Fixture with no change. Assert each Always field. |
| DLT-013 | The server MUST NOT collapse a Section with a field outside its Tolerance. | Change one field in each Section by its Tolerance plus one unit. Assert that the Section is present. |
| DLT-014 | The server MUST compare the current values with the Base, not with the previous call. | Change a field by 60% of its Tolerance on each of three calls. Use each new Cursor. Assert that the Section is present on the second change. |
| DLT-015 | The Cursor of a Delta Result MUST identify the Base values for Collapsed Sections and the new values for returned Sections. | Continue the DLT-014 sequence. Assert that the next comparison uses the returned values. |
| DLT-016 | The server MUST NOT collapse a Section whose metric availability changed since the Base. | Make the `cpu` read fail after the Base. Assert that `cpu` is present and `unavailable` has `cpu`. |
| DLT-017 | The Summary of a Delta Result MUST name the Collapsed Sections. | Fixture with no change. Assert that the Summary has each Section name in `unchanged`. |

### Unusable Cursors

| ID | Requirement | Acceptance check |
| --- | --- | --- |
| DLT-018 | For an unusable `since`, the server MUST return a Full Result, not an error. | Call with `since` `x`. Assert `isError` false and all Sections. |
| DLT-019 | That Full Result MUST set `delta` to false and give the reason in `deltaReset`. | Same call. Assert `delta` false and `deltaReset`. |
| DLT-020 | `deltaReset` MUST be one of `unknown_cursor`, `expired`, or `other_target`. | Use a malformed Cursor, an expired Cursor, and a Cursor from the other tool or track. Assert each value. |
| DLT-021 | A `get_system_stats` Cursor MUST expire 600 seconds after the server returned it. | Use a test clock. Call with a Cursor that is 601 seconds old. Assert `deltaReset` `expired`. |
| DLT-022 | The server MUST keep at most 8 `get_system_stats` Cursors per Session. | Get 9 Cursors. Use the first. Assert `deltaReset` `expired`. |
| DLT-023 | A `get_system_stats` Cursor from another Session MUST give `unknown_cursor`. | Get a Cursor in one harness. Use it in a second harness. Assert the reason. |
| DLT-024 | A `track_processes` Cursor MUST stay usable in other Sessions for the same track. | Start a track in Session A and get a Cursor. End Session A. Call status in Session B with the Cursor. Assert `delta` true. |

### get_system_stats Sections

| ID | Requirement | Acceptance check |
| --- | --- | --- |
| DLT-025 | `get_system_stats` MUST use the Sections and Tolerances in Table 1. | Table-driven test over each row of Table 1. |
| DLT-026 | When `network` collapses, the Delta Result MUST include `network` with only `receivedTotalBytes` and `sentTotalBytes`. | Fixture with stable rates and growing totals. Assert the two totals and no other `network` field. |

### Table 1 · get_system_stats Sections

| Section | Fields | Collapses when |
| --- | --- | --- |
| Always fields | `cursor`, `delta`, `unchanged`, `timestamp`, `sampleIntervalSeconds`, `uptimeSeconds`, `unavailable` | Never |
| `cpu` | All `cpu` fields | `usagePercent`, `userPercent`, and `systemPercent` are each within 2.0 percentage points. Each load average is within 0.5. `logicalCores` is equal. |
| `memory` | All `memory` fields | `pressure` is equal. `usedPercent` is within 1.0 percentage point. Each byte field is within 1% of `memory.totalBytes`. |
| `disk` | All `disk` fields | `mountPath` and `totalBytes` are equal. Each available-bytes field is within 1 GiB. |
| `network` | Rates and `interfaces`. The totals are Always fields of this Section. | `interfaces` is equal. Each rate is within 64 KiB/s or 25% of the Base rate, whichever is larger. |
| `battery` | All `battery` fields | Presence is equal. `isCharging` and `powerSource` are equal. `percent` is within 2. `minutesRemaining` is within 15. |
| `thermalState` | `thermalState` | The value is equal. |
| `topProcesses` | `topProcesses` | The pid sequence is equal. Each `cpuPercent` is within 10 percentage points. Each `memoryBytes` is within 10%. |

### track_processes status Sections

| ID | Requirement | Acceptance check |
| --- | --- | --- |
| DLT-027 | `track_processes` status MUST use the Sections in Table 2. | Table-driven test over each row of Table 2. |
| DLT-028 | A track Section MUST collapse only when it is equal to the Base. | Change one value in each Section. Assert that the Section is present. |
| DLT-029 | In a Delta Result, `events` MUST contain only events that the track added after the Base. | Base with 5 events. Add 3. Assert 3 events. |
| DLT-030 | `eventsOmitted` in a Delta Result MUST count the events added after the Base that the Result does not show. | Base, then add 40 events. Assert `events.count + eventsOmitted == 40`. |
| DLT-031 | In a Delta Result, `spikes` MUST contain each spike added after the Base. | Base, then cause 1 spike. Assert 1 spike. |
| DLT-032 | `spikes` MUST also contain each earlier spike whose sample result arrived after the Base. | Base after a spike with a capture in progress. Finish the capture. Assert that spike with `sampleTopFrames`. |
| DLT-033 | Status of an ended track with an unchanged Base SHOULD have a Payload Size of at most 800 bytes. | End a track. Call status. Call status with the Cursor. Measure the Structured content. |

### Table 2 · track_processes status Sections

| Section | Fields | Content in a Delta Result |
| --- | --- | --- |
| Always fields | `cursor`, `delta`, `unchanged`, `trackId`, `state`, `endReason`, `endedAt`, `elapsedSeconds`, `validSamples`, `aggregate`, `restartCount`, `additionalInstances`, `membersDropped`, `spikesRateLimited`, `argsUnreadable` | Always present when the report has them |
| `config` | `selector`, `match`, `includeChildren`, `scope`, `startedAt`, `endsAt`, `durationSeconds`, `intervalSeconds`, `argsFilter` | The whole Section when changed |
| `instances` | `instances`, `instancesOmitted` | The whole Section when changed |
| `members` | `members`, `membersOmitted` | The whole Section when changed |
| `events` | `events`, `eventsOmitted` | Only events added after the Base |
| `spikes` | `spikes`, `spikesOmitted` | Spikes added after the Base, and spikes whose sample result arrived after the Base |
| `spawn` | `spawn` | The whole Section when changed |
| `notes` | `notes`, `notesOmitted` | The whole Section when changed |

### Size

| ID | Requirement | Acceptance check |
| --- | --- | --- |
| DLT-034 | A `get_system_stats` Delta Result with all Sections collapsed SHOULD have a Payload Size of at most 400 bytes. | Fixture with no change. Measure the Structured content. |
| DLT-035 | A Full Result with `cursor` MUST still meet [SDD 0005](0005-response-size-budget.md). | Run the SDD 0005 size checks after this change. |

## Non-goals

- Delta Results for `get_top_processes`, `get_stats_history`, `diagnose_system`, `find_processes`, `wait_for`, and `get_environment`.
- Delta Results as the default behavior.
- Per-member differences inside the `members` Section.
- Server push, subscriptions, or MCP resources. The server lists no resources today ([MCPServer.swift:254](../../Sources/StatsCore/MCPServer.swift#L254)).
- `get_system_stats` Cursors that survive the Session.
- A `since` option in the CLI.

## Dependencies and related specs

- [SDD 0004](0004-summary-facts-in-json.md): `unchanged`, `delta`, and `deltaReset` put the delta state into Structured content. DLT-017 keeps the Summary consistent with them.
- [SDD 0005](0005-response-size-budget.md): Full Results keep the Payload Budget. Delta Results are smaller.
- [SDD 0003](0003-top-process-identity.md): if `topProcesses` rows get `startToken`, the `topProcesses` comparison SHOULD use pid and `startToken` together.
- [SDD 0011](0011-instructions-priority.md) and [SDD 0012](0012-schema-dedup.md): the new `since` property adds schema bytes. DLT-007 limits them.

## Open questions

- No measurement shows how often agents repeat these calls. The savings are not known. Measure the repeat rate from the activity log before implementation.
- The Tolerance values in Table 1 are proposals. They are not tested against agent decisions.
- The 600-second Cursor lifetime and the limit of 8 Cursors per Session are proposals.
- It is not known whether models merge a Delta Result with the Base correctly. It is not known how often the Base is gone from the context. An agent evaluation is needed.
- The 400-byte and 800-byte targets in DLT-033 and DLT-034 are estimates from the field lists. They were not measured.
- [ADR 0008](../adr/0008-cross-session-track-cursors.md) defines a bounded index for cross-session track status.
