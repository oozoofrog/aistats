# SDD 0013 · Orphan Report

Status · Proposed
Issue · [#12](https://github.com/oozoofrog/aistats/issues/12)
Proposed decision · [ADR 0009 · Record observed descendant identities for the orphan report](../adr/0009-orphan-lineage.md)

## Purpose and scope

An ADR MUST be accepted before implementation of this specification. That ADR must make these decisions:

1. The recorder: the Server Process, the app, or both, and the observation interval.
2. The linkage evidence in addition to `lineage`, for example process group, session id, or inherited environment markers. The ADR must state the privacy rule for each evidence type.
3. The storage location, format, retention age, and size limit of Lineage Records.
4. The events that end a Session for this report in addition to Agent Process exit, for example Server Process exit.
5. The report surface: a separate MCP tool, a section of `get_agent_sessions`, or both.
6. The app termination action: the signal sequence, the confirmation text, and the re-verification rule.

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
| Recording Coverage | The time range in which a recorder observed Descendants. |
| Confirmation Dialog | The app-modal dialog for consent to a destructive action. See [ADR 0007](../adr/0007-confirmation-dialog-hosting.md). |

## Background and evidence

| Fact | Evidence |
| --- | --- |
| The Server Process removes its presence record at shutdown. No record of the Session remains after it ends. | [MCPServer.swift:125](../../Sources/StatsCore/MCPServer.swift#L125) |
| A presence record of an exited pid is deleted when any reader lists Sessions. | [Store.swift:360](../../Sources/StatsCore/Store.swift#L360) |
| A presence record holds the Server Process identity, not the Agent Process. | [Store.swift:280](../../Sources/StatsCore/Store.swift#L280), [MCPServer.swift:300](../../Sources/StatsCore/MCPServer.swift#L300) |
| Tracks stop with reason `session_ended` when the Session ends. | [MCPServer.swift:124](../../Sources/StatsCore/MCPServer.swift#L124) |
| One sysctl call lists pid and ppid of all current-user processes without root. | [Proc.swift:155](../../Sources/StatsCore/Proc.swift#L155) |
| The tracker already polls for new children every 250 ms during a track. | [ProcessTracker.swift:536](../../Sources/StatsCore/ProcessTracker.swift#L536) |
| aistats terminates only the process group of its own subprocesses. | [Subprocess.swift:132](../../Sources/StatsCore/Subprocess.swift#L132) |
| The app has a Confirmation Dialog with Cancel as the default for registration replacement. | [ConfirmationDialog.swift:21](../../Sources/AIStatsMenu/ConfirmationDialog.swift#L21), [ADR 0007](../adr/0007-confirmation-dialog-hosting.md) |
| The agents directory is created with mode 0700. | [Store.swift:344](../../Sources/StatsCore/Store.swift#L344) |
| Process arguments can hold secrets and are never returned. | [Proc.swift:80](../../Sources/StatsCore/Proc.swift#L80) |

Live observations on one development Mac (not repeated for this document):

- Tool-call shells were children of the agent CLI process.
- Background jobs started with `nohup` or a double fork reparented to pid 1 when the per-call shell exited. After that, no parent link connects the job to its agent.
- Xcode build services and simulator processes ran under launchd during an agent build. They were never Descendants.

Inference: a report needs a record made while the parent link still exists. A scan after the session ends cannot find the link.

## Requirements

### Recording

| ID | Requirement | Acceptance check |
| --- | --- | --- |
| ORP-001 | While an Agent Process is live, AIStats MUST write a Lineage Record for each observed Descendant. | Test agent starts a shell that runs `sleep 600` in the foreground for 10 s. Read the store. Verify one Lineage Record for `sleep`. |
| ORP-002 | A Lineage Record MUST contain pid, Start Token, executable name, Agent Identity, Session name, and first-seen time. | Validate one record from the ORP-001 check. |
| ORP-003 | A Lineage Record MUST NOT contain arguments, environment values, working directories, or executable paths. | Start a Descendant with a unique marker argument and environment value. Search the store files for both markers. |
| ORP-004 | The recorder MUST observe each Descendant that remains a Descendant for at least 2 s. | Test agent starts 20 children that each live 2 s at random offsets. Verify 20 Lineage Records. |
| ORP-005 | The recorder SHOULD link a detached job whose intermediate shell exits before the first observation. | Test agent runs `sh -c 'nohup sleep 600 >/dev/null 2>&1 &'`. Verify a Lineage Record with an ADR evidence value. |
| ORP-006 | Recording MUST NOT require root, an entitlement, or Endpoint Security. | Inspect the signed binary entitlements. Run ORP-001 as a standard user. |
| ORP-007 | Recording MUST add at most 0.5% of one core, averaged over 60 s with 8 Sessions. | Run `scripts/measure-cpu.swift` on the recorder process with and without recording. Compare averages. |
| ORP-008 | The store MUST stay within the ADR size limit and retention age. | Write fixture records beyond both limits. Verify that the oldest records are removed first. |
| ORP-009 | The store MUST reside under the AIStats data directory in a directory with mode 0700. | Run with `AISTATS_HOME` set to a disposable directory. Inspect the path and mode. |

### Detection

| ID | Requirement | Acceptance check |
| --- | --- | --- |
| ORP-010 | AIStats MUST report a process as an Orphan Candidate only with evidence from Table 1. | Start `sleep 600` from a Terminal shell outside any agent. Verify that the report does not contain it. |
| ORP-011 | AIStats MUST verify the Start Token of a candidate before each report. | Fixture store with a record whose pid now belongs to a newer process. Verify that the report omits it. |
| ORP-012 | AIStats MUST NOT report a process whose Ancestor Walk reaches a live Agent Process. | Agent A ends while its child runs under a still-live agent B. Verify that the report omits the child. |
| ORP-013 | AIStats MUST NOT report Agent Processes or aistats Server Processes. | Fixture store that records a nested agent and an `aistats mcp` process. Verify that the report omits both. |
| ORP-014 | A Lineage Record MUST become an Orphan Candidate within 10 s after its Agent Process ends. | Test agent starts `sleep 600` in the foreground and exits. Poll the report every second. |

#### Table 1 · Evidence values

| Value | Condition |
| --- | --- |
| `lineage` | The recorder observed the process as a Descendant while the Agent Process was live. |
| ADR-defined | Additional values that the ADR accepts, each with its own acceptance check. |

### Report

| ID | Requirement | Acceptance check |
| --- | --- | --- |
| ORP-020 | `tools/list` MUST include the report tool with `readOnlyHint: true` and `openWorldHint: false`. | Stdio probe: send `tools/list`. Inspect the annotations of the tool that the ADR names. |
| ORP-021 | The report MUST contain `observedAt`, `coverageSince`, `processes`, `matched`, and `truncated`. | Stdio probe with an empty store and with one candidate. Validate the field set. |
| ORP-022 | Each `processes` row MUST contain `pid`, `startToken`, `name`, `memoryBytes`, `cpuSeconds`, `startedAt`, `session`, `endedAt`, and `evidence`. | Validate the row from the ORP-014 check. Compare `cpuSeconds` with the user and system time of the process. |
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
| ORP-032 | The Confirmation Dialog MUST show the process name, pid, Session name, and the time since the Session ended. | Inspect the dialog for a fixture candidate. |
| ORP-033 | The app MUST re-verify the pid and Start Token immediately before it signals. | Replace the candidate with a new process at the same pid in a test hook. Confirm. Verify that no signal reaches the new process. |
| ORP-034 | The app MUST signal only the confirmed process, not its process group or children. | Candidate with one child. Confirm. Verify that the child still runs. |
| ORP-035 | The app MUST show the result of each termination attempt. | Confirm for a process that ignores the signal. Verify a visible failure state. |

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

- No observation interval is measured. The ORP-004 value of 2 s, the ORP-007 CPU limit, the ORP-014 limit of 10 s, and the ORP-023 limit of 300 ms are proposals.
- A detached job can reparent to pid 1 within milliseconds. Interval sampling cannot see that link. Whether process group or session id survives in such jobs is not verified for any agent.
- Whether agents set an inherited environment marker in tool-call shells is not verified. Reading the environment of a process returns secrets with the marker. The ADR must decide whether to read it.
- If the recorder is the Server Process, the recorder ends with the Session. Whether the last observation before the end is sufficient is not verified.
- If the recorder is the app, Recording Coverage has gaps while the app does not run.
- Some agents may close and restart the Server Process during one agent run. The effect on Ended Session detection is not verified.
- Some users leave development servers running on purpose. The report can show them as Orphan Candidates. A dismiss action is not specified.
