# ADR 0012 · Account for visible simulator process trees without an owner registry

Status: Accepted

## Context

[SDD 0016](../spec/0016-simulator-resources.md) requests resource usage per visible device. A launchd_sim process can exist independently of the session that requested the device. On the observed Mac, every launchd_sim process had parent pid 1.

The process tree of [SDD 0017](../spec/0017-process-origin.md) already exists. `ProcessTree.measure` takes one 1.0 s sample of the current-user process table. It adds the own CPU, footprint and process count of each node to every observed ancestor. It stops that summation at agent roots (ORG-017). `TreeMetrics.partial` marks a total that misses an unreadable reading (ORG-018). `get_process_tree`, `aistats tree` and the panel use this code. The panel already lists launchd_sim roots under “출발점 불명 · launchd” (ORG-019).

## Decision drivers

Support systems without a selected Xcode. Observe devices without changing their state. Keep host service memory separate from device totals. Keep one process-tree aggregation in the code base. Take one 1.0 s sample per call.

## Considered options

- Write a separate walker for launchd_sim subtrees. This duplicates the SDD 0017 aggregation, its partial flags and its parent-link checks.
- Add a launchd_sim filter to `get_process_tree`. This needs the least new code. The SDD 0016 fields `bootedCount` and `top` and a separate tool name do not fit the tree contract.
- Run `xcrun simctl list devices booted` and cache the result for 300 s. This gives UDID, name and runtime. It adds an Xcode dependency and a first-call latency that is not measured.
- Parse device files and application paths. This depends on filesystem layout. Runtime system processes have no UDID in their paths, so only some devices are identified.
- Read the Claims of a Simulator Manager. This gives an owner. It couples AIStats to the data format of a separate tool.
- Use the Lineage Records of [SDD 0013](../spec/0013-orphan-report.md). [ADR 0009](0009-orphan-lineage.md) records only observed descendants of live agents. A Device Root runs under launchd with parent pid 1, so no chain from an agent reaches it. This source would report `not_recorded` for every device observed so far.

## Decision

### Measurement

Build the report from one `ProcessTree.measure` call. Do not add a second process-table walker. Do not take a second sample. Treat each current-user launchd_sim node in that tree as a Device Root. Include all visible device sets, including Xcode Previews.

Let the caller of `ProcessTree.measure` ask the initializer to detect Device Roots by name in the table that it reads. Keep the detected Device Roots in a separate set. Only the summation step reads this set. The summation step does not add the own reading of a Device Root or of its descendants to any ancestor of that Device Root. This is the same stop that an agent root gets under ORG-017. Do not add Device Roots to the agent root set. Agent detection, `AgentSessions.walk`, `owner`, `reason`, `children`, `hosts` and `unknown` do not read the Device Root set. A Device Root is therefore never treated as an agent, and tree position gives no owner (SIM-022). `get_process_tree` does not ask for Device Roots, so its set is empty and its output does not change.

Define a nested root as a Device Root whose observed ancestor chain reaches another Device Root. A nested root gets its own row (SIM-018). The outer row excludes the nested root and its Device Processes (SIM-019). A Device Root is never a Device Process of another Device Root. Each process counts toward at most one row.

Take each row value from the subtree total of its Device Root. `cpuPercent` uses the one-core scale of `get_top_processes`. `memoryBytes` is the sum of physical footprints. `processCount` is the subtree count. Copy `TreeMetrics.partial` for `cpu` and `memory` into the row, so that an unreadable reading is not reported as zero.

`TreeMetrics` leaves `cpuPercent` or `memoryBytes` nil when no reading of that metric in the subtree is readable. In that case, omit the field from the row and list the metric in `partial` (SIM-050). Do not write `0` or `null`. `get_process_tree` already omits a nil metric in the same way. This amendment adds an exception to SIM-004 on purpose. SIM-004 stays MUST for every other case.

A Device Root can have no verified sample row, for example when it starts after the sample and before the table read. Read its start token once more with `proc_pid_rusage` after the table read. Accept that token only when the kernel start time still matches the table entry. When the direct read gives no token, omit `startToken` from the row (SIM-051). Do not write an empty string or `0`. This is the second exception to SIM-004.

Rank `top` only by Device Processes with a readable CPU reading, so that each member has all four SIM-009 fields. Round the row `cpuPercent` to one decimal, as the per-process readings are, so that the summation order does not change the output (RSZ-011). To fit the Payload Budget, remove `top` members before `devices` rows and count them in `topOmitted`. Each Device Root then keeps its row and its totals (RSZ-008).

Keep the sum of footprints. Footprints can count shared memory more than once, so the sum can exceed the memory the device uses. State this limit in the `memoryBytes` field description in `tools/list`.

