# SDD 0013 · Orphan Report

Status · Proposed
Issue · [#12](https://github.com/oozoofrog/aistats/issues/12)
Decision · [ADR 0009 · Record observed descendant identities for the orphan report](../adr/0009-orphan-lineage.md)

## Purpose and scope

An ADR MUST be accepted before implementation of this specification. That ADR must make these decisions:

1. The recorder: the Server Process, the app, or both, and the observation interval.
2. The linkage evidence in addition to `lineage`, for example process group, session id, or inherited environment markers. The ADR must state the privacy rule for each evidence type.
3. The storage location, format, retention age, and size limit of Lineage Records.
4. The events that end a Session for this report in addition to Agent Process exit, for example Server Process exit.
5. The report surface: a separate MCP tool, a section of `get_agent_sessions`, or both.
6. The app termination action: the signal sequence, the confirmation text, and the re-verification rule.

[ADR 0009](../adr/0009-orphan-lineage.md) is accepted and makes these decisions. It amends ORP-001, ORP-004, ORP-005, ORP-007, ORP-008, ORP-014, ORP-021, ORP-022, ORP-032, and Table 1. It adds ORP-036, ORP-037, and ORP-040 through ORP-050.

This specification adds a report of Orphan Candidates. An Orphan Candidate is a live process that an agent session started and left behind after the session ended. The report is read-only for agents and the CLI. Only a person can terminate a reported process, in the app, after a confirmation.

The specification depends on the Agent Identity of [SDD 0009](0009-agent-sessions-mcp.md).

The key words "MUST", "MUST NOT", "SHOULD", "SHOULD NOT", and "MAY" in this document are to be interpreted as described in BCP 14 [RFC2119] [RFC8174] when, and only when, they appear in all capitals.

[RFC2119]: https://www.rfc-editor.org/rfc/rfc2119.html
[RFC8174]: https://www.rfc-editor.org/rfc/rfc8174.html

## Terms

| Term | Meaning |
| --- | --- |
| Session | One running `aistats mcp` server process and its presence record. See [SDD 0009](0009-agent-sessions-mcp.md). |
| Agent Process | The parent process of a Server Process, recorded on `initialize`. See [SDD 0009](0009-agent-sessions-mcp.md). |
| Agent Identity | The pid and Start Token of an Agent Process. |
| Start Token | The decimal `ri_proc_start_abstime` value that `find_processes` returns as `startToken`. |
| Descendant | A process whose Ancestor Walk reaches the Agent Process. |
| Ancestor Walk | The sequence of parent links from a process up to pid 1. |
| Lineage Record | A persisted entry that links one Descendant to one Agent Identity. |
| Ended Session | A Session whose recorded Agent Process no longer runs with its Start Token. |
| Orphan Candidate | A live process with a Lineage Record of an Ended Session and no live Agent Process in its Ancestor Walk. |
| Lineage Recorder | The app component that reads the current-user process table every 1 s and writes Lineage Records. It is the only writer of the store. |
| Closed-Panel Recording | The app setting `패널을 닫아도 계보 기록`. It lets the Lineage Recorder run while no Host is exposed. |
| Active Recording | The state in which the Lineage Recorder runs. All conditions apply: the app holds the writer lock; a live Session exists or the last one disappeared less than 60 s ago; a Host is exposed or Closed-Panel Recording is on. |
| Recording Coverage | The time ranges of Active Recording that the store retains. |
| Coverage Gap | The time between two retained Recording Coverage intervals. |
| Confirmation Dialog | The app-modal dialog for consent to a destructive action. See [ADR 0007](../adr/0007-confirmation-dialog-hosting.md). |

## Background and evidence

| Fact | Evidence |
| --- | --- |
| The Server Process removes its presence record at shutdown. No record of the Session remains after it ends. | [MCPServer.swift:127](../../Sources/StatsCore/MCPServer.swift#L127) |
| A presence record of an exited pid is deleted when any reader lists Sessions. | [Store.swift:415](../../Sources/StatsCore/Store.swift#L415) |
| A presence record holds the Server Process identity and the Agent Identity recorded on `initialize`. | [Store.swift:332](../../Sources/StatsCore/Store.swift#L332), [MCPServer.swift:321](../../Sources/StatsCore/MCPServer.swift#L321) |
| Tracks stop with reason `session_ended` when the Session ends. | [MCPServer.swift:126](../../Sources/StatsCore/MCPServer.swift#L126) |
| One sysctl call lists pid and ppid of all current-user processes without root. | [Proc.swift:162](../../Sources/StatsCore/Proc.swift#L162) |
| The executable name is the last path component of the executable path, or the kernel command name. | [Proc.swift:274](../../Sources/StatsCore/Proc.swift#L274) |
| The tracker already polls for new children every 250 ms during a track. | [ProcessTracker.swift:540](../../Sources/StatsCore/ProcessTracker.swift#L540) |
| aistats terminates only the process group of its own subprocesses. | [Subprocess.swift:135](../../Sources/StatsCore/Subprocess.swift#L135) |
| The app has a Confirmation Dialog with Cancel as the default. It accepts only a registration replacement consent. | [ConfirmationDialog.swift:5](../../Sources/AIStatsMenu/ConfirmationDialog.swift#L5), [ConfirmationDialog.swift:21](../../Sources/AIStatsMenu/ConfirmationDialog.swift#L21), [ADR 0007](../adr/0007-confirmation-dialog-hosting.md) |
| The app refreshes every 2 s. It reads the process table only while a Host is exposed. | [AppModel.swift:37](../../Sources/AIStatsMenu/AppModel.swift#L37), [AppModel.swift:142](../../Sources/AIStatsMenu/AppModel.swift#L142) |
| Existing JSON Lines compaction keeps a line count. It has no age or byte limit. | [Store.swift:50](../../Sources/StatsCore/Store.swift#L50) |
| The agents directory is created with mode 0700. | [Store.swift:399](../../Sources/StatsCore/Store.swift#L399) |
| Process arguments can hold secrets and are never returned. | [Proc.swift:80](../../Sources/StatsCore/Proc.swift#L80) |

Live observations on one development Mac (not repeated for this document):

- Tool-call shells were children of the agent CLI process.
- Background jobs started with `nohup` or a double fork reparented to pid 1 when the per-call shell exited. After that, no parent link connects the job to its agent.
- Xcode build services and simulator processes ran under launchd during an agent build. They were never Descendants.

Inference: a report needs a record made while the parent link still exists. A scan after the session ends cannot find the link.

ADR 0009 gives the cost of one current-user table read measured with a read-only probe. Those values do not measure a recorder.

## Requirements

### Recording

| ID | Requirement | Acceptance check |
| --- | --- | --- |
| ORP-001 | During Active Recording, AIStats MUST write a Lineage Record for each observed Descendant. | Expose a Host. Test agent starts a shell that runs `sleep 600` in the foreground for 10 s. Read the store. Verify one Lineage Record for `sleep`. Repeat with both Hosts closed and Closed-Panel Recording on. |
| ORP-002 | A Lineage Record MUST contain pid, Start Token, executable name, Agent Identity, Session name, and first-seen time. | Validate one record from the ORP-001 check. |
| ORP-003 | A Lineage Record MUST NOT contain arguments, environment values, working directories, or executable paths. | Start a Descendant with a unique marker argument and environment value. Search the store files for both markers. |
| ORP-004 | During Active Recording, the recorder MUST observe each Descendant that remains a Descendant for at least 2 s. | Test agent starts 20 children that each live 2 s at random offsets. Verify 20 Lineage Records. Run once with a Host exposed and once with both Hosts closed and Closed-Panel Recording on. |
| ORP-005 | The recorder SHOULD link a detached job whose intermediate shell exits before the first observation. | ADR 0009 does not meet this requirement and records the reasons. Test agent runs `sh -c 'nohup sleep 600 >/dev/null 2>&1 &'`. Verify no Lineage Record for the job. Verify that the report omits it. |
| ORP-006 | Recording MUST NOT require root, an entitlement, or Endpoint Security. | Inspect the signed binary entitlements. Run ORP-001 as a standard user. |
| ORP-007 | Recording MUST add at most 0.5% of one core, averaged over 60 s with 8 Sessions. This applies with a Host exposed and with both Hosts closed. | Run `scripts/measure-cpu.swift` on the app process with and without recording, with 8 live Sessions. Exposed run: one Host exposed as in the SDD 0001 Open quiet scenario. Closed run: both Hosts closed and Closed-Panel Recording on. Compare the averages of each run separately. |
| ORP-008 | The store MUST stay within the ADR 0009 size limit and retention rules. | Write fixture records beyond 2 MiB. Include Descendant records of exited processes, a live Descendant record first seen 8 days earlier, unreferenced Session records of exited agents, coverage intervals that ended more than 7 days ago, and more than 2,000 coverage intervals. Run a compaction. Verify the ADR 0009 removal order: exited Descendant records, unreferenced Session records, coverage older than 7 days, coverage beyond 2,000 intervals, then Descendant records with the newest first-seen time first. Verify that the 8-day live record remains, each coverage interval is one line, and the file is at most 1.5 MiB after eviction. |
| ORP-009 | The store MUST reside under the AIStats data directory in a directory with mode 0700. | Run with `AISTATS_HOME` set to a disposable directory. Inspect the path and mode. |

### Activation, storage, and coverage

| ID | Requirement | Acceptance check |
| --- | --- | --- |
| ORP-040 | The app MUST be the only process that writes the store. | Run every MCP and CLI report path against a fixture store. Compare file bytes, modes, and modification times before and after. Start a second app instance. Verify that it does not write. |
| ORP-041 | The Lineage Recorder MUST read the process table only during Active Recording. | Trace recorder reads with one live Session. Expose a Host and verify reads at 1 s intervals. Close both Hosts with Closed-Panel Recording off. Verify zero reads from 2 s after close. End the last Session. Verify zero reads from 62 s after its end. |
| ORP-042 | Closed-Panel Recording MUST be off in a fresh profile. The app MUST store the setting in its user defaults domain under the key `lineageClosedPanelRecording`. | Delete the key from the app's defaults domain. Launch with an empty `AISTATS_HOME`. Close both Hosts with a live Session. Verify zero recorder reads. Turn the setting on. Verify reads and the key value `true`. Turn it off. Verify zero reads from 2 s later. Verify that no file under `AISTATS_HOME` holds the setting. |
| ORP-043 | A Descendant record MUST NOT contain the Chain, intermediate pids, or intermediate names. | Test agent → shell → child. Read the child record. Verify only the ORP-002 fields, `lastConfirmedAt`, and the record type. |
| ORP-044 | The store MUST keep one Session record per Agent Identity. Each Session line MUST hold the complete record. A reader MUST use the last decodable Session line of an Agent Identity. | Restart the Server Process under one test agent. Start a second Session under the same agent. Before a compaction, verify that the last Session line of that Agent Identity lists three server identities and that the report resolves one Session. Run a compaction. Verify exactly one Session line with three server identities. Verify that the first server exit does not end the Session. |
| ORP-045 | The writer MUST hold an exclusive lock for each append and compaction and replace the file atomically. | Run 100 report calls during repeated compactions. Verify that no call reports `unreadableRecords`. Verify file mode 0600 after each compaction. |
| ORP-046 | A reader MUST read only the store file of its own format version. | Fixture with only `v2.jsonl`. Verify no rows and reason `lineage_version_unsupported`. Add one undecodable line to `v1.jsonl`. Verify `unreadableRecords: 1`. |
| ORP-047 | The report MUST contain `lastObservedAt` and `coverageGaps`. | Fixture with two coverage intervals and one gap. Verify `coverageGaps: 1` and `lastObservedAt` at the last heartbeat or stop. |
| ORP-048 | `endedAt` MUST follow the ADR 0009 end time rules, with `endedAfter` when `endedAt` is null. | End a test agent during Active Recording. Verify `endedAt` within 2 s after the exit and `endedAfter: null`. Quit the app, then end another agent. Verify `endedAt: null` and `endedAfter` equal to the `lastLiveAt` of its Session record, which is the stop time of the last coverage interval. |
| ORP-049 | The report MUST contain `evictedRecords`: the number of Descendant records that size eviction removed in the last 7 days, as stored in Compaction records. | Empty store: verify `evictedRecords: 0`. Fixture with more than 2 MiB of live records. Run a compaction in the app. Then run the report from a separate MCP process and from the CLI. Verify that both report a count equal to the number of removed records. Advance the fixture clock past 7 days and run a compaction. Verify `evictedRecords: 0`. |
| ORP-050 | A release that includes the Lineage Recorder MUST include measured results of the ORP-007 Exposed run, the ORP-007 Closed run, and SDD 0001 PERF-004 with Closed-Panel Recording on. The release content MUST follow the ADR 0009 gate outcomes. | Inspect the release verification report. Verify the three measured values, the interval, and the Session count. Verify that the release content matches the ADR 0009 gate outcome for those values. |

### Detection

| ID | Requirement | Acceptance check |
| --- | --- | --- |
| ORP-010 | AIStats MUST report a process as an Orphan Candidate only with evidence from Table 1. | Start `sleep 600` from a Terminal shell outside any agent. Verify that the report does not contain it. |
| ORP-011 | AIStats MUST verify the Start Token of a candidate before each report. | Fixture store with a record whose pid now belongs to a newer process. Verify that the report omits it. |
| ORP-012 | AIStats MUST NOT report a process whose Ancestor Walk reaches a live Agent Process. | Agent A ends while its child runs under a still-live agent B. Verify that the report omits the child. |
| ORP-013 | AIStats MUST NOT report Agent Processes or aistats Server Processes. | Fixture store that records a nested agent and an `aistats mcp` process. Verify that the report omits both. |
| ORP-014 | A Lineage Record MUST become an Orphan Candidate within 10 s after its Agent Process ends. | Test agent starts `sleep 600` in the foreground and exits. Poll the report every second. Repeat with the app quit after the record is written. |

#### Table 1 · Evidence values

| Value | Condition |
| --- | --- |
| `lineage` | The recorder observed the process as a Descendant while the Agent Process was live. |
| (none) | ADR 0009 accepts no additional value. A process without a `lineage` record has unknown origin. |

### Report

| ID | Requirement | Acceptance check |
| --- | --- | --- |
| ORP-020 | `tools/list` MUST include the report tool with `readOnlyHint: true` and `openWorldHint: false`. | Stdio probe: send `tools/list`. Inspect the annotations of the tool that the ADR names. |
| ORP-021 | The report MUST contain `observedAt`, `coverageSince`, `lastObservedAt`, `coverageGaps`, `evictedRecords`, `unreadableRecords`, `reason`, `processes`, `matched`, and `truncated`. Each field MUST follow the ADR 0009 Report surface table. | Stdio probe with an empty store, with one candidate, and with only a `v2.jsonl` file. Validate the field set and the null values in each case. |
| ORP-022 | Each `processes` row MUST contain `pid`, `startToken`, `name`, `memoryBytes`, `cpuSeconds`, `startedAt`, `session`, `endedAt`, `endedAfter`, and `evidence`. Exactly one of `endedAt` and `endedAfter` MUST be non-null. | Validate the row from the ORP-014 check and the row from its app-quit run. Compare `cpuSeconds` with the user and system time of the process. |
| ORP-023 | The report MUST NOT measure CPU over an interval. | Time 20 report calls. Verify that each call returns in under 300 ms. |
| ORP-024 | The report MUST list at most 15 rows, sorted by `memoryBytes`, largest first. | Fixture store with 20 live candidates. Verify 15 rows, `matched: 20`, and `truncated: true`. |
| ORP-025 | `structuredContent` MUST fit the response budget of [SDD 0005](0005-response-size-budget.md). | Measure the ORP-024 result in bytes. |
| ORP-026 | The tool description MUST state that an empty list covers only the time since `coverageSince`. | Read the tool description in `tools/list`. |
| ORP-027 | The MCP tool and the CLI MUST NOT signal, stop, or terminate any process. | Inspect the tool schema and CLI usage for such an action. Run every report path with a fixture candidate. Verify that it still runs. |
| ORP-028 | `aistats orphans --json` MUST print the JSON object of the MCP report. | Run the command and the stdio probe. Compare the field sets. |
| ORP-029 | `aistats orphans` MUST exit with 0 for an empty or non-empty report. | Run with an empty store and with one candidate. Check the exit code. |

### App action

| ID | Requirement | Acceptance check |
| --- | --- | --- |
| ORP-030 | The app MAY list Orphan Candidates with a termination action per row. | Not applicable. |
| ORP-031 | The app MUST show a Confirmation Dialog before it signals a process. | Activate the action. Verify the dialog. Press Return. Verify that the process still runs. |
| ORP-032 | The Confirmation Dialog MUST show the process name, pid, Session name, and the time since the Session ended. If `endedAt` is null, the dialog MUST state that the end time is unknown and show the time since `endedAfter`. | Inspect the dialog for a fixture candidate with `endedAt`. Inspect it for a fixture candidate with `endedAt: null`. Verify the unknown end time text and the time since `endedAfter`. |
| ORP-033 | The app MUST re-verify the pid and Start Token immediately before it signals. | Replace the candidate with a new process at the same pid in a test hook. Confirm. Verify that no signal reaches the new process. |
| ORP-034 | The app MUST signal only the confirmed process, not its process group or children. | Candidate with one child. Confirm. Verify that the child still runs. |
| ORP-035 | The app MUST show the result of each termination attempt. | Confirm for a process that ignores the signal. Verify a visible failure state. |
| ORP-036 | The app MUST send exactly one SIGTERM per confirmation and no other signal. | Confirm for a process that ignores SIGTERM. Trace signals for 10 s. Verify one SIGTERM and no SIGKILL. |
| ORP-037 | The termination dialog MUST use `프로세스 종료` as its destructive label and follow ADR 0007. | Open the dialog from each Host. Verify the label, initial focus on `취소`, and that Return cancels. |

## Non-goals

- Automatic termination, by AIStats, an agent, a hook, or a timer.
- Termination through MCP or the CLI.
- Attribution of processes that were never Descendants, such as Xcode build services or simulators under launchd.
- Processes of other users.
- Attribution to a conversation or subagent. The unit is the Agent Process.
- Report of processes that exited before the report.

## Dependencies and related specs

- [SDD 0009](0009-agent-sessions-mcp.md): Agent Identity and the Ancestor Walk. Implementation of this specification depends on AGT-001.
- [SDD 0003](0003-top-process-identity.md): the `startToken` field name.
- [SDD 0005](0005-response-size-budget.md): the response byte budget.
- [SDD 0008](0008-cli-parity.md): CLI `--json` and exit code conventions.
- [SDD 0016](0016-simulator-resources.md) may reuse Lineage Records for owner attribution.
- [ADR 0007](../adr/0007-confirmation-dialog-hosting.md): the Confirmation Dialog hosting rule.

## Open questions

- No recorder cost is measured. The values of ORP-004, ORP-007, ORP-014, and ORP-023 are budgets. ORP-050 makes the measurement a release gate. ADR 0009 names the fallback.
- The rate of short-lived Descendants between compactions is not measured. The 2 MiB compaction trigger bounds the file.

Resolved by ADR 0009:

- The recorder is the app. A detached job that reparents before the first observation has unknown origin.
- AIStats does not read process groups, session ids, or environment markers as evidence.
- A Server Process restart during one agent run keeps the same Session record. Only the Agent Process exit ends ownership.
- App downtime and Closed-Panel Recording off leave Coverage Gaps. The report discloses them.
- No dismiss action exists. A separate ADR must decide one.
