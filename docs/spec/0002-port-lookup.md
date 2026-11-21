# SDD 0002 · Port Lookup

Status · Proposed
Issue · [#1](https://github.com/oozoofrog/aistats/issues/1)

## Purpose and scope

This specification adds TCP port lookup to the `aistats` MCP server. It has two parts:

1. A `port` selector for `find_processes`. It returns the current-user processes that listen on a TCP port.
2. A `port_listening` Condition for `wait_for`. It waits until a current-user process listens on a TCP port.

An agent uses these tools in place of `lsof -iTCP:<port> -sTCP:LISTEN` and sleep loops. A typical case is a development server that does not start because the port is in use.

`aistats` reads only current-user processes. Thus "no listener found" does not mean "port free". This specification makes that difference explicit in the result. An optional bind probe can tell a free port from a port in use by an invisible socket.

The specification covers TCP listening sockets on IPv4 and IPv6. UDP is out of scope. The CLI form of the selector is specified in [SDD 0008](0008-cli-parity.md).

The key words "MUST", "MUST NOT", "SHOULD", "SHOULD NOT", and "MAY" in this document are to be interpreted as described in BCP 14 [RFC2119] [RFC8174] when, and only when, they appear in all capitals.

[RFC2119]: https://www.rfc-editor.org/rfc/rfc2119.html
[RFC8174]: https://www.rfc-editor.org/rfc/rfc8174.html

Requirements use the ASD-STE100 sentence rules and the Terms below. Each active ID identifies one requirement sentence. A Withdrawn ID remains reserved. Tables named by a requirement give the acceptance data for that requirement. [ASD-STE100 Issue 9](https://www.asd-ste100.org/assets/files/ASD-STE100_ISSUE9.pdf)

## Terms

| Term | Meaning |
| --- | --- |
| Current-user Process | A process whose effective user ID is the user ID of the `aistats` process. |
| Listening Socket | A TCP socket in the `LISTEN` state. |
| Listener | A Current-user Process that holds a Listening Socket with the requested local port. |
| Port Scan | One read of the open sockets of all Current-user Processes. |
| Port State | The `portState` result field. Table B gives its values. |
| Bind Probe | A test that binds a new TCP socket to the requested port and closes it. It never listens. |
| Wait | One `wait_for` call, as defined in [SDD 0006](0006-wait-for-conditions.md). |
| Condition | The value of the `wait_for` `condition` argument. |
| Observation | One reading of the Condition inputs, as defined in SDD 0006. |
| Start Observation | An Observation taken at the start of the Wait, before the first timer tick. |
| Condition Minimum | The lowest `timeoutSeconds` that the server accepts for a Condition. See Table A of SDD 0006. |

## Background and evidence

Current behavior:

- No `aistats` tool reads sockets. The server instructions name `lsof` as a command that `aistats` replaces ([MCPServer.swift:290](../../Sources/StatsCore/MCPServer.swift#L290)). No tool answers "which process holds port N".
- A selector needs exactly one of `pid`, `name`, or `path` ([Proc.swift:317-320](../../Sources/StatsCore/Proc.swift#L317-L320)).
- One shared property table holds the selector arguments ([MCPServer.swift:308-316](../../Sources/StatsCore/MCPServer.swift#L308-L316)). `find_processes`, `track_processes`, and `wait_for` merge it into their schemas ([MCPServer.swift:368](../../Sources/StatsCore/MCPServer.swift#L368), [MCPServer.swift:378](../../Sources/StatsCore/MCPServer.swift#L378), [MCPServer.swift:399](../../Sources/StatsCore/MCPServer.swift#L399)).
- A `find_processes` row has `pid`, `startToken`, `name`, `ppid`, `footprintBytes`, `path`, and `unreadable` ([ProcessFinder.swift:6-17](../../Sources/StatsCore/ProcessFinder.swift#L6-L17)). A result holds at most 15 rows ([ProcessFinder.swift:43](../../Sources/StatsCore/ProcessFinder.swift#L43)).
- The handler drops rows until the response fits 4,096 bytes ([MCPServer.swift:466-476](../../Sources/StatsCore/MCPServer.swift#L466-L476), [MCPServer.swift:14](../../Sources/StatsCore/MCPServer.swift#L14)).
- One `sysctl` call lists the Current-user Processes with their ppid ([Proc.swift:155-181](../../Sources/StatsCore/Proc.swift#L155-L181)).
- `wait_for` has no port Condition ([MCPServer.swift:400](../../Sources/StatsCore/MCPServer.swift#L400)).
- The bundle signs `aistats` ad hoc, without entitlements ([bundle.sh:32-33](../../scripts/bundle.sh#L32-L33)). `aistats` does not run in the App Sandbox.

Probe results (a standalone libproc probe on one Mac, without root):

- `proc_pidinfo` with `PROC_PIDLISTFDS`, then `proc_pidfdinfo` with `PROC_PIDFDSOCKETINFO`, reads each socket. A socket with kind `SOCKINFO_TCP` and TCP state `TSI_S_LISTEN` is a Listening Socket. The local port is the network-order `insi_lport` value.
- A Port Scan of 967 Current-user Processes took 3.4 ms to 5.2 ms. The results matched `lsof`.
- The probe read the sockets of sandboxed processes of the same user.
- The probe got `EPERM` for processes of other users. Thus a listener of another user is invisible.
- Inference, not tested: a `bind()` or `connect()` test can tell an invisible socket from a free port.
- UDP sockets and the bound address were not tested.

## Requirements

### Port selector

| ID | Requirement | Acceptance check |
| --- | --- | --- |
| PRT-001 | `find_processes` MUST accept an integer `port` argument from 1 to 65535. | Stdio probes: `port` 0 and 65536 give `isError` true. `port` 8080 gives `isError` false. |
| PRT-002 | The server MUST require exactly one of `pid`, `name`, `path`, and `port`. | Stdio probe: `{"port":8080,"name":"node"}`. Expect `isError` true and a message that names all four arguments. |
| PRT-003 | The server MUST reject `argsContain`, `startToken`, and `match` `glob` with `port`. | Stdio probe with each argument next to `port`. Expect `isError` true. `match` `exact` is accepted, as with `pid`. |
| PRT-004 | With `port`, `find_processes` MUST return each Listener on that port. | Test: a child process listens on an ephemeral loopback port. Expect its pid in `processes`. Compare the pid set with `lsof -nP -iTCP:<port> -sTCP:LISTEN` for the current user. |
| PRT-005 | The Port Scan MUST find Listening Sockets on IPv4 and on IPv6. | Test with one child that listens on `127.0.0.1` only and one that listens on `::1` only. Expect both pids. |
| PRT-006 | A socket in a state other than `LISTEN` MUST NOT make a process a Listener. | Test: a second child connects to the listening child. Expect only the listening pid. |
| PRT-007 | The result MUST list each Listener pid once. | Test: one child listens on IPv4 and IPv6 on the same port. Expect one row. |
| PRT-008 | Each row MUST use the existing `find_processes` row fields and their rules. | Compare the row with `find_processes` by `pid` for the same process. `path` is absent. |
| PRT-009 | The result MUST report `selector` as `port`. | Inspect the PRT-004 result. |
| PRT-010 | A port result MUST fit in 4,096 bytes as a whole JSON-RPC line. | Fork 20 children that share one Listening Socket. Expect at most 15 rows, `truncated` true, and a line of 4,096 bytes or less. |

### Port State

| ID | Requirement | Acceptance check |
| --- | --- | --- |
| PRT-011 | A port result MUST include `portState` with a value from Table B. | Inspect each port result in the PRT checks. |
| PRT-012 | `portState` MUST be `listening` when the result has at least one Listener. | Inspect the PRT-004 result. |
| PRT-013 | Without a Listener and without a Bind Probe, `portState` MUST be `unknown`. | Stdio probe on an unused port without `probeFree`. Expect `unknown`. |
| PRT-014 | The server MUST NOT report `free` unless a Bind Probe in the same call succeeded. | Unit test with an injected empty Port Scan and no probe. Expect `unknown`. Repeat with a probe that fails with `EADDRINUSE`. Expect `in_use`. |
| PRT-015 | Without a Listener, the `note` MUST say that listeners of other users are invisible. | Inspect the PRT-013 result. |

#### Table B · Port State values

| Value | Condition |
| --- | --- |
| `listening` | At least one Listener was found. |
| `in_use` | No Listener was found. The Bind Probe failed with `EADDRINUSE`. |
| `free` | No Listener was found. The Bind Probe succeeded on every tested address. |
| `unknown` | No Listener was found. The Bind Probe did not run, or it failed with another error. |

### Bind Probe

| ID | Requirement | Acceptance check |
| --- | --- | --- |
| PRT-016 | `find_processes` MUST accept a boolean `probeFree` argument with the default false. | Read the schema. Stdio probe: `probeFree` true without `port` gives `isError` true. |
| PRT-017 | The Bind Probe MUST run only when `probeFree` is true and no Listener was found. | Unit test with a counting probe. Expect zero probe calls when a Listener exists or `probeFree` is false. |
| PRT-018 | The Bind Probe MUST NOT call `listen()`. | Unit test with an injected socket layer. Expect no `listen` call. |
| PRT-019 | The Bind Probe MUST close its sockets before the call returns. | After a `free` result, a test binds the same port at once. Expect success. |
| PRT-020 | The Bind Probe MUST test the IPv4 and the IPv6 wildcard addresses. | Unit test with an injected socket layer. Expect one bind on `0.0.0.0` and one on `::`. |
| PRT-021 | The Bind Probe MUST NOT set `SO_REUSEADDR` or `SO_REUSEPORT`. | Unit test with an injected socket layer. Expect no such option. |
| PRT-022 | When the Bind Probe fails with another error, the `note` MUST name that error. | Unit test with a probe that fails with `EACCES`. Expect `unknown` and `EACCES` in `note`. |
| PRT-023 | The `find_processes` description SHOULD say that a Bind Probe can briefly stop another process from binding the port. | Read the description in `tools/list`. |

### port_listening Condition

| ID | Requirement | Acceptance check |
| --- | --- | --- |
| PRT-024 | `wait_for` MUST accept the Condition `port_listening` with a required `port` argument. | Stdio probe without `port`. Expect `isError` true. |
| PRT-025 | `port_listening` MUST return `met` when it observes at least one Listener. | Start the Wait. After 1 s, start a listening child. Expect `met` within 1.6 s of the listen call. |
| PRT-026 | `port_listening` MUST return `met` from a satisfied Start Observation. | Start a listening child before the call. Expect `met` with `elapsedSeconds` at or below 0.3. |
| PRT-027 | `port_listening` SHOULD observe at least every 500 ms. | Unit test with an injected clock. Count Observations over 5 s. Expect at least 10. |
| PRT-028 | The Condition Minimum of `port_listening` MUST be 1.0 s. | Follow Table A of SDD 0006. A `timeoutSeconds` of 1 is accepted. |
| PRT-029 | `port_listening` MUST NOT run a Bind Probe. | Unit test with a counting probe. Expect zero calls over a full Wait. |
| PRT-030 | A `met` result MUST list the Listeners in `processes` with `pid`, `startToken`, `name`, and `ppid`. | Inspect the PRT-025 result. Compare each row with `find_processes` by `pid`. |
| PRT-031 | A `met` result MUST include `matched`, the number of Listeners. | Inspect the PRT-025 result. |
| PRT-032 | Each Observation MUST include a boolean `portListening`. | Inspect `lastObservation` in the PRT-025 result and in a `timed_out` result. |
| PRT-033 | A `timed_out` result MUST say in `reason` that listeners of other users are invisible. | Stdio probe on an unused port with `timeoutSeconds` 1. Inspect `reason`. |
| PRT-034 | `port_listening` MUST reject `pid`, `name`, `path`, `argsContain`, and `trackId`. | Stdio probe with each argument. Expect `isError` true. |
| PRT-035 | The server MUST reject `port` with any other Condition. | Stdio probe: `{"condition":"cpu_idle","port":8080}`. Expect `isError` true. |

### Constraints and schema

| ID | Requirement | Acceptance check |
| --- | --- | --- |
| PRT-036 | Port lookup MUST work without root and without entitlements. | Run the PRT-004 check with the ad hoc signed bundle as a normal user. |
| PRT-037 | The Port Scan MUST NOT read the sockets of processes of other users. | Unit test with an injected process table that contains other-user pids. Expect no socket read for those pids. |
| PRT-038 | One Port Scan SHOULD finish within 50 ms. | Benchmark 20 Port Scans. Record the median and the process count. The 50 ms value is a budget. The probe measured 3.4 ms to 5.2 ms for 967 processes. |
| PRT-039 | `track_processes` MUST NOT accept or list `port`. | Read the `track_processes` schema. Stdio probe: `{"action":"start","port":8080}`. Expect `isError` true. |
| PRT-040 | The `find_processes` description MUST say that a missing Listener does not mean a free port. | Read the description in `tools/list`. |
| PRT-041 | The growth of the compact `tools/list` response from this specification SHOULD stay at or below 450 bytes. | Measure the compact `tools/list` result before and after the change. The 450-byte value is a budget, not a measurement. |

## Non-goals

- UDP sockets.
- Sockets of processes of other users, or a privileged helper to read them.
- A `connect()` probe. It creates a real connection to the server.
- Stopping or signaling the process that holds a port.
- `track_processes` by port. An agent uses the pid from `find_processes`.
- A Condition that waits until a port is released.
- Support for running `aistats` in the App Sandbox. The sandbox would probably block the Port Scan.

## Dependencies and related specs

- [SDD 0006 · Wait-for Conditions](0006-wait-for-conditions.md) defines the general wait rules, Table A, and the `processes` and `matched` result fields. `port_listening` follows them.
- [SDD 0003 · Top Process Identity](0003-top-process-identity.md) defines the same `startToken` and `ppid` fields for other process rows.
- [SDD 0005 · Response Size Budget](0005-response-size-budget.md) sets the general byte budget. PRT-010 applies the existing `find_processes` budget.
- [SDD 0008 · CLI Parity](0008-cli-parity.md) adds `aistats find` and `aistats wait`. Its CLI-017 and CLI-023 make those commands accept the port selector and `port_listening`.
- [SDD 0011 · Instructions Priority](0011-instructions-priority.md) controls the server instructions. The `find_processes` and `wait_for` lines at [MCPServer.swift:293-295](../../Sources/StatsCore/MCPServer.swift#L293-L295) can name port lookup only within the 0011 size cap.
- [SDD 0012 · Schema Deduplication](0012-schema-dedup.md) removes duplicate selector text. The `port` property is not in the shared selector table, because only two tools accept it.

## Open questions

- UDP listeners were not tested.
- The bound address of a Listening Socket was not tested. A future `addresses` row field could show `127.0.0.1` versus `0.0.0.0`.
- A wildcard Bind Probe can succeed while another user's process listens on one specific address. This BSD bind behavior was not verified on current macOS.
- A non-root bind to a port below 1024 was not tested on current macOS. The result can be `free` or `unknown` (`EACCES`).
- Port forwarding by container or VM tools was not tested. The host-side forwarder is probably a Current-user Process.
- The Port Scan time was measured on one Mac only. Processes with many open files were not measured separately.
- A `port_free` Condition can be useful after an agent stops a server. Demand was not verified.
