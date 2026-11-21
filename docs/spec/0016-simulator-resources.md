# SDD 0016 · Simulator Resources

Status · Proposed
Issue · [#15](https://github.com/oozoofrog/aistats/issues/15)
Proposed decision · [ADR 0012 · Account for visible simulator process trees without an owner registry](../adr/0012-simulator-accounting.md)

## Purpose and scope

An ADR MUST be accepted before implementation of this specification. That ADR must make these decisions:

1. The source of device identity (UDID, device name, runtime): a `simctl` subprocess, CoreSimulator device files, or none. The ADR must state the latency and the Xcode dependency of the source.
2. The processes that count toward one device: the Descendants of its Device Root only, or also per-device host-side processes.
3. The source of owner attribution: none, Lineage Records of [SDD 0013](0013-orphan-report.md), or a read-only view of Claims that a Simulator Manager keeps.
4. The device sets in scope, for example the default set and the Xcode Previews set.
5. The surfaces: an MCP tool, a CLI command, a `diagnose_system` evidence line, and an app section.

This specification adds a read-only report of CPU and memory use for each booted simulator device. An agent can then see whether simulators cause the load before it starts a build or a test. Where an ADR source permits, the report names the Session that owns a device.

AIStats MUST NOT duplicate the Boot Budget or the Claims of a Simulator Manager. SIM-030 to SIM-033 give the checks. AIStats reports use; it does not manage devices.

The key words "MUST", "MUST NOT", "SHOULD", "SHOULD NOT", and "MAY" in this document are to be interpreted as described in BCP 14 [RFC2119] [RFC8174] when, and only when, they appear in all capitals.

[RFC2119]: https://www.rfc-editor.org/rfc/rfc2119.html
[RFC8174]: https://www.rfc-editor.org/rfc/rfc8174.html

## Terms

| Term | Meaning |
| --- | --- |
| Device Root | A current-user `launchd_sim` process. One Device Root represents one booted simulator device. |
| Device Process | The Device Root or a process whose Ancestor Walk reaches it. |
| Ancestor Walk | The sequence of parent links from a process up to pid 1. |
| Host Service | A simulator support process outside every Device Root, for example `CoreSimulatorService`, `SimLaunchHost`, or `simdiskimaged`. |
| Start Token | The decimal `ri_proc_start_abstime` value that `find_processes` returns as `startToken`. |
| Session | One running `aistats mcp` server process and its presence record. See [SDD 0009](0009-agent-sessions-mcp.md). |
| Owner | The Session that started or claimed a device, from the ADR source. |
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
| No source file mentions simulators. | Text search of `Sources/` for `simulator`, `launchd_sim`, and `CoreSimulator`. |
| The Agent Identity of a Session is specified in SDD 0009, not implemented. | [SDD 0009](0009-agent-sessions-mcp.md) |
| Process arguments can hold secrets and are never returned. | [Proc.swift:80](../../Sources/StatsCore/Proc.swift#L80) |

Live observations on one development Mac with two booted devices (`ps`, not repeated):

- Each booted device had one `launchd_sim` process. Both were owned by the current user and had ppid 1.
- The two Device Roots had 175 and 317 direct children.
- `CoreSimulatorService`, `SimulatorTrampoline`, and `SimLaunchHost` ran under launchd as the current user. `simdiskimaged` ran as root.
- An installed app inside a device had an executable path that contained the device UDID. Runtime system processes had paths inside the runtime image, without a UDID.
- Simulators started by an agent ran under launchd. A parent link cannot connect them to the agent.

## Requirements

### Report contract

| ID | Requirement | Acceptance check |
| --- | --- | --- |
| SIM-001 | `tools/list` MUST include `get_simulator_usage` with `readOnlyHint: true` and `openWorldHint: false`. | Stdio probe: send `tools/list`. Inspect the tool entry. |
| SIM-002 | The result MUST contain `observedAt`, `bootedCount`, `devices`, and `truncated`. | Stdio probe with zero and with one booted device. Validate the field set. |
| SIM-003 | The tool MUST return one `devices` row for each Device Root. | Boot one device. Compare `bootedCount` with the count of current-user `launchd_sim` processes. |
| SIM-004 | Each `devices` row MUST contain `rootPid`, `startToken`, `bootedAt`, `processCount`, `cpuPercent`, and `memoryBytes`. | Validate one row. Compare `rootPid` and `startToken` with `find_processes` for name `launchd_sim`. |
| SIM-005 | `cpuPercent` MUST be the sum over all Device Processes of one device in one 1.0 s measurement. | Run a CPU-bound app in one device. Compare the value with the sum of `get_top_processes` rows for its Device Processes. |
| SIM-006 | `cpuPercent` MUST use the `get_top_processes` scale, where 100 is one core. | Unit test with fixture process times. |
| SIM-007 | `memoryBytes` MUST be the sum of the physical footprints of all Device Processes of one device. | Unit test with fixture footprints. Inspect the field description in `tools/list` for "sum of footprints". |
| SIM-008 | A `devices` row MUST omit `udid`, `name`, and `runtime` when the ADR source does not give them. | Run with the ADR source disabled. Verify that the three fields are absent, not empty. |
| SIM-009 | A `devices` row MUST contain `top`, at most three Device Processes by CPU with `pid`, `name`, `cpuPercent`, and `memoryBytes`. | Validate `top` for a device with a CPU-bound app. |
| SIM-010 | The tool MUST NOT count a Host Service toward any device. | Fixture table with `CoreSimulatorService` and one Device Root. Verify that the device totals exclude the service. |
| SIM-011 | The result MAY contain `hostServices` with one combined `cpuPercent` and `memoryBytes`. | Not applicable. |
| SIM-012 | With no booted device, the tool MUST return `bootedCount: 0`, an empty `devices`, and `isError: false`. | Shut down all devices that this check booted. Run the stdio probe. |
| SIM-013 | Without Xcode, the tool MUST return a non-error result with the devices it finds. | Run with `DEVELOPER_DIR` set to an empty directory. Verify a non-error result. |
| SIM-014 | `structuredContent` MUST fit the response budget of [SDD 0005](0005-response-size-budget.md). | Fixture with four Device Roots and 300 processes each. Measure the bytes. |
| SIM-015 | The tool MUST NOT return arguments, environment values, or executable paths of Device Processes. | Search the response line for a marker argument of an app in the device and for the string `/Users/`. |
| SIM-016 | The tool MUST complete within 1.5 s when the ADR identity source is cached or disabled. | Time 10 calls with two booted devices. |

### Owner attribution

| ID | Requirement | Acceptance check |
| --- | --- | --- |
| SIM-020 | A `devices` row MUST omit `owner` when the ADR source gives no Session name. | Run with the ADR source disabled. Verify that `owner` is absent. |
| SIM-021 | A `devices` row without `owner` MUST contain `ownerUnknown` with one value from Table 1. | Fixture tests for each value. |
| SIM-022 | The tool MUST NOT infer an Owner from process names, start times, or the parent of a Device Root. | Boot a device from a test agent. Disable the ADR source. Verify `ownerUnknown: "no_source"`. |

#### Table 1 · Unknown owner reasons

| Value | Condition |
| --- | --- |
| `no_source` | No ADR owner source is enabled or available. |
| `not_recorded` | The ADR source has no record for this device. |
| `ended` | The recorded Owner Session has ended. |

### Separation from a Simulator Manager

| ID | Requirement | Acceptance check |
| --- | --- | --- |
| SIM-030 | AIStats MUST NOT compute, report, or enforce a Boot Budget. | Inspect the schema and output of every surface for a budget, limit, or free slot field. |
| SIM-031 | AIStats MUST NOT create, change, or delete a Claim. | Record modification times of the Simulator Manager data before and after 20 calls. Verify no change. |
| SIM-032 | AIStats MUST NOT boot, shut down, erase, create, or delete a simulator device. | Inspect the subprocess calls of the tool with a test hook. Allow only the ADR read-only identity source. |
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
- Simulator disk use and device data sizes. [SDD 0014](0014-dev-storage-breakdown.md) covers storage.
- Physical devices.
- Android emulators.
- History of simulator use over time.
- Attribution of Xcode build services or SourceKit services.

## Dependencies and related specs

- [SDD 0009](0009-agent-sessions-mcp.md): Session names and Agent Identity for `owner`.
- [SDD 0013](0013-orphan-report.md): Lineage Records as one possible owner source.
- [SDD 0003](0003-top-process-identity.md): the `startToken` field name.
- [SDD 0005](0005-response-size-budget.md): the response byte budget.
- [SDD 0008](0008-cli-parity.md): CLI `--json` and exit code conventions.
- [SDD 0014](0014-dev-storage-breakdown.md): simulator storage.

## Open questions

- That every booted device has exactly one `launchd_sim` process is observed on one Mac only. watchOS, tvOS, visionOS, and Xcode Previews devices are not checked.
- Whether all Device Processes are readable with `proc_pid_rusage` without root is inferred from the user column, not measured.
- The cost of one 1.0 s measurement over several hundred Device Processes is not measured. The SIM-016 limit of 1.5 s is a proposal.
- The latency of `xcrun simctl list devices booted` is not measured.
- A UDID appears in executable paths of installed apps. Deriving it from a path discloses no path, but the ADR must accept this source explicitly.
- Physical footprints of Device Processes can include shared memory. Whether the sum overstates device memory is not measured.
- A read-only view of Simulator Manager Claims couples AIStats to the data format of a separate tool. The ADR must decide whether the coupling is acceptable.
