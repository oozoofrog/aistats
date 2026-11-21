# SDD 0015 · Job Duration Baselines

Status · Proposed
Issue · [#14](https://github.com/oozoofrog/aistats/issues/14)

## Purpose and scope

An Architecture Decision Record (ADR) MUST be accepted before implementation of this specification starts. That ADR MUST make these decisions:

1. The content of a Command Signature. The ADR decides whether it uses the executable name, the executable path, argument tokens, or the working directory. It also decides whether it stores a keyed hash instead of text.
2. The Run sources. Candidates are `track_processes` tracks, `aistats track` CLI runs, and `wait_for` `process_exit` waits.
3. The minimum number of Runs for a Baseline, the statistics it reports, and the Suggested Timeout formula.
4. Retention: the maximum Runs per Command Signature, the maximum Command Signatures, and the maximum Run age.
5. How an agent reads a Baseline without starting a track: a new tool, a new field of an existing tool, or both.
6. Whether a Baseline separates Runs by toolchain version, for example the Xcode version from `get_environment`.
7. Whether Censored Runs are stored apart from Runs, and how a Baseline uses them.

This specification covers durations of recurring jobs on this Mac, such as builds and test runs. AIStats records how long each observed job instance ran, keyed by Command Signature. AIStats then gives the typical duration to agents. An agent can then choose a track duration, a command timeout, or a check schedule once, instead of repeated short waits. All data stays on this Mac.

The key words "MUST", "MUST NOT", "SHOULD", "SHOULD NOT", and "MAY" in this document are to be interpreted as described in BCP 14 [RFC2119] [RFC8174] when, and only when, they appear in all capitals.

[RFC2119]: https://www.rfc-editor.org/rfc/rfc2119.html
[RFC8174]: https://www.rfc-editor.org/rfc/rfc8174.html

## Terms

| Term | Meaning |
| --- | --- |
| Server | The `aistats` stdio MCP server process. One Server runs for each connected agent session. |
| Root Instance | A process that a track selector matched directly, as listed in the track report `instances`. Child processes are not Root Instances. |
| Run | One Root Instance whose start time and exit were both observed. |
| Run Duration | The exit observation time minus the kernel start time of the Root Instance, in seconds. |
| Censored Run | A Root Instance that was still alive when its track ended. Its true duration is longer than the observed time. |
| Command Signature | The key that groups Runs of the same recurring job. The ADR defines its content. |
| Baseline | Statistics over the stored Runs of one Command Signature. |
| Suggested Timeout | A duration in seconds that the Baseline derives from its upper percentile. It is an estimate. |
| Duration Store | The file that holds Runs under `$AISTATS_HOME`. |

## Background and evidence

| Fact | Source |
| --- | --- |
| A track runs 10 to 7,200 s. At most 4 tracks run at once in a session. | [ProcessTracker.swift:14](../../Sources/StatsCore/ProcessTracker.swift#L14), [ProcessTracker.swift:1231](../../Sources/StatsCore/ProcessTracker.swift#L1231) |
| `wait_for` waits at most 55 s per call. | [Waiter.swift:71](../../Sources/StatsCore/Waiter.swift#L71), [MCPServer.swift:403](../../Sources/StatsCore/MCPServer.swift#L403) |
| `process_exit` polls every 250 ms and returns `elapsedSeconds` of the wait, not of the process. | [Waiter.swift:127](../../Sources/StatsCore/Waiter.swift#L127), [Waiter.swift:46](../../Sources/StatsCore/Waiter.swift#L46) |
| A Root Instance start time comes from the kernel process start time, not from the time the track noticed it. | [ProcessTracker.swift:863](../../Sources/StatsCore/ProcessTracker.swift#L863) |
| The tracker sets the exit time when it observes the exit: during a table scan, a tick usage read, or a kqueue `NOTE_EXIT` event when the watch succeeded. | [ProcessTracker.swift:818](../../Sources/StatsCore/ProcessTracker.swift#L818), [ProcessTracker.swift:707](../../Sources/StatsCore/ProcessTracker.swift#L707), [ProcessTracker.swift:915](../../Sources/StatsCore/ProcessTracker.swift#L915), [ProcessTracker.swift:954](../../Sources/StatsCore/ProcessTracker.swift#L954), [ProcessTracker.swift:921](../../Sources/StatsCore/ProcessTracker.swift#L921) |
| A report shows only the last 3 Root Instances. Older ones are counted in `instancesOmitted`. | [ProcessTracker.swift:1103](../../Sources/StatsCore/ProcessTracker.swift#L1103), [ProcessTracker.swift:1143](../../Sources/StatsCore/ProcessTracker.swift#L1143) |
| A track ends with `target_exited` or `duration_elapsed`, is `stopped`, or becomes `interrupted` when its session dies. | [ProcessTracker.swift:161](../../Sources/StatsCore/ProcessTracker.swift#L161), [ProcessTracker.swift:752](../../Sources/StatsCore/ProcessTracker.swift#L752), [ProcessTracker.swift:756](../../Sources/StatsCore/ProcessTracker.swift#L756), [ProcessTracker.swift:1408](../../Sources/StatsCore/ProcessTracker.swift#L1408) |
| Only the 50 newest track reports stay on disk. | [ProcessTracker.swift:1232](../../Sources/StatsCore/ProcessTracker.swift#L1232), [ProcessTracker.swift:1430](../../Sources/StatsCore/ProcessTracker.swift#L1430) |
| A report gives only the selector kind (`pid`, `name`, `path`), not the selector value. | [ProcessTracker.swift:1136](../../Sources/StatsCore/ProcessTracker.swift#L1136), [Proc.swift:354](../../Sources/StatsCore/Proc.swift#L354) |
| The `argsContain` filter is never stored, returned, or logged. | [ProcessTracker.swift:194](../../Sources/StatsCore/ProcessTracker.swift#L194), [Proc.swift:365](../../Sources/StatsCore/Proc.swift#L365), [MCPServer.swift:515](../../Sources/StatsCore/MCPServer.swift#L515) |
| Store files use an exclusive `flock` for appends, mode 0600, and compaction to a fixed line count. | [Store.swift:50](../../Sources/StatsCore/Store.swift#L50), [Store.swift:54](../../Sources/StatsCore/Store.swift#L54), [Store.swift:86](../../Sources/StatsCore/Store.swift#L86) |
| Unreadable store lines are skipped on read. | [Store.swift:83](../../Sources/StatsCore/Store.swift#L83) |
| Track responses are trimmed to 4,096 bytes. Ids, state, aggregate figures, and omission counts are always kept. | [MCPServer.swift:14](../../Sources/StatsCore/MCPServer.swift#L14), [ProcessTracker.swift:228](../../Sources/StatsCore/ProcessTracker.swift#L228), [MCPServer.swift:534](../../Sources/StatsCore/MCPServer.swift#L534) |

An agent that starts a long build does not know how long the build usually takes. The agent then either picks a short timeout and calls `wait_for` many times, or picks a long timeout and waits too long after a failure. Each `wait_for` call costs one tool call and its result tokens. A track already observes Root Instance start and exit times. The tracker drops this data when it trims the report or prunes old reports.

The host machine had 8 concurrent Server sessions. Concurrent Servers can record Runs at the same time.

## Requirements

### Recording

| ID | Requirement | Acceptance check |
| --- | --- | --- |
| DUR-001 | The tracker MUST record one Run for each observed Root Instance exit in a track. | Track a name selector while a fixture starts and ends 5 sequential instances. Require 5 Runs in the Duration Store, although the report shows 3. |
| DUR-002 | A Run MUST give `durationSeconds` rounded to 0.1 s, `exitedAt`, and its Command Signature. | Decode a Run from the DUR-001 fixture. Require the three fields. Require `durationSeconds` within the track interval of the fixture duration. |
| DUR-003 | A Run MUST give `exitResolutionSeconds`, the maximum delay of the exit observation. | Track with `intervalSeconds` 5. Require `exitResolutionSeconds` of 5 or less on each Run. |
| DUR-004 | AIStats MUST NOT record a Censored Run as a Run. | End a track with `duration_elapsed`, with `stopped`, and with `interrupted` while the target lives. Require no new Run for the target. |
| DUR-005 | AIStats MUST record a Run for a Root Instance that started before its track. | Start a 30 s fixture job. Start a pid track 10 s later. Require a Run with `durationSeconds` near 30, not near 20. |
| DUR-006 | AIStats MUST NOT record Runs for child processes that are not Root Instances. | Track with `includeChildren` true over a job that spawns 20 children. Require Runs only for Root Instances. |

### Privacy

| ID | Requirement | Acceptance check |
| --- | --- | --- |
| DUR-007 | The Duration Store MUST NOT contain the `argsContain` text. | Track with `argsContain` set to a unique 32-character marker. Search the AIStats home for the marker. Require zero matches. |
| DUR-008 | The Duration Store MUST NOT contain raw process argument text. | Run a fixture job with a unique marker argument. Track it by name. Search the AIStats home for the marker. Require zero matches. |
| DUR-009 | The Duration Store MUST NOT contain the absolute home directory path or the user name. | Track a job whose executable is under the home directory. Search the Duration Store for both strings. Require zero matches. |
| DUR-010 | The Duration Store MUST use file mode 0600. | Inspect the file mode after the first Run. Require `0600`. |
| DUR-011 | AIStats MUST NOT send Runs or Baselines off this Mac. | Run the DUR-001 fixture with network access monitored for the AIStats processes. Require no outgoing connection. |

### Storage

| ID | Requirement | Acceptance check |
| --- | --- | --- |
| DUR-012 | Concurrent Servers MUST NOT lose or corrupt Runs. | Start 8 processes that each record 100 Runs at the same time. Require 800 decodable Runs, or the retention limit when it is lower. |
| DUR-013 | The Duration Store MUST keep at most the Run and Command Signature limits that the ADR fixes. | Record one Run more than each limit. Require that the oldest Run or the least recently used Command Signature is gone. |
| DUR-014 | AIStats MUST treat a missing or partly unreadable Duration Store as having only its readable Runs. | Delete the file, then append a corrupt line to a valid file. Require no error and Baselines from the valid lines only. |
| DUR-015 | Recording a Run MUST NOT delay the track tick by more than 50 ms. | Trace tick times on a track over 100 recorded Runs with a store at the retention limit. Require every tick delay of 50 ms or less. |

### Baseline content

| ID | Requirement | Acceptance check |
| --- | --- | --- |
| DUR-016 | A Baseline MUST give `runs`, `medianSeconds`, `p90Seconds`, `maxSeconds`, and `lastRunAt`. | Load a fixture with 10 Runs of known durations, or the ADR minimum when it is higher. Require the five fields with the expected values. |
| DUR-017 | A Baseline MUST NOT give percentile fields or `suggestedTimeoutSeconds` when it has fewer Runs than the ADR minimum. | Load a fixture with one Run less than the minimum. Require `runs` and no `medianSeconds`, `p90Seconds`, or `suggestedTimeoutSeconds`. |
| DUR-018 | A Baseline MUST give a display `label` that names the executable. | Decode a Baseline for a track by name. Require `label` equal to the executable file name. |
| DUR-019 | A Baseline SHOULD give `suggestedTimeoutSeconds` within the track duration range of 10 to 7,200 s. | Load fixtures with p90 values of 2 s, 600 s, and 10,000 s. Require values clamped to 10 and 7,200 and computed by the ADR formula in between. |
| DUR-020 | When a Baseline gives `waitForTimeoutSeconds`, its value MUST be 55 or less. | Decode Baselines from the DUR-019 fixtures. Require every `waitForTimeoutSeconds` at 55 or less. |
| DUR-021 | The Baseline JSON MUST stay at or below 256 bytes compact. | Encode a Baseline with a 64-character `label` and every field present. Require 256 bytes or less. |

### Agent access

| ID | Requirement | Acceptance check |
| --- | --- | --- |
| DUR-022 | A `track_processes` `start` result MUST include `baseline` when the target has a Baseline at the start. | Load a fixture with enough Runs for a name. Start a track by that name while an instance runs. Require `baseline` in `structuredContent`. |
| DUR-023 | A `track_processes` `status` result MUST include `baseline` when the track has one. | Call `status` on the DUR-022 track. Require `baseline` in `structuredContent`. |
| DUR-024 | Report trimming MUST keep `baseline`. | Fill a track report past 4,096 bytes with events and spikes. Require `baseline` in the trimmed result. |
| DUR-025 | An agent MUST get the Baseline of a running process in one call without starting a track. | Load a fixture with enough Runs. Send one `tools/call` request by the means that the ADR picks. Require the Baseline in `structuredContent`. |
| DUR-026 | The Server MUST NOT add Baselines to results of tools that the ADR does not name. | Load Baseline fixtures. Call every other tool. Require no `baseline` field in their `structuredContent`. |
| DUR-027 | A user MUST be able to delete all Runs with one CLI command. | Record Runs. Run the CLI command that the ADR names. Require an empty Duration Store and exit code 0. |

## Non-goals

- A command runner that starts and times a job, such as `aistats time -- cmd`. This proposal was rejected.
- Exit status or success detection of a job. AIStats cannot read the exit status of a process that it did not start.
- Durations of child processes, or per-phase timings inside a job.
- Prediction from machine load, project size, or source changes.
- Sharing Baselines between Macs or users.
- Changing the 55 s `wait_for` limit or the 7,200 s track limit.

## Dependencies and related specs

- [SDD 0003 · Top process identity](0003-top-process-identity.md): `startToken` in top rows lets an agent start a pid track without an extra lookup.
- [SDD 0004 · Summary facts in JSON](0004-summary-facts-in-json.md): Baseline facts are in JSON, not only in summary text.
- [SDD 0005 · Response size budget](0005-response-size-budget.md): DUR-021 and DUR-024 keep results inside its budget.
- [SDD 0006 · wait_for conditions](0006-wait-for-conditions.md): `process_exit` is a candidate Run source. Its behavior stays unchanged.
- [SDD 0008 · CLI parity](0008-cli-parity.md): DUR-027 follows its CLI conventions.
- [SDD 0010 · Delta responses](0010-delta-responses.md): an unchanged `baseline` can collapse in a delta `status` result.
- [SDD 0013 · Orphan report](0013-orphan-report.md): both specs record process lifetimes. Their ADRs should agree on one store format.

## Open questions

- Which Command Signature content groups Runs well without raw arguments. For example, `xcodebuild build` and `xcodebuild test` share the executable name. No measurement exists.
- How failed or cancelled jobs affect the Baseline. A fast compile error and a full build share one Command Signature.
- How much tighter the kqueue `NOTE_EXIT` exit time is than the tick, and how often the kqueue watch fails so that only polling applies. Not measured.
- Whether `wait_for` `process_exit` can record Runs. Its result gives the wait time only. The process start time from the start token would give the Run Duration. Not verified.
- How often agents start tracks for recurring jobs. Without tracks, no Runs exist. No usage data exists.
- Whether a toolchain upgrade makes old Runs misleading enough to separate them. Not measured.
- Token savings from fewer `wait_for` calls are estimates at about 4 bytes per token. No tokenizer measurement exists.
