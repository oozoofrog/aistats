# SDD 0016 · Simulator Resources

Status · Proposed
Issue · [#15](https://github.com/oozoofrog/aistats/issues/15)
Decision · [ADR 0012 · Account for visible simulator process trees without an owner registry](../adr/0012-simulator-accounting.md)

## Purpose and scope

An ADR MUST be accepted before implementation of this specification. That ADR must make these decisions:

1. The source of device identity (UDID, device name, runtime): a `simctl` subprocess, CoreSimulator device files, or none. The ADR must state the latency and the Xcode dependency of the source.
2. The processes that count toward one device: the Descendants of its Device Root only, or also per-device host-side processes.
3. The source of owner attribution: none, Lineage Records of [SDD 0013](0013-orphan-report.md), or a read-only view of Claims that a Simulator Manager keeps.
4. The device sets in scope, for example the default set and the Xcode Previews set.
5. The surfaces: an MCP tool, a CLI command, a `diagnose_system` evidence line, and an app section.

[ADR 0012](../adr/0012-simulator-accounting.md) records these decisions and the amendments below.

This specification adds a read-only report of CPU and memory use for each booted simulator device. An agent can then see whether simulators cause the load before it starts a build or a test. ADR 0012 selects no owner source for v1. Each v1 row therefore reports `ownerUnknown: "no_source"` and names no Session. A later ADR can add an owner source.

AIStats MUST NOT duplicate the Boot Budget or the Claims of a Simulator Manager. SIM-030 to SIM-033 give the checks. AIStats reports use; it does not manage devices.

The key words "MUST", "MUST NOT", "SHOULD", "SHOULD NOT", and "MAY" in this document are to be interpreted as described in BCP 14 [RFC2119] [RFC8174] when, and only when, they appear in all capitals.

[RFC2119]: https://www.rfc-editor.org/rfc/rfc2119.html
[RFC8174]: https://www.rfc-editor.org/rfc/rfc8174.html

## Terms

| Term | Meaning |
| --- | --- |
| Device Root | A current-user `launchd_sim` process. One Device Root represents one booted simulator device. |
| Device Process | For one Device Root R: R itself, or a process that is not a Device Root and whose Ancestor Walk reaches R before it reaches any other Device Root or any agent root of [SDD 0017](0017-process-origin.md). A Nested Root is never a Device Process of the outer Device Root. |
| Nested Root | A Device Root whose Ancestor Walk reaches another Device Root. |
| Ancestor Walk | The sequence of observed parent links from a process up to pid 1. An observed link requires that the parent started no later than the child, as in `ProcessTree`. |
| Host Service | A simulator support process outside every Device Root, for example `CoreSimulatorService`, `SimLaunchHost`, or `simdiskimaged`. |
| Start Token | The decimal `ri_proc_start_abstime` value that `find_processes` returns as `startToken`. |
| Session | One running `aistats mcp` server process and its presence record. See [SDD 0009](0009-agent-sessions-mcp.md). |
| Owner | The Session that started or claimed a device, from an owner source. ADR 0012 selects no owner source for v1. |
| Synthetic Device Root | A current-user test process named `launchd_sim` that the procedure below starts. It is not a simulator device. |
| Simulator Manager | A separate tool that limits concurrently booted devices and records which session uses each device. |
| Boot Budget | The limit on concurrently booted devices that a Simulator Manager enforces. |
| Claim | A Simulator Manager record that one session uses one device. |

## Background and evidence

| Fact | Evidence |
| --- | --- |
| The sampler reads usage for every pid and skips processes it cannot read. | [SystemSampler.swift:300](../../Sources/StatsCore/SystemSampler.swift#L300), [SystemSampler.swift:317](../../Sources/StatsCore/SystemSampler.swift#L317) |
| One sysctl call lists pid and ppid of all current-user processes. | [Proc.swift:155](../../Sources/StatsCore/Proc.swift#L155) |
| `get_top_processes` measures CPU for 1.0 s. | [MCPServer.swift:437](../../Sources/StatsCore/MCPServer.swift#L437) |
| aistats already runs `xcrun` as a cancellable subprocess with a timeout and caches the result for 300 s. | [Subprocess.swift:66](../../Sources/StatsCore/Subprocess.swift#L66), [Diagnosis.swift:150](../../Sources/StatsCore/Diagnosis.swift#L150), [Diagnosis.swift:212](../../Sources/StatsCore/Diagnosis.swift#L212) |
| `ProcessTree.measure` takes one 1.0 s sample and builds the current-user tree. | [ProcessTree.swift:82](../../Sources/StatsCore/ProcessTree.swift#L82) |
| The tree adds each own reading to every observed ancestor and stops at agent roots. `TreeMetrics.partial` marks totals with an unreadable reading. | [ProcessTree.swift:158](../../Sources/StatsCore/ProcessTree.swift#L158), [ProcessTree.swift:7](../../Sources/StatsCore/ProcessTree.swift#L7) |
| The tree panel lists `launchd_sim` roots under “출발점 불명 · launchd”. ORG-019 checks simulator fixtures there. | [ProcessTreeView.swift:62](../../Sources/AIStatsMenu/ProcessTreeView.swift#L62), [SDD 0017](0017-process-origin.md) |
| The Agent Identity of a Session is specified in SDD 0009, not implemented. | [SDD 0009](0009-agent-sessions-mcp.md) |
| Process arguments can hold secrets and are never returned. | [Proc.swift:80](../../Sources/StatsCore/Proc.swift#L80) |

Live observations on one development Mac with two booted devices (`ps`, not repeated):

- Each booted device had one `launchd_sim` process. Both were owned by the current user and had ppid 1.
- The two Device Roots had 175 and 317 direct children.
- A later, separate `ps` observation on the same Mac gave 162 and 227 direct children and 956 current-user processes. Child counts change over time, so the two observations differ.
- `CoreSimulatorService`, `SimulatorTrampoline`, and `SimLaunchHost` ran under launchd as the current user. `simdiskimaged` ran as root.
- An installed app inside a device had an executable path that contained the device UDID. Runtime system processes had paths inside the runtime image, without a UDID.
- Simulators started by an agent ran under launchd. A parent link cannot connect them to the agent.

### Synthetic Device Root procedure

Use this procedure when no booted device is available for authorized testing. It was checked on one Mac with macOS 27.2. A plain copy of `/bin/bash` was stopped by the system at launch, and a symbolic link kept the kernel name `bash`. An ad hoc signed copy ran with the kernel name `launchd_sim`.

1. Copy `/bin/bash` to an empty scratch directory under the name `launchd_sim`.
2. Sign the copy ad hoc with `codesign -f -s - launchd_sim`.
3. Start it as the current user with `./launchd_sim -c 'i=0; while [ $i -lt 500 ]; do sleep 600 & i=$((i+1)); done; wait'`.
4. Count the current-user processes with `ps -U "$(id -u)" -o pid= | wc -l`.
5. If the count is below 1,000, start more `sleep 600` processes outside the Synthetic Device Root until the count reaches 1,000.
6. Run the check.
7. Stop the Synthetic Device Root, its children and the extra `sleep` processes. Delete the scratch directory.

The minimum of 1,000 current-user processes matches the table size observed with two booted devices. The cost of `ProcessTree.measure` depends on the size of the whole table, not only on one subtree.

## Requirements

### Report contract

| ID | Requirement | Acceptance check |
| --- | --- | --- |
| SIM-001 | `tools/list` MUST include `get_simulator_usage` with `readOnlyHint: true` and `openWorldHint: false`. | Stdio probe: send `tools/list`. Inspect the tool entry. |
| SIM-002 | The result MUST contain `observedAt`, `bootedCount`, `devices`, and `truncated`. | Stdio probe with zero and with one booted device. Validate the field set. |
| SIM-003 | The tool MUST return one `devices` row for each Device Root. | Boot one device. Compare `bootedCount` with the count of current-user `launchd_sim` processes. |
| SIM-004 | Each `devices` row MUST contain `rootPid`, `startToken`, `bootedAt`, `processCount`, `cpuPercent`, and `memoryBytes`, except as SIM-050 states. | Validate one row. Compare `rootPid` and `startToken` with `find_processes` for name `launchd_sim`. |
| SIM-005 | `cpuPercent` MUST be the sum over all Device Processes of one device in one 1.0 s measurement. | Run a CPU-bound app in one device. Compare the value with the sum of `get_top_processes` rows for its Device Processes. |
| SIM-006 | `cpuPercent` MUST use the `get_top_processes` scale, where 100 is one core. | Unit test with fixture process times. |
| SIM-007 | `memoryBytes` MUST be the sum of the physical footprints of all Device Processes of one device. | Unit test with fixture footprints. Inspect the field description in `tools/list` for "sum of footprints" and for a statement that shared memory can be counted more than once. |
| SIM-008 | A `devices` row MUST omit `udid`, `name`, and `runtime` when no identity source gives them. | ADR 0012 selects no identity source, so no source is disabled for this check. Run the stdio probe with the Synthetic Device Root. Verify that the three fields are absent, not empty. |
| SIM-009 | A `devices` row MUST contain `top`, at most three Device Processes by CPU with `pid`, `name`, `cpuPercent`, and `memoryBytes`. | Validate `top` for a device with a CPU-bound app. |
| SIM-010 | The tool MUST NOT count a Host Service toward any device. | Fixture table with `CoreSimulatorService` and one Device Root. Verify that the device totals exclude the service. |
| SIM-011 | In v1, the result MUST NOT contain `hostServices`. ADR 0012 changed this requirement from MAY. | Fixture table with one Device Root and `CoreSimulatorService`. Verify that `hostServices` is absent. Run the stdio probe with zero devices and with the Synthetic Device Root. Verify that `hostServices` is absent and that the output schema in `tools/list` does not define it. |
| SIM-012 | With no booted device, the tool MUST return `bootedCount: 0`, an empty `devices`, and `isError: false`. | Shut down all devices that this check booted. Run the stdio probe. |
| SIM-013 | Without Xcode, the tool MUST return a non-error result with the devices it finds. | Run with `DEVELOPER_DIR` set to an empty directory. Verify a non-error result. |
| SIM-014 | `structuredContent` MUST fit the response budget of [SDD 0005](0005-response-size-budget.md). | Fixture with four Device Roots and 300 processes each. Measure the bytes. |
| SIM-015 | The tool MUST NOT return arguments, environment values, or executable paths of Device Processes. | Search the response line for a marker argument of an app in the device and for the string `/Users/`. |
| SIM-016 | The tool MUST complete each call within 1.5 s. ADR 0012 removed the identity source condition. | Use the release build configuration. Time 10 stdio `tools/call` requests from the request write to the response read. Use two booted devices when they are available for authorized testing. Otherwise use the Synthetic Device Root procedure. Every call completes within 1.5 s. Record the conditions that ADR 0012 lists. |
| SIM-017 | A `devices` row MUST contain `partial`, the list of `cpu` and `memory` totals that miss an unreadable reading. | Fixture with one Device Process whose CPU reading is unreadable. Verify that `partial` contains `cpu` and not `memory`. With all readings, verify an empty `partial`. |
| SIM-050 | A `devices` row MUST omit `cpuPercent` or `memoryBytes` when no Device Process of that device has a readable reading of that metric. | Fixture where every CPU reading of one device is unreadable. Verify that `cpuPercent` is absent, not `0` or `null`. Verify that `partial` contains `cpu`. Repeat for `memoryBytes` and `memory`. |
| SIM-018 | A Nested Root MUST have its own `devices` row. | Fixture table with one `launchd_sim` below another. Verify two rows. |
| SIM-019 | The row of an outer Device Root MUST exclude every Device Process of a Nested Root. | Same fixture as SIM-018. Verify that the outer `processCount` excludes the inner subtree. Verify that the sum of row `processCount` values equals the count of Device Processes. |

### Owner attribution

| ID | Requirement | Acceptance check |
| --- | --- | --- |
| SIM-020 | A `devices` row MUST omit `owner` when no owner source gives a Session name. | ADR 0012 selects no owner source, so no source is disabled for this check. Run the stdio probe with the Synthetic Device Root. Verify that `owner` is absent. |
| SIM-021 | A `devices` row without `owner` MUST contain `ownerUnknown` with one value from Table 1. | Fixture test and stdio probe with the Synthetic Device Root. Verify `ownerUnknown: "no_source"` in every row. In v1, `not_recorded` and `ended` cannot occur, so v1 has no check for them. |
| SIM-022 | The tool MUST NOT infer an Owner from process names, start times, or the parent of a Device Root. | Start the Synthetic Device Root from a shell below a test agent session, so that its Ancestor Walk reaches the agent root. Verify that `owner` is absent and that `ownerUnknown` is `"no_source"`. |

#### Table 1 · Unknown owner reasons

| Value | Condition |
| --- | --- |
| `no_source` | No owner source is enabled or available. |
| `not_recorded` | The owner source has no record for this device. |
| `ended` | The recorded Owner Session has ended. |

In v1, only `no_source` occurs. ADR 0012 reserves `not_recorded` and `ended` for a later owner source. The ADR that adds such a source must add fixture tests for both values.

### Separation from a Simulator Manager

| ID | Requirement | Acceptance check |
| --- | --- | --- |
| SIM-030 | AIStats MUST NOT compute, report, or enforce a Boot Budget. | Inspect the schema and output of every surface for a budget, limit, or free slot field. |
| SIM-031 | AIStats MUST NOT create, change, or delete a Claim. | Record modification times of the Simulator Manager data before and after 20 calls. Verify no change. |
| SIM-032 | AIStats MUST NOT boot, shut down, erase, create, or delete a simulator device. | Inspect the subprocess calls of the tool with a test hook. Verify zero subprocess calls, because ADR 0012 uses no identity source. |
| SIM-033 | AIStats MUST NOT install, launch, or terminate an app in a simulator device. | Same check as SIM-032. |

### Other surfaces

| ID | Requirement | Acceptance check |
| --- | --- | --- |
| SIM-040 | `aistats sims --json` MUST print the JSON object of `get_simulator_usage`. | Run the command and the stdio probe. Compare the field sets. |
| SIM-041 | `diagnose_system` with `purpose: "heavy_work"` MAY add the combined simulator CPU as evidence. | Not applicable. |
| SIM-042 | The app MAY show one row per booted device with CPU and memory. | Not applicable. |
| SIM-043 | An app simulator section MUST NOT show a Boot Budget or Claim state. | Inspect the section with two booted devices. |

## Non-goals

- Simulator boot budgets, claims, and device lifecycle actions. A Simulator Manager owns them.
- Simulator disk use and device data sizes. Simulator disk use is covered by [SDD 0014](0014-dev-storage-breakdown.md).
- Physical devices.
- Android emulators.
- History of simulator use over time.
- Attribution of Xcode build services or SourceKit services.

## Dependencies and related specs

- [SDD 0009](0009-agent-sessions-mcp.md): Session names and Agent Identity for `owner`.
- [SDD 0013](0013-orphan-report.md): Lineage Records as one possible owner source. ADR 0012 rejects this source for v1.
- [SDD 0017](0017-process-origin.md): the `ProcessTree` aggregation and partial totals that this report reuses.
- [SDD 0003](0003-top-process-identity.md): the `startToken` field name.
- [SDD 0005](0005-response-size-budget.md): the response byte budget.
- [SDD 0008](0008-cli-parity.md): CLI `--json` and exit code conventions.
- [SDD 0014](0014-dev-storage-breakdown.md): simulator storage.

## Open questions

- That every booted device has exactly one `launchd_sim` process is observed on one Mac only. watchOS, tvOS, visionOS, and Xcode Previews devices are not checked.
- Whether all Device Processes are readable with `proc_pid_rusage` without root is inferred from the user column, not measured. SIM-017 reports the unreadable ones.
- The SIM-016 limit of 1.5 s is a proposal, not a measured limit. No recorded measurement of `get_simulator_usage` exists yet. ADR 0012 gives the release check, the record it keeps and the fallback.
- The latency of `xcrun simctl list devices booted` is not measured. ADR 0012 defers this source.
- How much shared memory the sum of footprints counts more than once is not measured. SIM-007 requires a statement of this limit.

## Decided by ADR 0012

- No identity is derived from executable paths.
- No Simulator Manager Claims are read.
- No `hostServices` aggregate is emitted in v1.
