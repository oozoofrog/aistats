# SDD 0015 · Job Duration Baselines

Status · Proposed
Issue · [#14](https://github.com/oozoofrog/aistats/issues/14)
Accepted decision · [ADR 0011 · Derive local duration baselines from observed process exits](../adr/0011-duration-baselines.md)

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
| Observed Instance | A Root Instance, or the target process of a `wait_for` `process_exit` wait. |
| Run | One Observed Instance whose start time and exit were both observed. |
| Run Duration | The uptime of the exit observation minus the kernel start uptime of the Observed Instance, in seconds. The uptime clock stops while the Mac sleeps. |
| Censored Run | A Root Instance that was still alive when its track ended, or a `process_exit` target whose wait ended `timed_out` or `unavailable`. Its true duration or exit time is unknown. |
| Command Signature | The key that groups Runs of the same recurring job: HMAC-SHA256 over the executable path and the Subcommand, with the Signature Key. ADR 0011 defines it. |
| Subcommand | Up to two argument tokens that exactly equal entries of the fixed Subcommand Allowlist in ADR 0011, such as `test` for `xcodebuild`. |
| Signature Key | The random installation-local key of the Command Signature, in `key.json` of the Duration Store. |
| Discarded Run | An observed exit that ADR 0011 excludes from the Duration Store: no path read, an unreadable or unknown Subcommand of an allowlisted tool, a clock offset change above 1 s, a duration above 30 days, an `exitResolutionSeconds` above twice the observation interval plus 1 s, or an `exitedAt` earlier than the `notBefore` of the Signature Key. |
| Baseline | Statistics over the stored Runs of one Command Signature. |
| Suggested Timeout | A duration in seconds that the Baseline derives from its upper percentile. It is an estimate. |
| Duration Store | The `durations` directory under `$AISTATS_HOME`. It holds `v1.jsonl`, its lock file and `key.json`. |

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
| `wait_for` `process_exit` keeps the pid and kernel start time of its target. A pid that is gone at the start of a wait gives `unavailable`. | [Waiter.swift:134](../../Sources/StatsCore/Waiter.swift#L134), [Waiter.swift:215](../../Sources/StatsCore/Waiter.swift#L215), [Waiter.swift:218](../../Sources/StatsCore/Waiter.swift#L218) |
| A track keeps at most 64 Root Instances and removes the oldest exited one first. | [ProcessTracker.swift:536](../../Sources/StatsCore/ProcessTracker.swift#L536), [ProcessTracker.swift:883](../../Sources/StatsCore/ProcessTracker.swift#L883) |
| An exec can change the name and path of a tracked instance. A pid track admits its root without a path. | [ProcessTracker.swift:770](../../Sources/StatsCore/ProcessTracker.swift#L770), [ProcessTracker.swift:782](../../Sources/StatsCore/ProcessTracker.swift#L782), [ProcessTracker.swift:642](../../Sources/StatsCore/ProcessTracker.swift#L642) |
| `find_processes` returns at most 15 rows. | [ProcessFinder.swift:46](../../Sources/StatsCore/ProcessFinder.swift#L46) |
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
| DUR-001 | The tracker MUST record one Run for each observed Root Instance exit in a track, except a Discarded Run. | Track a name selector while a fixture starts and ends 5 sequential instances. Require 5 Runs in the Duration Store, although the report shows 3. |
| DUR-002 | A Run MUST give `durationSeconds` rounded to 0.1 s, `exitedAt`, and its Command Signature. | Decode a Run from the DUR-001 fixture. Require the three fields. Require `durationSeconds` within the track interval of the fixture duration. |
| DUR-003 | A Run MUST give `exitResolutionSeconds`, the time from the last observation of the instance alive to the exit observation. | Track with `intervalSeconds` 5. Require `exitResolutionSeconds` of 5.5 or less on each Run, the interval plus the 10 % tick timer leeway. |
| DUR-004 | AIStats MUST NOT record a Censored Run as a Run. Exits observed before the track ended stay recorded. | End a track with `duration_elapsed`, with `stopped`, and with `interrupted` while the target lives. Require no new Run for the target. In each track, let a second instance exit before the end. Require one Run for it. |
| DUR-005 | AIStats MUST record a Run for a Root Instance that started before its track. | Start a 30 s fixture job. Start a pid track 10 s later. Require a Run with `durationSeconds` near 30, not near 20. |
| DUR-006 | AIStats MUST NOT record Runs for child processes that are not Root Instances. | Track with `includeChildren` true over a job that spawns 20 children. Require Runs only for Root Instances. |

### Privacy

| ID | Requirement | Acceptance check |
| --- | --- | --- |
| DUR-007 | The Duration Store MUST NOT contain the `argsContain` text. | Track with `argsContain` set to a unique 32-character marker. Search the AIStats home for the marker. Require zero matches. |
| DUR-008 | The Duration Store MUST NOT contain raw process argument text. A Subcommand is not stored as text either. | Run a fixture job with a unique marker argument. Track it by name. Search the AIStats home for the marker. Require zero matches. Repeat with a fixture named `xcodebuild` and the argument `test`. Require no `test` text in `v1.jsonl`. |
| DUR-009 | The Duration Store MUST NOT contain the absolute home directory path or the user name. | Track a job whose executable is under the home directory. Search the Duration Store for both strings. Require zero matches. |
| DUR-010 | Every file in the Duration Store MUST use mode 0600. | Inspect `v1.jsonl`, its lock file and `key.json` after the first Run and after a compaction. Require `0600` for each. |
| DUR-011 | AIStats MUST NOT send Runs or Baselines off this Mac. | Run the DUR-001 fixture with network access monitored for the AIStats processes. Require no outgoing connection. |

### Storage

| ID | Requirement | Acceptance check |
| --- | --- | --- |
| DUR-012 | Concurrent recorder processes MUST NOT lose or corrupt Runs. This excludes Runs still queued when the 2 s drain bound of ADR 0011 passes, or when SIGKILL or a crash ends the process. | Start 8 processes that each record 100 Runs at the same time and then exit normally. Require 800 decodable Runs, or the retention limit when it is lower. |
| DUR-013 | A Baseline MUST use only Runs inside the ADR limits: 64 per Command Signature, 128 Command Signatures ranked by their newest Run, and 30 days. Compaction MUST remove the other Runs. | Record one Run more than each limit. Require a Baseline without the oldest Run, without the Command Signature whose newest Run is oldest, and without a Run older than 30 days. Force a compaction. Require that the file no longer holds those Runs. |
| DUR-014 | AIStats MUST treat a missing or partly unreadable Duration Store as having only its readable Runs. | Delete the file, then append a corrupt line to a valid file. Require no error and Baselines from the valid lines only. |
| DUR-015 | Recording a Run MUST NOT delay the track tick by more than 50 ms. | Trace tick times on a track over 100 recorded Runs with a store at the retention limit. Require every tick delay of 50 ms or less. |

### Baseline content

| ID | Requirement | Acceptance check |
| --- | --- | --- |
| DUR-016 | From five Runs, a Baseline MUST give exactly `label`, `runs`, `medianSeconds`, `p90Seconds`, `maxSeconds`, `lastRunAt`, `suggestedTimeoutSeconds`, and `resolutionSeconds`. | Load fixtures with 5 and 10 Runs of known durations. Require exactly the eight fields with the expected values. Require `p90Seconds` equal to `maxSeconds` for 5 Runs. |
| DUR-017 | A Baseline MUST NOT give percentile fields or `suggestedTimeoutSeconds` when it has fewer Runs than the ADR minimum. | Load a fixture with one Run less than the minimum. Require `runs` and no `medianSeconds`, `p90Seconds`, or `suggestedTimeoutSeconds`. |
| DUR-018 | A Baseline MUST give a display `label`: the executable file name, then one space and the Subcommand when it is not empty. | Decode a Baseline for a track by name. Require `label` equal to the executable file name. Decode a Baseline for a fixture named `xcodebuild` run with `test`. Require `label` equal to `xcodebuild test`. |
| DUR-019 | A Baseline SHOULD give `suggestedTimeoutSeconds` within the track duration range of 10 to 7,200 s. | Load fixtures with p90 values of 2 s, 600 s, and 10,000 s. Require values clamped to 10 and 7,200 and computed by the ADR formula in between. |
| DUR-020 | A Baseline MUST NOT give `waitForTimeoutSeconds`. | Decode Baselines from the DUR-019 fixtures. Require no `waitForTimeoutSeconds` key. |
| DUR-021 | The Baseline JSON MUST stay at or below 256 bytes compact. | Encode a Baseline with a 64-byte `label`, 64 Runs, durations of 2,592,000 s, and `resolutionSeconds` 9999.9. Require 256 bytes or less. |

### Agent access

| ID | Requirement | Acceptance check |
| --- | --- | --- |
| DUR-022 | A `track_processes` `start` result MUST include `baseline` when the target has a Baseline at the start. | Load a fixture with enough Runs for a name. Start a track by that name while an instance runs. Require `baseline` in `structuredContent`. |
| DUR-023 | A `track_processes` `status` result MUST include `baseline` when the track has one. This applies to a Full Result and to a Delta Result of SDD 0010. `baseline` never collapses. | Call `status` on the DUR-022 track. Require `baseline` in `structuredContent`. Call `status` again with the returned `cursor` as `since` and no change. Require `baseline` in the Delta Result and no `baseline` entry in `unchanged`. |
| DUR-024 | Report trimming MUST keep `baseline`. | Fill a track report past 4,096 bytes with events and spikes. Require `baseline` in the trimmed result. |
| DUR-025 | An agent MUST get the Baseline of a running process in one call without starting a track. | Load a fixture with enough Runs. Send one `find_processes` request with the pid of a running instance and `includeBaseline` true. Require `baselines` with one Baseline and `baselineIndex` 0 on the row. |
| DUR-026 | The Server MUST NOT add Baselines to results of tools that the ADR does not name. | Load Baseline fixtures. Call every other tool. Require no `baseline` field in their `structuredContent`. |
| DUR-027 | A user MUST be able to delete all Runs and replace the Signature Key with one CLI command. | Record Runs. Run `aistats baselines clear`. Require no Runs, a different `key` in `key.json`, and exit code 0. |

### Additional decisions of ADR 0011

| ID | Requirement | Acceptance check |
| --- | --- | --- |
| DUR-028 | A `wait_for` `process_exit` wait that ends `met` MUST record one Run, except a Discarded Run. | Start a 3 s fixture job. Call `wait_for` `process_exit` on its pid. Require one Run with `durationSeconds` near 3 and `exitResolutionSeconds` of 0.5 or less. |
| DUR-029 | A `process_exit` wait that ends `timed_out` or `unavailable` MUST NOT record a Run. | Wait 2 s on a 30 s fixture job. Let the job exit between calls, then call again. Require no Run for the job. |
| DUR-030 | A Baseline lookup MUST NOT write any file in the Duration Store. | Record the size and modification time of each Duration Store file. Call `start`, `status`, and `find_processes` with `includeBaseline`. Require unchanged values. |
| DUR-031 | The Duration Store directory MUST use mode 0700. | Inspect the directory mode after the first Run. Require `0700`. |
| DUR-032 | A Baseline MUST count one Run for an instance that several recorders observed. | Track a fixture job in two Servers and wait on it in a third. Require `runs` to grow by 1 after the job exits. |
| DUR-033 | A `find_processes` result MUST give at most 3 Baselines. Its 4,096-byte size check MUST include `baselines`, `baselineIndex` and `baselinesOmitted`. | Load Baselines for 5 Command Signatures. Find 15 matching processes with `includeBaseline`. Require 3 `baselines`, `baselinesOmitted` 2, and a response of 4,096 bytes or less. Repeat with 15 rows whose paths are 1,024 bytes. Require a response of 4,096 bytes or less, `processesOmitted` equal to the dropped rows, and a `baselineIndex` on each remaining row that points into `baselines`. |
| DUR-034 | `aistats find` MUST accept `--include-baseline` and give the Baseline fields of `find_processes`. | Run `aistats find --pid` of a fixture job with `--include-baseline --json`. Compare its key paths with the DUR-025 result. |
| DUR-035 | A Baseline lookup that rebuilds the index SHOULD take 50 ms or less when the Duration Store is at its file bound. | Fill the store to 16,776 worst-case lines. Before each of 100 `status` calls, change the modification time of `v1.jsonl` from another process, so that each lookup rebuilds the index. Time each lookup inside the Server. Require a median of 50 ms or less. Report the 90th percentile. |
| DUR-036 | AIStats MUST NOT record a Run for an instance whose executable path it never read. AIStats MUST NOT record a Run for an instance of an allowlisted basename whose argument vector it never read. | Track a pid whose path read fails in an injected fixture. Let it exit. Require no Run. Repeat with a fixture named `xcodebuild` whose argument read fails. Require no Run. |
| DUR-037 | AIStats MUST derive the Subcommand by the rules of ADR 0011, with at most two `xcodebuild` actions. AIStats MUST NOT record a Run when the Subcommand is unknown. | Run fixtures with these argument vectors and decode each label. `xcodebuild -scheme App -destination X test` gives `xcodebuild test`. `xcodebuild -quiet clean build` gives `xcodebuild clean build`. `xcodebuild build test analyze` gives `xcodebuild build test`. `go test ./... -run build` gives `go test`. `cargo run -- test` gives `cargo run`. `cargo +nightly build` gives `cargo build`. `swift package resolve` gives `swift`. Require no Run for `xcodebuild -scheme test build`, `xcodebuild -derivedDataPath build test` and `swift -v build`. |
| DUR-038 | A change of the Subcommand Allowlist, the No-value Flag list or the matching rules MUST change the signature version prefix. | Run the unit test that compares a SHA-256 digest of the canonical allowlist, flag list and prefix with its pinned value. Add one allowlist entry without a prefix change. Require the test to fail. |
| DUR-039 | The `label` JSON string content MUST be at most 64 bytes, cut at a character boundary. The `label` MUST come from the path and Subcommand held for the instance, also after the instance exited. | Track a fixture whose basename is 40 two-byte characters, run with `build-for-testing`. Require valid UTF-8, a `label` of 64 bytes or less, and a `label` that is a prefix of the uncut label. Let the instance exit. Require the same `label` in `status` and in the final report of `aistats track`. |
| DUR-040 | AIStats MUST NOT record a Run when the clock offset changed by more than 1 s, when the duration is more than 2,592,000 s, or when `exitResolutionSeconds` is more than twice the observation interval plus 1 s. | Inject a clock offset change of 2 s. Require no Run. Inject 0.9 s. Require one Run. Inject a kernel start time 2,592,001 s before the exit. Require no Run. Stall the tick of a 1 s track for 4 s before the exit. Require no Run. |
| DUR-041 | AIStats MUST accept `key.json` only as a regular file of the current user with mode 0600 and a 32-byte key. After it rejects the key, the writer MUST delete `v1.jsonl` before it writes a new key. | Replace `key.json` in turn with a mode 0644 file, a symbolic link and a 16-byte key. Call `status` with a Baseline fixture. Require no `baseline` and unchanged files. Record one Run. Require a new valid `key.json` with mode 0600 and a `v1.jsonl` that holds only that Run. |
| DUR-042 | After `aistats baselines clear`, the Duration Store MUST NOT hold a Run that exited before the clear. Every stored `sig` MUST use the current Signature Key. | Pause the writer queue of a Server in a test build. Let a tracked fixture exit, so that the Server queues its Run. Run `aistats baselines clear`. Resume the writer queue. Require no Run with an `exitedAt` earlier than `notBefore`. In the same Server, record a new Run after the clear. Require a Baseline lookup that matches it. |
| DUR-043 | Each Run line MUST use the format of ADR 0011: exactly six fields, a 64-character lowercase hexadecimal `sig`, a decimal `startToken` string, numbers with at most one fractional digit, and an `exitedAt` with whole seconds in UTC. | Decode every line of the DUR-001 fixture. Require exactly the six keys, `sig` matching `^[0-9a-f]{64}$`, and `exitedAt` matching `^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$`. Encode a worst-case Run. Require 216 bytes or less with the LF. |
| DUR-044 | When several lines hold the same `pid` and `startToken`, a Baseline and a compaction MUST keep the line with the smallest `exitResolutionSeconds`. On a tie, they MUST keep the first line in the file. | Write three lines for one instance with `exitResolutionSeconds` 2.0, 0.3 and 0.3 and different `durationSeconds`. Require `runs` 1 and the duration of the second line. Force a compaction. Require only the second line in the file. |
| DUR-045 | A recorder process MUST write its queued Runs before a normal exit. This applies to the Server after its input closes or after SIGTERM, SIGINT or SIGHUP, to `aistats track` after its track ends, and to `aistats wait process_exit` after `met`. | Delay the writer queue in a test build. Let a tracked fixture exit. Close the Server input. Require the Run in the store. Repeat with SIGTERM to the Server and with SIGINT to `aistats track` right after the exit. Require the Run in the store each time. |
| DUR-046 | A batch MUST hold at most 50 Runs. Each writer MUST count the file lines before an append that would make its lines appended since its last count more than 50. | Fill the store to 16,384 lines. Start 8 writers that append 50-Run batches at the same time. Count the lines under the shared lock after each batch. Require 16,776 lines or less at every count. |

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
- [SDD 0006 · wait_for conditions](0006-wait-for-conditions.md): `process_exit` is a Run source (DUR-028). Its result stays unchanged.
- [SDD 0008 · CLI parity](0008-cli-parity.md): DUR-027 and DUR-034 follow its CLI conventions. CLI-023 requires `--include-baseline`.
- [SDD 0010 · Delta responses](0010-delta-responses.md): `baseline` is not a Section of Table 2, and it never collapses. Every `status` result, Full or Delta, includes it when the track has one (DUR-023). A later revision of SDD 0010 should list `baseline` as an Always field.
- [SDD 0013 · Orphan report](0013-orphan-report.md): both specs record process lifetimes. ADR 0011 uses the store conventions of [ADR 0009](../adr/0009-orphan-lineage.md) in a separate `durations` directory.

## Open questions

- How much the Subcommand Allowlist of ADR 0011 improves grouping. Interpreter jobs, such as `node` and `python3` scripts, still share one Baseline per interpreter path. No measurement exists.
- How failed or cancelled jobs affect the Baseline. A fast compile error and a full build share one Command Signature.
- How much tighter the kqueue `NOTE_EXIT` exit time is than the tick, and how often the kqueue watch fails so that only polling applies. Not measured.
- How much an index rebuild costs when the Duration Store is at its file bound. DUR-035 states a budget. Not measured.
- How often an option before an `xcodebuild` action, or before a `swift`, `cargo` or `go` subcommand, makes the Subcommand unknown, so that ADR 0011 records no Run. Not measured.
- How often agents start tracks for recurring jobs. Without tracks, no Runs exist. No usage data exists.
- Whether a toolchain upgrade makes old Runs misleading enough to separate them. Not measured.
- Token savings from fewer `wait_for` calls are estimates at about 4 bytes per token. No tokenizer measurement exists.