Exclude host services. Observed host services run as separate launchd children or as root, so they are outside every Device Root subtree. Do not emit `hostServices` in v1. AIStats can identify a host service only by its name, and the root-owned `simdiskimaged` is not readable from the current-user table. This amendment changes SIM-011 from MAY to MUST NOT for v1 on purpose.

### Identity and owner

Use no device identity source and no claim registry in v1. Omit UDID, name, runtime and owner. Set `ownerUnknown` to `no_source`. This adds zero subprocess latency and requires no Xcode installation. Do not derive identity from executable paths. Do not start a subprocess.

### Latency

Keep the SIM-016 budget of 1.5 s. The budget is a proposal, not a measured limit. It allows the fixed 1.0 s sample plus 0.5 s for the table read, the tree build and the JSON response. `get_simulator_usage` reuses the sample and the tree build of `aistats tree`.

An earlier spot check timed a Debug `aistats tree` build on one development Mac. That Mac had two booted devices and about 1,000 current-user processes. All observed wall-clock times were in the range 1.09 s to 1.37 s. The command line, the date and the raw output of that check were not recorded. This ADR therefore does not use it as evidence. The release check below supplies the evidence. The direct child counts in the SDD 0016 observations come from separate `ps` runs, so they differ from each other.

Verify SIM-016 before each release with the release build configuration. Use two booted devices when they are available for authorized testing. Otherwise use the Synthetic Device Root procedure of SDD 0016. That procedure starts one current-user `launchd_sim` process with 500 children and fills the current-user table to at least 1,000 processes. This matches the table size of the spot check. Record these conditions with the ten times in the release pull request: the date, the macOS version, the build configuration, the number of Device Roots, their direct child counts and the current-user process count. If a check exceeds 1.5 s, remove work outside the sample from the shared tree build first. An example is a full-name lookup for a process that no report returns. If the check still fails, amend SIM-016 through a new ADR with the measured value before release. Do not shorten the 1.0 s sample, because SIM-005 and `get_top_processes` depend on it.

### Surfaces

Expose `get_simulator_usage` and `aistats sims --json`. Defer a panel section and heavy-work diagnosis changes.

### Specification amendments

This decision amends SDD 0016 as follows:

- Replace the stale evidence row about simulator mentions with the current ProcessTree evidence.
- Define Device Process with the nested-root and agent-root boundaries. A Device Root other than R is never a Device Process of R.
- Add the Synthetic Device Root term and its procedure.
- Change the purpose text: v1 names no Session, and every row reports `ownerUnknown: "no_source"`.
- Add an exception to SIM-004 for a metric with no readable reading. Add SIM-050 for the omission. The keyword strength of SIM-004 stays MUST.
- Change SIM-011 from MAY to MUST NOT for v1. Its check uses a fixture table and the Synthetic Device Root, so it needs no booted device.
- Extend the SIM-007 check with the shared-memory statement.
- Remove the identity source condition from SIM-016, because v1 has no identity source. Extend its check with the release build, the Synthetic Device Root procedure and the recorded conditions. The keyword strength stays MUST.
- Change the SIM-008, SIM-020 and SIM-022 checks so that they use the Synthetic Device Root instead of a disabled source.
- Limit the SIM-021 check to `no_source`. Reserve `not_recorded` and `ended` for a later owner source.
- Change the SIM-032 check to zero subprocess calls.
- Add SIM-017 for partial totals.
- Add SIM-018 for the own row of a nested root and SIM-019 for its exclusion from the outer row.
- Add SIM-051 for a Device Root whose start time is unreadable. Change SIM-004 to refer to SIM-050 and SIM-051.
- Exclude a Device Process without a readable CPU reading from `top` in SIM-009.
- Extend SIM-014 with the Trimming order and a check with 255-byte names.

## Consequences

Users identify devices by root PID, start token and boot time. The report cannot name the owning session.

Rows have no UDID. AIStats cannot match a row to the UDID-keyed Claims of a Simulator Manager or to `simctl` output. An agent that must know which row is its own device must correlate the row itself, for example by boot time. The Simulator Manager remains the source for the session that uses each UDID. A later ADR can add a cached `simctl` identity source.

A change to the ProcessTree aggregation changes both the tree and the simulator report. Run the ORG-017 and ORG-018 tests together with the SIM-005, SIM-007, SIM-017, SIM-018, SIM-019 and SIM-050 tests.

The report writes no file and needs no cleanup. Simulator disk use is covered by [SDD 0014](../spec/0014-dev-storage-breakdown.md).

Verify the empty case, multiple synthetic roots, a nested root, exclusion of host services, partial metrics, a metric with no readable reading, a Device Root without a sample row, the no-Xcode case and the latency check above.
