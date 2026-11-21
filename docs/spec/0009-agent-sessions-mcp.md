# SDD 0009 · Agent Sessions over MCP

Status · Proposed
Issue · [#8](https://github.com/oozoofrog/aistats/issues/8)

## Purpose and scope

This specification adds one read-only MCP tool, `get_agent_sessions`. The tool lists the connected aistats Sessions and the recent tool calls of all Sessions. It also attributes Busy Processes to the Agent Process that started them. An agent can then answer the question "is the load mine, another session's, or neither?" in one call.

The specification also extends the existing CLI command `aistats agents` with the same data. It does not change the eight existing tools. It does not report processes of ended Sessions; [SDD 0013](0013-orphan-report.md) covers them.

The key words "MUST", "MUST NOT", "SHOULD", "SHOULD NOT", and "MAY" in this document are to be interpreted as described in BCP 14 [RFC2119] [RFC8174] when, and only when, they appear in all capitals.

[RFC2119]: https://www.rfc-editor.org/rfc/rfc2119.html
[RFC8174]: https://www.rfc-editor.org/rfc/rfc8174.html

## Terms

| Term | Meaning |
| --- | --- |
| Session | One running `aistats mcp` server process and its presence record. |
| Server Process | The `aistats mcp` process of one Session. |
| Agent Process | The parent process of a Server Process, recorded when the Session receives `initialize`. |
| Agent Identity | The pid and Start Token of an Agent Process. |
| Start Token | The decimal `ri_proc_start_abstime` value that `find_processes` returns as `startToken`. |
| Busy Process | One of the current-user processes with the highest CPU percentage in one measurement. |
| Ancestor Walk | The sequence of parent links from a process up to pid 1. |
| Attributed | A Busy Process whose Ancestor Walk reaches a live Agent Process. |
| Unattributed | A Busy Process whose Ancestor Walk reaches no live Agent Process. |
| Host App | A process that is an ancestor of two or more Agent Processes. |

Attribution granularity is the Agent Process. A conversation and its subagents share one Agent Process, so this specification cannot separate them.

## Background and evidence

| Fact | Evidence |
| --- | --- |
| A presence record stores the Server Process pid and Start Token, not the Agent Process. | [Store.swift:280](../../Sources/StatsCore/Store.swift#L280), [MCPServer.swift:32](../../Sources/StatsCore/MCPServer.swift#L32), [MCPServer.swift:300](../../Sources/StatsCore/MCPServer.swift#L300) |
| The Session name comes from `clientInfo.name` and gets a numeric suffix when taken. | [MCPServer.swift:278](../../Sources/StatsCore/MCPServer.swift#L278), [Store.swift:372](../../Sources/StatsCore/Store.swift#L372) |
| A presence record is valid only while its pid has the same start time. Stale records are deleted on read. | [Store.swift:294](../../Sources/StatsCore/Store.swift#L294), [Store.swift:360](../../Sources/StatsCore/Store.swift#L360) |
| The Session removes its presence record on shutdown. | [MCPServer.swift:125](../../Sources/StatsCore/MCPServer.swift#L125) |
| The activity log keeps the last 200 calls of all Sessions. A call has date, agent, tool, and detail. | [Store.swift:278](../../Sources/StatsCore/Store.swift#L278), [Store.swift:302](../../Sources/StatsCore/Store.swift#L302) |
| The call detail records only that an argument filter was used, never its text. | [MCPServer.swift:595](../../Sources/StatsCore/MCPServer.swift#L595) |
| Only the CLI `aistats agents` and the app read Sessions and calls. MCP does not expose them. | [main.swift:123](../../Sources/aistats/main.swift#L123), [AppModel.swift:145](../../Sources/AIStatsMenu/AppModel.swift#L145) |
| `Proc.parent` reads one parent pid. `Proc.currentUserTable` reads pid and ppid of all current-user processes in one sysctl call. | [Proc.swift:105](../../Sources/StatsCore/Proc.swift#L105), [Proc.swift:155](../../Sources/StatsCore/Proc.swift#L155) |
| The tracker already builds parent and child maps from one table scan and caps an ancestor loop at 64 steps. | [ProcessTracker.swift:815](../../Sources/StatsCore/ProcessTracker.swift#L815), [ProcessTracker.swift:834](../../Sources/StatsCore/ProcessTracker.swift#L834), [ProcessTracker.swift:848](../../Sources/StatsCore/ProcessTracker.swift#L848) |
| `get_top_processes` measures for 1.0 s. Its rows have pid, name, cpuPercent, and memoryBytes only. | [MCPServer.swift:437](../../Sources/StatsCore/MCPServer.swift#L437), [Snapshot.swift:110](../../Sources/StatsCore/Snapshot.swift#L110) |
| Process usage of other users is unreadable without root. | [SystemSampler.swift:317](../../Sources/StatsCore/SystemSampler.swift#L317) |
| Process arguments can hold secrets and are never returned. | [Proc.swift:80](../../Sources/StatsCore/Proc.swift#L80) |

Live observations on one development Mac (not repeated for this document):

- The parent of the aistats Server Process was the agent CLI process. Tool-call shells were children of the same agent CLI process.
- One desktop Host App was the common ancestor of several agent sessions. Eight aistats Sessions ran at the same time.
- Background jobs started with `nohup` or a double fork reparented to pid 1 when the per-call shell exited.
- Xcode build services, simulator processes, and SourceKit services ran under launchd. A parent link cannot attribute them.

## Requirements

### Agent Identity

| ID | Requirement | Acceptance check |
| --- | --- | --- |
| AGT-001 | On `initialize`, the Server Process MUST record the Agent Identity in its presence record. | Start `aistats mcp` from a test parent process. Send `initialize`. Read the presence file. Compare the recorded pid and Start Token with the test parent. |
| AGT-002 | If the parent cannot be read or is pid 1, the Session MUST record no Agent Identity. | Unit test `AgentIdentityTests.testNoIdentityForLaunchdParent` with an injected parent of 1 and an unreadable parent. |
| AGT-003 | The app and CLI MUST decode presence records without Agent Identity fields. | Decode a presence record written by v0.3.0. Verify that `connectedAgents()` returns it and that the Session has no Agent Identity. |
| AGT-004 | The server MUST treat an Agent Process as live only when its pid has the recorded Start Token. | Unit test with a fixture table where the agent pid has a different start time. Verify that no process is Attributed to it. |

### Tool contract

| ID | Requirement | Acceptance check |
| --- | --- | --- |
| AGT-010 | `tools/list` MUST include `get_agent_sessions` with `readOnlyHint: true` and `openWorldHint: false`. | Stdio probe: send `tools/list`. Inspect the tool entry and its annotations. |
| AGT-011 | `get_agent_sessions` MUST accept the optional arguments `calls`, `attribute`, and `limit`. | Inspect `inputSchema`. Verify integer `calls` 0–20 with default 5, boolean `attribute` with default true, and integer `limit` 1–15 with default 10. |
| AGT-012 | The tool MUST reject an out-of-range or wrongly typed argument with `isError: true`. | Stdio probe with `calls: 21`, `limit: 0`, and `attribute: "yes"`. Verify an error result for each call. |
| AGT-013 | The result MUST contain `observedAt`, `caller`, `sessions`, `recentCalls`, and `truncated`. | Stdio probe with default arguments. Validate the field set of `structuredContent`. |
| AGT-014 | `caller` MUST equal the Session name of the Session that answers the call. | Start two Sessions with `--name a` and `--name b`. Call the tool in each Session. Compare `caller`. |
| AGT-015 | Each `sessions` row MUST contain `name`, `connectedAt`, `lastSeen`, and `serverPid`. | Stdio probe with two live Sessions. Validate both rows. |
| AGT-016 | A `sessions` row MUST contain `client`, `agentPid`, `agentStartToken`, and `agentName` when each value is known. | Unit test with one Session that has an Agent Identity and a client name. Validate the row. |
| AGT-017 | A `sessions` row MUST omit an unknown value instead of returning null or 0. | Unit test with one Session without Agent Identity or client name. Verify that the four fields are absent. |
| AGT-018 | `recentCalls` MUST list at most `calls` calls of all Sessions, newest first. | Write 30 fixture calls to a disposable activity log. Call with `calls: 7`. Verify seven rows in descending `date` order. |
| AGT-019 | Each `recentCalls` row MUST contain `date`, `agent`, and `tool`. | Stdio probe after one `find_processes` call. Validate the newest row. |
| AGT-020 | The tool MUST NOT return process arguments, environment values, or working directories. | Start a Busy Process with a unique marker argument. Search the whole JSON-RPC response line for the marker. |
| AGT-021 | The tool MUST work when the AIStats app is not running. | Quit the app. Run the stdio probe. Verify a non-error result with the live Sessions. |
| AGT-022 | `recentCalls` MUST NOT contain the text of an `argsContain` filter. | Call `find_processes` with a unique `argsContain` marker. Search the `get_agent_sessions` response line for the marker. |

### Attribution

| ID | Requirement | Acceptance check |
| --- | --- | --- |
| AGT-030 | With `attribute: true`, the result MUST contain `busy`, the top `limit` processes by CPU over one 1.0 s measurement. | Stdio probe with `limit: 3` during a CPU load. Verify at most three rows in descending `cpuPercent` order. |
| AGT-031 | Each `busy` row MUST contain `pid`, `startToken`, `name`, `cpuPercent`, and `memoryBytes`. | Validate each row. Compare `startToken` with `find_processes` for the same pid. |
| AGT-032 | The Ancestor Walk MUST start at the Busy Process itself. | Fixture test: the Agent Process is the Busy Process. Verify that the row has its own `agentPid`. |
| AGT-033 | The Ancestor Walk MUST stop at the first live Agent Process. | Fixture test: agent B runs under a shell of agent A. A child of B is busy. Verify `agentPid` equals B. |
| AGT-034 | An Attributed row MUST contain the `agentPid` of the Agent Process where the walk stopped. | Start `sh -c 'yes > /dev/null'` from a test agent. Verify that the `yes` row has the test agent pid. |
| AGT-035 | The server MUST NOT attribute a process through a Host App or another ancestor above an Agent Process. | Fixture test: Host App H with agents A1 and A2. A busy helper is a child of H. Verify that the helper is Unattributed. |
| AGT-036 | An Unattributed row MUST contain `unattributed` with one value from Table 1. | Fixture tests for each value in Table 1. |
| AGT-037 | The Ancestor Walk MUST end after 64 parent links. | Fixture test with a parent cycle and a 100-deep chain. Verify termination and `unattributed: "walk_limit"`. |
| AGT-038 | The Ancestor Walk MUST use at most one process table read per call. | Count `Proc.currentUserTable` calls with a test hook during one tool call. |
| AGT-039 | With `attribute: false`, the result MUST NOT contain `busy`. | Stdio probe with `attribute: false`. Verify that `busy` is absent. |
| AGT-040 | The tool SHOULD state in its description that subagents share their parent's Agent Process. | Read the tool description in `tools/list`. |
| AGT-041 | With `attribute: false`, the tool MUST return in under 300 ms. | Time 10 stdio calls with `attribute: false` and 8 fixture Sessions. Verify that each call takes under 300 ms. |

#### Table 1 · Unattributed reasons

| Value | Condition |
| --- | --- |
| `no_agent_ancestor` | The walk reached pid 1 without a live Agent Process. |
| `ancestry_unreadable` | A parent link could not be read before the walk ended. |
| `walk_limit` | The walk reached 64 links without an end. |

### Size and text

| ID | Requirement | Acceptance check |
| --- | --- | --- |
| AGT-050 | `structuredContent` MUST fit the response budget of [SDD 0005](0005-response-size-budget.md). | Stdio probe with 8 fixture Sessions, `calls: 20`, and `limit: 15`. Measure the `structuredContent` bytes. |
| AGT-051 | To fit the budget, the server MUST remove oldest calls first, then lowest-CPU `busy` rows. | Same probe. Verify the removal order and `truncated: true`. |
| AGT-052 | The summary text MUST NOT contain a fact that is absent from `structuredContent`. | Apply the check of [SDD 0004](0004-summary-facts-in-json.md) to this tool. |
| AGT-053 | The activity log MUST record each `get_agent_sessions` call with the tool name. | Call the tool. Read the newest activity log row. |

### CLI

| ID | Requirement | Acceptance check |
| --- | --- | --- |
| AGT-060 | `aistats agents --json` MUST print the JSON object of the MCP tool with default arguments, without `caller`. | Run the command and the stdio probe within 5 s. Compare the field sets. Ignore measured values. |
| AGT-061 | `aistats agents` MUST accept `--calls N` and `--no-attribute` with the MCP ranges. | Run with `--calls 20 --no-attribute`. Verify status 0. Run with `--calls 21`. Verify status 1 and an error message on stderr. |
| AGT-062 | Without `--json`, `aistats agents` SHOULD print each Busy Process with its Agent Process or `unattributed`. | Run during a CPU load from a test agent. Read the output. |

## Non-goals

- Attribution of processes that have reparented to pid 1. [SDD 0013](0013-orphan-report.md) covers processes of ended Sessions.
- Attribution to a conversation or subagent. The unit is the Agent Process.
- Attribution of Xcode build services, simulators, or other launchd children by heuristics such as name or start time.
- Other users' processes.
- New fields in `get_top_processes`. [SDD 0003](0003-top-process-identity.md) owns that row shape.
- A process stop or kill action.

## Dependencies and related specs

- [SDD 0003](0003-top-process-identity.md): `startToken` and `ppid` in process rows. `busy` rows SHOULD use the same field names.
- [SDD 0004](0004-summary-facts-in-json.md): summary facts in JSON.
- [SDD 0005](0005-response-size-budget.md): the `structuredContent` byte budget.
- [SDD 0008](0008-cli-parity.md): CLI `--json` and exit code conventions.
- [SDD 0011](0011-instructions-priority.md): a routing line for the new tool must fit the instructions budget.
- [SDD 0012](0012-schema-dedup.md): the new tool adds schema bytes for eager-loading clients.
- [SDD 0013](0013-orphan-report.md) and [SDD 0016](0016-simulator-resources.md) reuse the Agent Identity.

## Open questions

- Some clients may start the server through a wrapper, such as a shell or a package runner. The parent is then the wrapper, and tool-call processes are its siblings. The walk then reports them as Unattributed, not misattributed. The parent process of each supported agent is not verified except one CLI agent.
- Whether an agent spawns tool-call processes from the Agent Process or from a separate helper process is not verified for Codex, Gemini CLI, Cursor, or Claude Desktop.
- The 300 ms latency in AGT-041 is a proposed budget, not a measurement.
- The byte estimate for 8 Sessions, 10 `busy` rows, and 5 calls is about 3 KB at about 4 bytes per token. It is not measured.
- Whether exposing other Sessions' tool names and Session names to every agent is acceptable on shared accounts is not decided. All data belongs to the same user.
