# SDD 0006 · Wait-for Conditions

Status · Proposed
Issue · [#5](https://github.com/oozoofrog/aistats/issues/5)

## Purpose and scope

This specification changes the `wait_for` MCP tool of the `aistats` server. It has four parts:

1. `memory_pressure_normal` takes its first observation at the start of the wait.
2. Each condition has a stated minimum timeout. The server rejects a shorter timeout.
3. A new condition, `process_started`, waits until a matching process runs.
4. A new condition, `disk_free_above`, waits until a volume has enough free space.

The `port_listening` condition is specified in [SDD 0002](0002-port-lookup.md). This specification gives the general wait rules that `port_listening` also follows. The `process_exit` condition does not change. The CLI `wait` command is specified in [SDD 0008](0008-cli-parity.md).

The key words "MUST", "MUST NOT", "SHOULD", "SHOULD NOT", and "MAY" in this document are to be interpreted as described in BCP 14 [RFC2119] [RFC8174] when, and only when, they appear in all capitals.

[RFC2119]: https://www.rfc-editor.org/rfc/rfc2119.html
[RFC8174]: https://www.rfc-editor.org/rfc/rfc8174.html

Requirements use the ASD-STE100 sentence rules and the Terms below. Each active ID identifies one requirement sentence. A Withdrawn ID remains reserved. Tables named by a requirement give the acceptance data for that requirement. [ASD-STE100 Issue 9](https://www.asd-ste100.org/assets/files/ASD-STE100_ISSUE9.pdf)

## Terms

| Term | Meaning |
| --- | --- |
| Wait | One `wait_for` call, from argument validation to its result. |
| Condition | The value of the `condition` argument, for example `cpu_idle`. |
| Observation | One reading of the Condition inputs. The latest valid one is `lastObservation` in the result. |
| Start Observation | An Observation taken at the start of the Wait, before the first timer tick. |
| Tick | One periodic Observation after the start of the Wait. |
| Required Run | The number of consecutive valid, satisfied Observations that makes the result `met`. |
| Earliest Met Time | The shortest elapsed time at which a Condition can return `met`. |
| Condition Minimum | The lowest `timeoutSeconds` that the server accepts for a Condition. See Table A. |
| Instance | One process, identified by pid and `startToken`. |
| Matching Process | A current-user process that the process selector of the Wait matches. |
| Current-user Process | A process whose effective user ID is the user ID of the `aistats` process. |
| GiB | 2^30 bytes. |

## Background and evidence

Current conditions and limits:

- The server accepts three Conditions: `cpu_idle`, `process_exit`, and `memory_pressure_normal` ([Waiter.swift:11-13](../../Sources/StatsCore/Waiter.swift#L11-L13), [MCPServer.swift:400](../../Sources/StatsCore/MCPServer.swift#L400)).
- `timeoutSeconds` must be 1 to 55 for every Condition ([Waiter.swift:71](../../Sources/StatsCore/Waiter.swift#L71), [MCPServer.swift:566](../../Sources/StatsCore/MCPServer.swift#L566), [MCPServer.swift:403](../../Sources/StatsCore/MCPServer.swift#L403)).
- `cpu_idle` and `memory_pressure_normal` need two consecutive satisfied Observations ([Waiter.swift:72](../../Sources/StatsCore/Waiter.swift#L72), [Waiter.swift:216-217](../../Sources/StatsCore/Waiter.swift#L216-L217)).
- The Tick period is 1 s, or 250 ms for `process_exit` ([Waiter.swift:127](../../Sources/StatsCore/Waiter.swift#L127)). The first Tick fires one period after the start, with up to 50 ms leeway ([Waiter.swift:129](../../Sources/StatsCore/Waiter.swift#L129)).
- `memory_pressure_normal` reads nothing at the start ([Waiter.swift:183-184](../../Sources/StatsCore/Waiter.swift#L183-L184)). Its first Observation is the first Tick ([Waiter.swift:249-251](../../Sources/StatsCore/Waiter.swift#L249-L251)).
- A Tick that finishes after the deadline counts as a timeout ([Waiter.swift:212-213](../../Sources/StatsCore/Waiter.swift#L212-L213)). This rule is correct and stays.
- The `wait_for` description does not state a per-Condition minimum timeout ([MCPServer.swift:396](../../Sources/StatsCore/MCPServer.swift#L396)).

Observed defects (built binary v0.3.0, one machine, memory pressure normal during the test):

- `memory_pressure_normal` with `timeoutSeconds` 2 returned `timed_out`.
- `memory_pressure_normal` with `timeoutSeconds` 2.5 returned `met` after 2.0 s.

Source analysis of `cpu_idle`:

- A CPU rate needs two counter readings. The Wait primes the counters at the start ([Waiter.swift:188](../../Sources/StatsCore/Waiter.swift#L188), [Waiter.swift:203](../../Sources/StatsCore/Waiter.swift#L203)).
- The two required Observations arrive at about 1 s and 2 s. A `cpu_idle` Wait with `timeoutSeconds` below about 2.05 s cannot return `met`. The server accepts such a Wait now.

`process_exit` is not defective:

- It checks the pid at the start and reports `unavailable` when the Instance is not visible ([Waiter.swift:175-182](../../Sources/StatsCore/Waiter.swift#L175-L182)).
- It needs one Observation at 250 ms Ticks ([Waiter.swift:217](../../Sources/StatsCore/Waiter.swift#L217)).

Gaps that the new Conditions fill:

- No Condition waits for a process to appear. A `cpu_idle` selector Wait reports `unavailable` when nothing matched ([Waiter.swift:227-231](../../Sources/StatsCore/Waiter.swift#L227-L231)). The selector parser and process directory already exist ([Proc.swift:317-346](../../Sources/StatsCore/Proc.swift#L317-L346), [Proc.swift:250](../../Sources/StatsCore/Proc.swift#L250), [Proc.swift:281](../../Sources/StatsCore/Proc.swift#L281)).
- The `cpu_idle` selector rescans at most every 5 s ([ProcessTracker.swift:529](../../Sources/StatsCore/ProcessTracker.swift#L529), [Waiter.swift:300](../../Sources/StatsCore/Waiter.swift#L300)). That interval is too slow to detect a process start.
- No Condition waits for free disk space. The sampler reads `availableBytes` and `availableForImportantUsageBytes` with `statfs` and a volume resource query ([SystemSampler.swift:197-210](../../Sources/StatsCore/SystemSampler.swift#L197-L210), [Snapshot.swift:67-74](../../Sources/StatsCore/Snapshot.swift#L67-L74)). The default volume is `/` ([SystemSampler.swift:42](../../Sources/StatsCore/SystemSampler.swift#L42)).
- `diagnose_system` reports low disk below 10 GiB ([Diagnosis.swift:29](../../Sources/StatsCore/Diagnosis.swift#L29)). An agent has no way to wait for a cleanup to finish.

Existing tests: [MCPAndRegistrationTests.swift:180-191](../../Tests/StatsCoreTests/MCPAndRegistrationTests.swift#L180-L191) checks `wait_for` validation errors.

## Requirements

### General wait rules

| ID | Requirement | Acceptance check |
| --- | --- | --- |
| WAI-001 | When the Condition holds for the whole Wait and `timeoutSeconds` is at least the Condition Minimum, the result MUST be `met`. | For each Condition in Table A, run a unit test with an injected Observation source that is always satisfied. Use `timeoutSeconds` equal to the Condition Minimum. Expect `state` `met` in 20 of 20 runs. |
| WAI-002 | The server MUST use the Condition Minimum values in Table A. | Unit test the validation function with each Condition at its minimum and at the minimum minus 0.1 s. Expect acceptance at the minimum and a tool error below it. |
| WAI-003 | The server MUST return a tool error when `timeoutSeconds` is below the Condition Minimum. | Stdio probe: `{"condition":"cpu_idle","timeoutSeconds":2}` and `{"condition":"memory_pressure_normal","timeoutSeconds":1}`. Expect `isError` true for both. |
| WAI-004 | The error text MUST name the Condition and its minimum in seconds. | In the WAI-003 probes, expect the text to contain `cpu_idle` and `2.5`, and `memory_pressure_normal` and `1.5`. |
| WAI-005 | Every entry point that runs a Wait MUST apply the same Condition Minimums. | Call the shared validation from the MCP handler and from the CLI `wait` command of SDD 0008. Run the WAI-003 cases through both. |
| WAI-006 | A Tick that finishes after the deadline MUST NOT count as satisfied. | Keep the existing behavior of [Waiter.swift:212-213](../../Sources/StatsCore/Waiter.swift#L212-L213). Unit test with a Tick period longer than the timeout. Expect `timed_out`. |
| WAI-007 | The `condition` enum MUST list `cpu_idle`, `process_exit`, `memory_pressure_normal`, `process_started`, `disk_free_above`, and `port_listening`. | Read `tools/list`. Compare the `wait_for` `condition` enum with this list. |
| WAI-008 | The server MUST reject an argument without a schema default that the chosen Condition does not use. | Stdio probes: `aboveGiB` with `cpu_idle`, `name` with `disk_free_above`, `trackId` with `process_started`. Expect `isError` true. Arguments with a schema default, such as `belowPercent` and `match`, are exempt; see Open questions. |
| WAI-009 | The `wait_for` description SHOULD state the Condition Minimums of `cpu_idle` and `memory_pressure_normal`. | Read the description in `tools/list`. |
| WAI-010 | The growth of the compact `tools/list` response from this specification SHOULD stay at or below 600 bytes. | Measure the compact `tools/list` result before and after the change. The 600-byte value is a budget, not a measurement. |

#### Table A · Condition Minimums

The Condition Minimum is the Earliest Met Time plus a 0.5 s margin, rounded up to a multiple of 0.5 s, and not less than 1.0 s. The margin covers timer leeway and Observation cost.

| Condition | Required Run | Start Observation | Tick period | Earliest Met Time | Condition Minimum |
| --- | --- | --- | --- | --- | --- |
| `process_exit` | 1 | Pid check only (unchanged) | 250 ms | 0.25 s | 1.0 s |
| `memory_pressure_normal` | 2 | Yes | 1 s | 1.0 s | 1.5 s |
| `cpu_idle` | 2 | No (a rate needs an interval) | 1 s | 2.0 s | 2.5 s |
| `process_started` | 1 | Yes | 500 ms or less | 0 s | 1.0 s |
| `disk_free_above` | 1 | Yes | 1 s | 0 s | 1.0 s |
| `port_listening` | 1 | Yes | 500 ms or less | 0 s | 1.0 s (see SDD 0002) |

### memory_pressure_normal

| ID | Requirement | Acceptance check |
| --- | --- | --- |
| WAI-011 | `memory_pressure_normal` MUST take a Start Observation. | Unit test with an injected pressure reader that records call times. Expect the first call before the first Tick. |
| WAI-012 | The Start Observation MUST count toward the Required Run of 2. | Unit test with a reader that always returns `normal`. Expect `met` with `elapsedSeconds` from 0.9 to 1.3. |
| WAI-013 | With pressure normal for the whole Wait, `memory_pressure_normal` MUST return `met` within 1.3 s. | Stdio probe on a Mac with normal pressure: `{"condition":"memory_pressure_normal","timeoutSeconds":1.5}`. Expect `met` and `elapsedSeconds` at or below 1.3. Repeat 10 times. |
| WAI-014 | An `unknown` pressure reading MUST NOT count as satisfied. | Keep [Waiter.swift:251](../../Sources/StatsCore/Waiter.swift#L251). Unit test with a reader that returns `unknown`. Expect no `met`. |

### cpu_idle and process_exit

| ID | Requirement | Acceptance check |
| --- | --- | --- |
| WAI-015 | `cpu_idle` MUST keep a Required Run of two consecutive Observations at 1 s Ticks. | Unit test: an idle injected source returns `met` with `elapsedSeconds` from 1.9 to 2.4. |
| WAI-016 | `process_exit` MUST keep its current start check, 250 ms Tick period, and Required Run of 1. | The existing `process_exit` tests in [MCPAndRegistrationTests.swift](../../Tests/StatsCoreTests/MCPAndRegistrationTests.swift) and `scripts/smoke-mcp.sh` pass without change. |

### process_started

| ID | Requirement | Acceptance check |
| --- | --- | --- |
| WAI-017 | `wait_for` MUST accept the Condition `process_started` with a `name` or `path` selector. | Stdio probe: `{"condition":"process_started","name":"sleep","timeoutSeconds":3}` while a `sleep` child runs. Expect `met`. |
| WAI-018 | `process_started` MUST accept `match` and `argsContain` with the same meaning as in `find_processes`. | Run two `sleep` children with different arguments. Use `argsContain` to select one. Compare the reported pid. |
| WAI-019 | `process_started` MUST reject `pid`, `startToken`, and `trackId`. | Stdio probes with each argument. Expect `isError` true. |
| WAI-020 | `process_started` MUST return `met` when at least one Matching Process runs. | Start the Wait with no match. Spawn a matching child after 1 s. Expect `met` within 1.6 s of the spawn. |
| WAI-021 | By default, a Matching Process that runs at the Start Observation MUST satisfy the Condition. | Spawn the child before the call. Expect `met` with `elapsedSeconds` at or below 0.3. |
| WAI-022 | With `newInstancesOnly` true, only Instances absent from the Start Observation MUST count. | Spawn child A before the call and child B after 1 s. Expect `met` with only B in `processes`. Without B, expect `timed_out`. |
| WAI-023 | `newInstancesOnly` MUST default to false. | Read the schema default. Run the WAI-021 check without the argument. |
| WAI-024 | `process_started` MUST return `met` from a satisfied Start Observation. | Covered by WAI-021. |
| WAI-025 | `process_started` SHOULD observe at least every 500 ms. | Unit test with an injected clock. Count Observations over 5 s. Expect at least 10. |
| WAI-026 | A `met` result MUST list Matching Processes in `processes` with `pid`, `startToken`, `name`, and `ppid`. | Inspect the WAI-020 result. Compare each row with `find_processes` for the same pid. |
| WAI-027 | `processes` MUST hold at most 5 rows. | Spawn 8 matching children. Expect 5 rows. |
| WAI-028 | A `met` result MUST include `matched`, the number of Matching Processes in the satisfying Observation. | In the WAI-027 check, expect `matched` 8. |
| WAI-029 | With `argsContain`, the result MUST include `argsUnreadable`, as for `cpu_idle`. | Follow [Waiter.swift:370](../../Sources/StatsCore/Waiter.swift#L370). Stdio probe with `argsContain`. Expect an integer `argsUnreadable`. |
| WAI-030 | The `wait_for` description SHOULD say that a process shorter than one Tick can be missed. | Read the description in `tools/list`. Expect a sentence about processes shorter than one Tick. The sentence can point to `track_processes` with `includeChildren`. |
| WAI-031 | A `process_started` result MUST fit in 4,096 bytes as a whole JSON-RPC line. | Spawn 8 matching children with an `argsContain` filter. Measure the whole response line in bytes. |

### disk_free_above

| ID | Requirement | Acceptance check |
| --- | --- | --- |
| WAI-032 | `wait_for` MUST accept the Condition `disk_free_above` with a required number `aboveGiB` greater than 0. | Stdio probes: `aboveGiB` missing, 0, and -1. Expect `isError` true. `aboveGiB` 1 returns a result. |
| WAI-033 | `disk_free_above` MUST accept an optional absolute `volumePath` with the default `/`. | Stdio probe without `volumePath`. Expect `mountPath` `/`. A relative `volumePath` gives `isError` true. |
| WAI-034 | The Condition MUST compare `availableBytes` with `aboveGiB` × 2^30. | Unit test with an injected disk reader at the threshold minus 1, the threshold, and plus 1. Expect not satisfied, satisfied, satisfied. |
| WAI-035 | `availableBytes` MUST have the same meaning as `disk.availableBytes` in `get_system_stats`. | Call both on the same volume within 1 s. Expect values within 1 GiB on an idle disk. |
| WAI-036 | `disk_free_above` MUST return `met` from a satisfied Start Observation. | Use `aboveGiB` 0.001. Expect `met` with `elapsedSeconds` at or below 0.3. |
| WAI-037 | When the volume cannot be read at the start, the result MUST be `unavailable` with a `reason`. | Stdio probe with `volumePath` `/nonexistent-aistats`. Expect `state` `unavailable` and a non-empty `reason`. |
| WAI-038 | Each Observation MUST include `diskAvailableBytes`. | Inspect `lastObservation` of a `timed_out` result. Use `aboveGiB` larger than the volume. |
| WAI-039 | Each Observation SHOULD include `diskAvailableForImportantUsageBytes` when it is readable. | Inspect the WAI-038 result on an APFS volume. |
| WAI-040 | A `disk_free_above` result MUST include `mountPath` and `thresholdBytes`. | Inspect the WAI-038 result. Expect `thresholdBytes` equal to `aboveGiB` × 2^30. |

## Non-goals

- Changes to the `process_exit` Condition.
- A change to the 55 s maximum timeout.
- A Start Observation for `cpu_idle`. A CPU rate needs an interval.
- The details of `port_listening`. [SDD 0002](0002-port-lookup.md) owns them.
- Conditions for files, log lines, network idle, or thermal state.
- `process_started` for processes of other users.
- Progress notifications during a Wait.

## Dependencies and related specs

- [SDD 0002 · Port Lookup](0002-port-lookup.md) adds `port_listening`. It follows WAI-001 to WAI-008 and uses the `processes` and `matched` fields of WAI-026 to WAI-028.
- [SDD 0003 · Top Process Identity](0003-top-process-identity.md) defines `startToken` and `ppid` for process rows. The rows in WAI-026 use the same fields.
- [SDD 0005 · Response Size Budget](0005-response-size-budget.md) sets the general byte budget for tool results. WAI-031 applies that budget to `process_started` now.
- [SDD 0008 · CLI Parity](0008-cli-parity.md) adds the CLI `wait` command. WAI-005 applies to it.
- [SDD 0011 · Instructions Priority](0011-instructions-priority.md) controls the server instructions. The `wait_for` line at [MCPServer.swift:295](../../Sources/StatsCore/MCPServer.swift#L295) lists the Conditions. Name the new Conditions only within the 0011 size cap.
- [SDD 0012 · Schema Deduplication](0012-schema-dedup.md) limits description growth. WAI-010 is the budget for this specification.

## Open questions

- Rejection or clamping: this specification rejects a short timeout (WAI-003). Clamping up to the Condition Minimum saves one round trip but silently changes the requested timeout. Maintainers can choose clamping if they also report the effective `timeoutSeconds`.
- `belowPercent` with a Condition other than `cpu_idle` is ignored now. Some clients can send schema defaults, such as `belowPercent` and `match`. Rejection could break those clients, so WAI-008 exempts arguments with a schema default. This was not verified with any client.
- Kernel memory pressure can be stable enough that one Observation is sufficient. Then `memory_pressure_normal` could return `met` at the start. No measurement of pressure flapping exists.
- `disk_free_above` compares `availableBytes`, without purgeable space. A Wait for a cleanup can also want the purgeable-inclusive value. Not decided.
- `statfs` latency on network or external volumes was not measured.
- The CPU cost of a 500 ms process scan for `process_started` was not measured. One current-user process table read is one `sysctl` call ([Proc.swift:155-181](../../Sources/StatsCore/Proc.swift#L155-L181)), plus path reads for cache misses.
- Demand for `newInstancesOnly` was not verified. It is in scope because the default behavior cannot detect a restart of an already running process.
- Whether the observed `memory_pressure_normal` defect reproduces on other machines was not verified. The source analysis predicts the same result on every machine.
