# ADR 0011 · Derive local duration baselines from observed process exits

Status: Accepted

## Context

[SDD 0015](../spec/0015-job-duration-baselines.md) needs repeated, uncensored durations of recurring jobs, such as builds and test runs.

A track observes the kernel start time and the exit of each Root Instance. The tracker sets an exit in three places: the table scan, the tick usage read and the kqueue `NOTE_EXIT` handler ([ProcessTracker.swift:818](../../Sources/StatsCore/ProcessTracker.swift#L818), [:707](../../Sources/StatsCore/ProcessTracker.swift#L707), [:954](../../Sources/StatsCore/ProcessTracker.swift#L954)). The tracker keeps at most 64 Root Instances and removes the oldest exited one first ([:536](../../Sources/StatsCore/ProcessTracker.swift#L536), [:883](../../Sources/StatsCore/ProcessTracker.swift#L883)). An exec can change the name and the path of an instance during its life ([:770](../../Sources/StatsCore/ProcessTracker.swift#L770), [:782](../../Sources/StatsCore/ProcessTracker.swift#L782)). A pid track admits its root without a path ([:642](../../Sources/StatsCore/ProcessTracker.swift#L642)).

A `wait_for` `process_exit` wait holds the pid and the kernel start time of its target in `exitKey` ([Waiter.swift:134](../../Sources/StatsCore/Waiter.swift#L134), [:218](../../Sources/StatsCore/Waiter.swift#L218)). Exit minus start therefore gives the Run Duration. A wait observes only exits that occur during the call. When the pid is gone at the start of a call, the wait ends `unavailable` and gives no exit time ([:215](../../Sources/StatsCore/Waiter.swift#L215)).

The existing JSON Lines store keeps the newest N lines of one file ([Store.swift:50](../../Sources/StatsCore/Store.swift#L50)). It has no per-key or age retention.

The Server runs its shutdown path on SIGTERM, SIGINT and SIGHUP ([main.swift:184](../../Sources/aistats/main.swift#L184)). `aistats track` stops its track on SIGINT and SIGTERM and then prints the final report ([main.swift:416](../../Sources/aistats/main.swift#L416)). `aistats wait` exits at once with status 130 on SIGINT ([DiagnosticCommand.swift:79](../../Sources/aistats/DiagnosticCommand.swift#L79)).

`find_processes` drops rows from the end until the response fits 4,096 bytes ([MCPServer.swift:620](../../Sources/StatsCore/MCPServer.swift#L620)).

SDD 0010 Table 2 lists the Sections and Always fields of a delta `status` result. It does not list `baseline`.

## Decision drivers

- Keep command arguments and the `argsContain` text out of storage.
- Separate `xcodebuild build` from `xcodebuild test`, the main jobs of SDD 0015.
- Bound the store size, the response size and the lookup cost.
- Disclose the timing precision of every Run and Baseline.
- Give a Baseline without starting another track.
- Keep every lookup free of file writes.
- Follow the store conventions of [ADR 0009](0009-orphan-lineage.md), as SDD 0015 asks.

## Considered options

Command Signature content:

- Hash of the full command line. It groups jobs precisely. It requires collecting all argument text, including secrets. Rejected.
- Executable basename only. It merges unrelated installations, such as `Xcode.app` and `Xcode-beta.app`. Rejected.
- Keyed hash of the executable path only. It has the lowest privacy risk. It merges `xcodebuild build` with `xcodebuild test`, and `swift build` with `swift test`. Rejected.
- Keyed hash of the executable path and the `argsContain` text. Each caller picks its own fragment, so two agents split one job into different groups. A track without `argsContain` gets no separation. A holder of the key can test guesses of the text. This conflicts with the existing rule that `argsContain` is never stored. Rejected.
- Keyed hash of the executable path and an allowlisted Subcommand. The allowlist is a fixed, public vocabulary. A matched token reveals no text that the user typed freely. Chosen.

Run sources:

- Tracks only. Runs then exist only when agents start tracks. No data shows how often agents do that. Rejected.
- Tracks and `wait_for` `process_exit`. The Waiter already holds the start time. Its 250 ms poll gives a precise exit time. Exits between calls give no Run. Chosen.

Lookup without a track:

- A new tool. It adds schema bytes to every session. Rejected.
- An opt-in `includeBaseline` argument of `find_processes`, with a CLI option. Chosen.

Signature Key storage:

- The macOS Keychain. The app, the Server and the CLI are separate binaries. A Keychain item that one binary creates can show an access prompt to another. Rejected.
- A file in the private store directory. Chosen.

Toolchain separation:

- Separate Runs by toolchain version. Reading the toolchain version starts subprocesses ([Diagnosis.swift:200](../../Sources/StatsCore/Diagnosis.swift#L200), [:216](../../Sources/StatsCore/Diagnosis.swift#L216)). The path already separates side-by-side installations. Rejected.

## Decision

### Command Signature

1. Compute the Command Signature as HMAC-SHA256 with the Signature Key. The message is `v1`, a zero byte, the executable path, a zero byte and the Subcommand.
2. Use the last executable path that AIStats read while the instance was alive.
3. In a track, read the path at admission, at each observed exec, at each name change and at each tick usage read of a live Root Instance. A pid track reads the path itself, because its root has no report path.
4. In a `process_exit` wait, read the path at the start of the wait and at each poll that sees the process alive.
5. Read the argument vector only when the path basename is in the Subcommand Allowlist. Read it at admission and again when the path or the name changes.
6. Keep only the matched tokens in memory. Discard the argument vector immediately.
7. For `xcodebuild`, examine the argument elements after the first. An element is a candidate when it exactly equals an allowlist entry. A candidate is an action when the element before it is the first element, an element that does not start with `-`, or a Self-contained Flag. A Self-contained Flag starts with `-` and contains `=` or `:`, or is in the No-value Flag list of the table. A candidate after any other element that starts with `-` is ambiguous, because it can be an option value, as in `-scheme test` or `-derivedDataPath build`.
8. When an `xcodebuild` candidate is ambiguous, the Subcommand is unknown. Record no Run for that instance. Otherwise the Subcommand is the first two actions in argument order, joined by one space. It is empty when no action exists.
9. For `swift`, `cargo` and `go`, examine only the second argument element. For `cargo`, skip it when it starts with `+`, a toolchain override, and examine the next element. When the examined element is an allowlist entry, it is the Subcommand. When it starts with `-`, the Subcommand is unknown, and AIStats records no Run. Otherwise the Subcommand is empty. Option values after the subcommand never match, as in `go test ./... -run build` (`test`) and `cargo run -- test` (`run`).
10. Use this Subcommand Allowlist, version `v1`:

| Basename | Entries |
| --- | --- |
| `xcodebuild` | `build`, `build-for-testing`, `test`, `test-without-building`, `analyze`, `archive`, `docbuild`, `clean` |
| `swift` | `build`, `test`, `run` |
| `cargo` | `build`, `check`, `test`, `bench`, `run`, `clippy` |
| `go` | `build`, `test`, `run`, `vet` |

The `xcodebuild` No-value Flag list, version `v1`, holds options that `xcodebuild -help` lists without an argument: `-quiet`, `-json`, `-verbose`, `-alltargets`, `-parallelizeTargets`, `-allowProvisioningUpdates`, `-allowProvisioningDeviceRegistration`, `-skipUnavailableActions`, `-skipPackageUpdates`, `-skipPackagePluginValidation`, `-skipMacroValidation`, `-disableAutomaticPackageResolution`, `-onlyUsePackageVersionsFromResolvedFile`, `-hideShellScriptEnvironment`, `-showBuildTimingSummary`, `-retry-tests-on-failure` and `-run-tests-until-failure`.

11. Change the `v1` prefix when the allowlist, the No-value Flag list or rules 7 to 9 change. Runs with the old prefix then age out. A unit test pins a SHA-256 digest of the canonical allowlist, the flag list and the prefix, so that a change without a new prefix fails the test (DUR-038).
12. Record no Run when AIStats never read the path. Record no Run when the argument vector of an allowlisted basename was unreadable.
13. Exclude the working directory, the user identity, the toolchain version and the `argsContain` text from the signature.
14. Do not store a label in the Duration Store. Compute the label from the same path and Subcommand that give the Command Signature: the path basename, then one space and the Subcommand when it is not empty. A track keeps these values in memory for each Root Instance, also after the instance exits. The label of an exited instance is therefore available in `status` and in the final report of `aistats track`. A `find_processes` lookup uses the values read for its row. Cut the label at a character boundary so that its JSON string content is at most 64 bytes.

### Recording

1. Record a Run in one function that runs when AIStats first sees the exit of a Root Instance. The table scan, the tick usage read and the kqueue handler call it. The scan branch for a root without a member also calls it.
2. Record the Run before any removal from the root or member tables. A removal can then never lose a Run.
3. At track end, treat a Root Instance that is still alive as a Censored Run. Record nothing for it. The end reason does not change this rule: `duration_elapsed`, `stopped` and `interrupted` all apply it.
4. Keep the Runs of exits that AIStats saw before the track ended.
5. Do not store or count Censored Runs.
6. Record a Run when a `process_exit` wait ends `met`. Record nothing when it ends `timed_out` or `unavailable`. `aistats wait process_exit` follows the same rule.
7. Compute `durationSeconds` as the uptime of the exit observation minus the kernel start uptime. Round it to 0.1 s.
8. Compute `exitResolutionSeconds` as the uptime of the exit observation minus the uptime of the last observation of the instance alive. Round it up to 0.1 s. The true exit lies inside this interval. A kqueue exit uses the same rule, so its value is conservative.
9. The uptime clock stops while the Mac sleeps. Record the offset between the continuous clock and the uptime clock at the first observation and at the exit. Discard the Run when the two offsets differ by more than 1 s. Sleep before the first observation stays undetected.
10. Discard a Run longer than 2,592,000 s (30 days). Its start is older than the retention window.
11. Discard a Run whose `exitResolutionSeconds` is more than twice the observation interval plus 1 s. The observation interval is the track `intervalSeconds`, or 0.25 s for a wait. A larger gap means that the observer stalled, for example from App Nap or a stopped process. The largest kept value is 121 s, for a 60 s track interval.
12. Record exits with unknown exit status. AIStats cannot read the exit status of a process that it did not start.
13. A Discarded Run is an observed exit that rules 9 to 11, Command Signature rules 8, 9 and 12, or Store rule 12 exclude. A Discarded Run removes one sample. It never adds a wrong sample. DUR-001 and DUR-028 exempt Discarded Runs on purpose.
14. Put each Run on a serial writer queue for each process. The recorder does constant work on the track or wait queue. The queue entry holds the executable path, the Subcommand, `pid`, `startToken`, `durationSeconds`, `exitedAt` and `exitResolutionSeconds`. It stays in memory and holds no digest.
15. The writer appends in batches of at most 50 Runs.
16. Each recorder process drains its writer queue before a normal exit:
    - The Server drains after its input closes, and in its shutdown path for SIGTERM, SIGINT and SIGHUP.
    - `aistats track` drains after its track ends, also when SIGINT or SIGTERM stops the track, and before it prints the final report.
    - `aistats wait process_exit` drains after a `met` result and before it prints the result. SIGINT ends the wait before `met`, so the wait then has no Run to lose.
17. A drain waits at most 2 s for the exclusive lock. This is a proposed bound, not a measurement. Runs still queued after the bound are lost. Runs in a process that SIGKILL or a crash ends are also lost. A loss removes samples and never adds wrong ones. DUR-012 exempts these losses on purpose.

### Store

1. Use the store conventions of ADR 0009: versioned JSON Lines in a private subdirectory of the app data directory, mode 0700 for directories and mode 0600 for files.
2. Use the `durations` subdirectory under `$AISTATS_HOME`. Keep its directory, lock and retention apart from the lineage store, because the record types and the limits differ.
3. Store Runs in `durations/v1.jsonl`. As in ADR 0009, the file name carries the format version. A reader reads only the file of its own version and gives no Baseline from another version.
4. Serialize appends, compactions and the clear with an exclusive `flock` on `.v1.jsonl.lock`. A reader holds the shared `flock`. This is the existing `JSONLinesFile` lock pattern.
5. Write each Run line as a compact JSON object with no whitespace, followed by one LF. Give it exactly these six fields:

| Field | Format |
| --- | --- |
| `sig` | The HMAC-SHA256 digest as 64 lowercase hexadecimal characters. |
| `pid` | A JSON integer. |
| `startToken` | A JSON string of decimal digits, at most 20, as `find_processes` returns it. |
| `durationSeconds` | A JSON number with at most one fractional digit. |
| `exitedAt` | A JSON string in ISO 8601 UTC with whole seconds and the `Z` suffix, such as `2026-01-31T09:05:00Z`. |
| `exitResolutionSeconds` | A JSON number with at most one fractional digit. |

6. A line in any other format is malformed, and readers and compaction skip it. A new Run field requires an amendment of this ADR and a new file version.
7. The computed worst-case line is 215 bytes with the LF: a 5-digit `pid`, a 20-digit `startToken`, a `durationSeconds` of 2591999.9 and an `exitResolutionSeconds` of 120.9. The file bound uses 216 bytes per line, one byte of margin.
8. Store the Signature Key in `key.json` with the fields `v`, `key` and an optional `notBefore`. The key is 32 random bytes in Base64. `notBefore` is an ISO 8601 UTC time with whole seconds.
9. Create or replace the key only while holding the exclusive lock. Write a temporary file with `O_EXCL`, `O_NOFOLLOW` and mode 0600, then rename it.
10. Accept the key file only when it is a regular file of the current user with mode 0600 and a 32-byte key.
11. When the writer finds a missing or invalid key file, it deletes `v1.jsonl` and writes a new key without `notBefore`. Runs of an unknown key cannot match any lookup. The queued Runs stay and get digests with the new key.
12. The writer reads the key file under the exclusive lock for each batch. It drops each queued Run whose `exitedAt` is earlier than `notBefore`. It then computes `sig` for each remaining Run with that key, under the same lock. Every line in the file therefore uses the current key. A process that started before a key change cannot write a digest of an old key.
13. A reader that finds no valid key returns no Baseline and writes nothing.
14. `aistats baselines clear` takes the exclusive lock, deletes `v1.jsonl`, and writes a new key with `notBefore` set to the current time rounded up to a whole second. It exits with 0. `exitedAt` is the exit time rounded down to a whole second. Every Run that exited before the clear is therefore dropped, also when it waits in the queue of another process. A Run that exits less than 1 s after the clear can also be dropped. Old digests link to no new Run.
15. Keep the newest 64 Runs per Command Signature by `exitedAt`.
16. Keep 128 Command Signatures. Rank them by the `exitedAt` of their newest Run. "Most recently used" means this rank. A lookup never counts as use.
17. Keep Runs for 30 days by `exitedAt`.
18. Deduplicate by `pid` and `startToken` across recorders. Keep the Run with the smallest `exitResolutionSeconds`. On a tie, keep the first line in the file. Apply this rule at read time and at compaction. Appends do not scan the file.
19. Use a new compaction routine. The keep-newest-N routine of `JSONLinesFile` cannot apply per-signature, signature-count or age limits.
20. Run a full compaction at the first batch of each process.
21. Each writer counts the lines that it appended since its last line count. Before a batch, under the exclusive lock, when that count plus the batch size is more than 50, the writer counts the file lines and resets its count. When the file lines plus the batch size are more than 16,384, it compacts before the append. 16,384 is twice the 8,192-Run maximum. The existing store counts every 50 appends of one line each. This rule keeps that interval in lines, so a large batch cannot skip a count.
22. A compaction decodes all lines and skips malformed lines. It applies the age, deduplication, per-signature and signature-count rules. It writes a temporary file with mode 0600 and renames it under the exclusive lock.
23. Readers apply every retention rule at read time. Lines that wait for compaction therefore never reach a Baseline.
24. After a counted batch, the file holds at most 16,384 lines. After that batch, a writer appends at most 49 more lines before its next count, because its count starts at the size of the counted batch, which is at least 1. The computed file bound is therefore 16,384 lines plus 49 lines per concurrent writer. With 8 writers, the number of concurrent Servers seen on the host, this is 16,776 lines, at most 3.6 MB at 216 bytes per line. Each further concurrent writer adds 49 lines to the bound.

### Lookup cost

1. Each process keeps an in-memory index from `v1.jsonl`. For each signature it holds the sorted durations, the newest `exitedAt` and the largest `exitResolutionSeconds`.
2. Before each use, compare the device, inode, size and modification time of `v1.jsonl` and `key.json` under the shared lock. Reuse the index when they are unchanged. Rebuild it otherwise. A rebuild reads the key, decodes every line and applies the read-time retention rules.
3. A lookup takes only the shared lock and writes no file. It computes the digest of the live or held path and Subcommand with the key of the index.
4. A lookup that rebuilds the index has a budget of 50 ms with the store at the file bound. This is a proposed budget, not a measurement. A lookup that reuses the index costs less. Concurrent writers change the file often, so the budget applies to the rebuild. DUR-035 times the rebuild.

### Baseline

1. Return a Baseline when at least one Run matches. Below five Runs, return only `label` and `runs`.
2. From five Runs, return exactly these fields: `label`, `runs`, `medianSeconds`, `p90Seconds`, `maxSeconds`, `lastRunAt`, `suggestedTimeoutSeconds` and `resolutionSeconds`. Do not return the signature digest or `waitForTimeoutSeconds`.
3. Compute the median as the middle value. For an even count, average the middle pair. Round it to 0.1 s.
4. Compute `p90Seconds` by nearest rank: the value at rank ceil(0.9 × n). For 5 to 9 Runs, `p90Seconds` equals `maxSeconds`.
5. Give `lastRunAt` as the newest `exitedAt` in ISO 8601 UTC with whole seconds.
6. Give `resolutionSeconds` as the largest `exitResolutionSeconds` of the Runs used.
7. Compute `suggestedTimeoutSeconds` as ceil(1.25 × `p90Seconds`). Clamp it to 10–7,200 s.
8. The computed worst-case compact Baseline is 251 bytes, inside the 256-byte limit of DUR-021. The computation uses a 64-byte label, 64 Runs, 2,591,999.9 s durations and a 9,999.9 s resolution. Recording rule 11 keeps every stored resolution at 121 s or less, so the 9,999.9 s value is conservative. A new Baseline field requires an amendment of this ADR.

### Agent access

1. A `track_processes` `start` or `status` result gives `baseline` for the newest Root Instance that has a Command Signature. Report trimming keeps `baseline`.
2. A delta `status` result also gives `baseline`. `baseline` is not a Section of SDD 0010, and it never collapses. Its size is at most 256 bytes. SDD 0015 states this rule beside DUR-023. SDD 0010 Table 2 does not list `baseline` yet. A later revision of SDD 0010 should add it to the Always fields.
3. `find_processes` accepts `includeBaseline`, a boolean with the default false. When it is true, the result gives a `baselines` array with at most 3 distinct Baselines, in the order of their first returned row.
4. Each returned row whose Baseline is in the array gives `baselineIndex`. The result counts the other distinct Baselines of the returned rows in `baselinesOmitted`.
5. The 4,096-byte size check of `find_processes` includes `baselines`, `baselineIndex` and `baselinesOmitted`. Each trimming step drops the last row, then computes the three fields again from the remaining rows. A Baseline that no remaining row references is removed. `includeBaseline` can therefore cost rows. `processesOmitted` and `truncated` report these rows as for any other trim. When one row remains, the existing path and name clipping applies. The computed worst-case addition is 1,062 bytes.
6. `aistats find --include-baseline` mirrors `includeBaseline`, as CLI-023 of SDD 0008 requires. Its `--json` output carries the same fields. Its text output prints one line per Baseline after the table.
7. The final report of `aistats track` carries `baseline`.
8. `wait_for` and every other tool return no Baseline.
9. A lookup reads the path and the argument vector by the rules of the Command Signature section.

### Amendments to SDD 0015

This ADR amends SDD 0015 as follows:

- The Terms add Observed Instance, Subcommand, Signature Key and Discarded Run. They extend Run, Run Duration and Censored Run to `process_exit` waits. The Duration Store becomes a directory.
- DUR-001 exempts Discarded Runs. The MUST strength stays. Its scope becomes narrower on purpose, because a Discarded Run would add a sample without a known Command Signature or with a wrong duration.
- DUR-003 defines `exitResolutionSeconds` by the last alive observation. Its check allows the 10 % timer leeway of the tick. The MUST strength stays.
- DUR-004 states that exits seen before the track end stay recorded. The MUST NOT strength stays.
- DUR-008 states that the Subcommand enters only the keyed hash. The MUST NOT strength stays.
- DUR-010 covers every file of the Duration Store. The MUST strength stays.
- DUR-012 covers every recorder process, not only Servers. It exempts Runs still queued when the drain bound passes, or when SIGKILL or a crash ends the process. The MUST NOT strength stays. Its scope becomes narrower on purpose, because no file write can survive SIGKILL.
- DUR-013 ranks signatures by their newest Run, adds the 30-day limit, and lets compaction remove excess lines later. The MUST strength stays.
- DUR-016 freezes the eight Baseline fields. The MUST strength stays.
- DUR-018 adds the Subcommand to the label. The MUST strength stays.
- DUR-020 changes on purpose from a conditional MUST to MUST NOT. A Baseline gives no `waitForTimeoutSeconds`. The 55 s cap is in the Server instructions, and the value saves no tool call.
- DUR-021 and DUR-025 name the worst-case fixture and the `find_processes` lookup in their checks. Their MUST strength stays.
- DUR-023 also covers a delta `status` result. The SDD 0010 dependency line now states that `baseline` never collapses. The MUST strength stays.
- DUR-027 also requires a new Signature Key. The MUST strength stays.
- DUR-028 to DUR-046 are new requirements for this decision. DUR-028 exempts Discarded Runs. DUR-035 is a SHOULD, because its 50 ms value is a budget without a measurement. Every other new requirement is a MUST or a MUST NOT.

## Consequences

Build and test runs of allowlisted tools get separate Baselines. Jobs of `node`, `python3`, `bash` and other interpreters share one Baseline per interpreter path, so their Baselines are less useful. No measurement shows how far build and test durations differ.

The Subcommand rules prefer a lost Run to a wrong group. An `xcodebuild` action after an option that is not in the No-value Flag list gives no Run, for example `-derivedDataPath build test` or an action after a flag that a later Xcode adds. A `swift`, `cargo` or `go` call with an option before its subcommand also gives no Run. Calls of these tools with a subcommand outside the allowlist, such as `swift package` or `go mod`, share the group with an empty Subcommand. `xcodebuild` calls without an action, such as a default build or `-showBuildSettings`, share that group too.

Side-by-side installations, such as `Xcode.app` and `Xcode-beta.app`, get separate Baselines. An in-place upgrade keeps the path, so old and new Runs merge until the 64-Run and 30-day limits remove the old ones.

A fast failure and a full build share one Baseline. For 5 to 9 Runs, `p90Seconds` equals the maximum, so one slow Run sets the Suggested Timeout.

Run Durations exclude Mac sleep, and a Run is discarded when AIStats sees sleep during it. Sleep before the first observation makes a Run shorter than its wall-clock time.

A process with the same account can read the Signature Key. It can then confirm a guess of an executable path and a Subcommand. The risk is low, because such a process can also list the running processes.

When no process appends, Runs older than 30 days stay on disk but never reach a Baseline. `aistats baselines clear` removes them.

The writer queue holds the executable path and the Subcommand in memory until the batch write, because the writer computes the digest under the lock. These values never reach a file.

The change adds the `durations` store, the Signature Key file, the `includeBaseline` argument, the `--include-baseline` option and the `aistats baselines clear` command.

Verify store privacy, the key file rules (DUR-041) and the clear rotation (DUR-027, DUR-042). Verify concurrent recorders, the drain (DUR-045), the file bound (DUR-046) and deduplication across a track and a wait (DUR-032, DUR-044). Verify the retention limits and compaction (DUR-013). Verify censored jobs, exec of a shim, pid tracks, the Subcommand rules (DUR-037, DUR-038) and each discard rule (DUR-036, DUR-040). Verify the percentiles, the label (DUR-039), the Run line format (DUR-043), the 256-byte Baseline, the `find_processes` byte bound (DUR-033) and the 50 ms rebuild budget (DUR-035).
