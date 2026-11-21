# ADR 0009 · Record observed descendant identities for the orphan report

Status: Accepted

## Context

[SDD 0013](../spec/0013-orphan-report.md) needs evidence from before a parent exits. A live tree cannot recover a parent that has already disappeared. A Server Process removes its presence record at shutdown. [MCPServer.swift:127](../../Sources/StatsCore/MCPServer.swift#L127) A detached job reparents to pid 1 when its intermediate shell exits.

Existing rules constrain a recorder in the app:

- [SDD 0001](../spec/0001-cyberpunk-panel.md#performance-budgets) PERF-010 prohibited every process scan without an Exposed Host. PERF-004 limits the closed-panel mean CPU Percentage to below 1%.
- The app refreshes every 2 s. [AppModel.swift:37](../../Sources/AIStatsMenu/AppModel.swift#L37) It reads the process table only for an Exposed Host. [AppModel.swift:142](../../Sources/AIStatsMenu/AppModel.swift#L142)
- [SDD 0017](../spec/0017-process-origin.md) ORG-013 stops process sampling when both Hosts close.
- Existing JSON Lines compaction keeps a line count. It has no age or byte limit. [Store.swift:50](../../Sources/StatsCore/Store.swift#L50)
- The Confirmation Dialog accepts only a registration `ReplacementConsent`. [ConfirmationDialog.swift:5](../../Sources/AIStatsMenu/ConfirmationDialog.swift#L5)

A read-only probe ran on 2026-11-21 on one Apple silicon development Mac with macOS 27.2.1. The probe is context for the budgets. It is not evidence for any limit, and it is not in the repository. Its method is given here so that a reader can repeat it:

1. Call `sysctl` with `CTL_KERN`, `KERN_PROC`, `KERN_PROC_UID`, and the current UID: first for the size, then for the data. This is one table read.
2. Repeat the table read 300 times in one run and 1,000 times in three runs.
3. Measure CPU time with `getrusage(RUSAGE_SELF)` user plus system time before and after each loop. System time includes the kernel time of the `sysctl` calls.
4. Measure wall time per read with a monotonic clock.
5. Call `proc_pidpath` once and `proc_pid_rusage` once for each pid of one table read. Measure CPU time per call the same way.

The probe called these interfaces through a Python foreign-function interface. It did not run a recorder.

| Measured item | Result over four runs |
| --- | --- |
| Current-user processes | 935 to 943 |
| Bytes returned by one table read | 605,880 to 611,064 |
| CPU time per table read, user plus system | 0.14 to 0.18 ms. System time is more than 90% of it. |
| Wall time per table read | Median 0.11 to 0.12 ms. Mean 1.2 to 1.5 ms. Maximum 95 to 164 ms. |
| CPU time per `proc_pidpath` call | 2.6 to 3.2 µs |
| CPU time per `proc_pid_rusage` call | 2.0 to 5.2 µs |
| `kern.maxprocperuid` | 4,000 |

The median wall time is close to the CPU time. A small number of long reads raise the mean wall time. The cause of the long reads was not measured. The probe does not cover the Python call overhead, decoding, ancestor walks, JSON encoding, file writes, or the app process. These results do not replace the ORP-007 check.

## Decision drivers

- Limit CPU overhead across multiple sessions.
- Bound retention and disclose observation gaps.
- Keep the report read-only for agents.
- Keep long-running orphans in the store. They are the main target of the report.
- State every exception to a panel sampling rule in the specification that owns the rule.

## Considered options

| Option | Benefits | Costs |
| --- | --- | --- |
| A recorder in each Server Process | Works without the app. | Eight Sessions repeat the same scan eight times. Recording stops when the Server Process exits. |
| The app and each Server Process | Widest coverage. | Several writers need election, locks, and duplicate removal. |
| A single app recorder | One table read serves all Sessions. | Coverage requires the running app. Closed-panel recording needs a PERF-010 exception. |
| No recording, live Chains of SDD 0017 only | No cost. | A job reparented to pid 1 has no link. The issue stays unsolved. |
| Measure a prototype before acceptance | The CPU budget gets evidence before the decision. | Acceptance waits. This ADR makes the measurement a release gate instead. |

SDD 0013 Purpose item 2 requires a privacy rule for each evidence type:

| Evidence type | Privacy rule | Decision |
| --- | --- | --- |
| `lineage`: parent links in the current-user table | The recorder reads pid, parent pid, table start time, and kernel command name from the table. For each new pid, it also reads the Start Token with `proc_pid_rusage` and the executable path with `proc_pidpath`. It uses the path in memory only to derive the executable name. It stores only the ORP-002 fields and the fields this ADR names. It never stores the path. | Accepted. This is the only value in SDD 0013 Table 1. |
| Process group id or session id | Reading these values exposes no secret. | Rejected. A Terminal job-control group or login session can contain work outside any agent. That breaks ORP-010. The recorder MUST NOT read or store them as evidence. |
| Inherited environment markers | `KERN_PROCARGS2` returns every environment value of a process, including secrets. | Rejected. The recorder MUST NOT read the environment of any process. |
| Arguments, working directory, executable path | These values can hold secrets or project paths. The recorder reads no arguments and no working directory. It reads the executable path only to derive the name, as the `lineage` row states. | Not evidence. ORP-003 prohibits storage of all three. |

Consequence for ORP-005 (SHOULD): this evidence set cannot link a detached job whose intermediate shell exits before the first observation. ORP-005 is not met. The reasons are the privacy rule for environment markers and the false-attribution risk of process groups. SDD 0013 now checks that such a job stays out of the report.

## Decision

### Recorder and activation

The menu bar app is the only writer. The MCP server and the CLI only read.

The Lineage Recorder runs on its own 1 s timer. The 2 s panel refresh stays unchanged. The recorder does not share the refresh table read. This keeps the ORP-004 guarantee of 2 s independent of the 0.5 s refresh tolerance. With a Host exposed, the recorder is therefore a second table read path.

Active Recording requires all of these conditions:

1. The app runs and holds the writer lock.
2. The presence poll lists at least one live Session, or the last live Session disappeared less than 60 s ago. The 60 s grace lets the recorder observe the Agent Process exit after the Server Process removes its presence record.
3. A Host is exposed, or the closed-panel setting `패널을 닫아도 계보 기록` is on.

The closed-panel setting is off by default. With the setting off, the recorder runs only while a Host is exposed. Closing the last Exposed Host stops the recorder within one interval. The stop starts a coverage gap. With the setting off, the app reads no process table without an Exposed Host.

With the setting on, the recorder continues while both Hosts are closed. This is the only process-table read allowed without an Exposed Host. The recorder does not build a tree, a top-process list, or an origin notification.

### Specification amendments

This ADR amends these requirements. Each amendment is in the owning document.

| Requirement | Amendment | Keyword strength |
| --- | --- | --- |
| SDD 0001 PERF-010 | Adds one exception: the SDD 0013 Lineage Recorder with the closed-panel setting on. Every other scan stays prohibited. | MUST NOT unchanged. The scope of the prohibition narrows on purpose. |
| SDD 0001 PERF-004 | The closed-panel budget now includes the recorder with the setting on and eight Sessions. | MUST unchanged. |
| SDD 0001 Closed Host text and Closed idle scenario | State the recorder exception. | Not a requirement row. |
| SDD 0017 ORG-013 acceptance | Closing both Hosts stops origin sampling. The recorder does not restart origin sampling or notifications. | MUST unchanged. |
| SDD 0013 ORP-001, ORP-004 | Scope changes from "while an Agent Process is live" to Active Recording. | MUST unchanged inside Active Recording. The coverage reduction is intentional. Outside Active Recording the report discloses a gap. |
| SDD 0013 ORP-005 | Acceptance check verifies that the job stays unreported. | SHOULD unchanged and not met. |
| SDD 0013 ORP-007 | The check runs in two states: one Host exposed, and both Hosts closed with Closed-Panel Recording on. | MUST unchanged. |
| SDD 0013 ORP-008 | "Retention age" changes to the retention rules in Retention below. Descendant records have no age limit. The removal order changes to that section. | MUST unchanged. |
| SDD 0013 Table 1 | No additional evidence value. | Not applicable. |
| SDD 0013 ORP-014 acceptance | Adds a run with the app quit after the record is written. | MUST unchanged. |
| SDD 0013 ORP-021, ORP-022 | Add the report and row fields of Report surface below. | MUST unchanged. |
| SDD 0013 ORP-032 | Adds the dialog text for a null `endedAt`. | MUST unchanged. The added text is MUST. |
| SDD 0013 ORP-036, ORP-037, ORP-040 to ORP-050 | New rows for the signal rule, the dialog label, activation, storage, coverage, report fields, and the release gate. | New. |

### Record content

The recorder treats a pid as new when the previous read did not contain it or its table start time changed. For each new pid, it walks parent links to the nearest live Agent Identity. The walk follows SDD 0009 AGT-032 through AGT-038, including the identity checks and stop reasons. The recorder looks up a Start Token only for a new pid.

The store holds four record types. Each line carries a `type` field.

| Type | Fields |
| --- | --- |
| Descendant | The ORP-002 fields: pid, Start Token, executable name, Agent Identity, Session name, first-seen time. Also `lastConfirmedAt`. |
| Session | Agent Identity, each observed Server Process identity (pid and Start Token), the latest Session name, first observation, `lastLiveAt`, and exit observation. |
| Coverage | Interval id and one of: interval start, heartbeat, interval stop, or a merged interval with start and end. |
| Compaction | Compaction time and `evicted`, the number of Descendant records that step 6 of that compaction removed. |

A Descendant record does not hold the Chain, intermediate pids, or intermediate names. An intermediate process gets its own record only when it is itself a Descendant.

One Session record exists per Agent Identity. A Server Process restart during one agent run adds a server identity to the same record. Two Sessions that share an Agent Process share one record. A server disconnect alone does not end ownership. Ownership ends only when the Agent Process no longer runs with its Start Token.

A coverage interval without a stop record ends at its last heartbeat. This covers an app crash. A gap is the time between two coverage intervals.

### Record updates in the append-only file

Between compactions the writer only appends. It never edits a line in place.

- Descendant: the writer appends one line when it first observes the pid. Only a compaction changes `lastConfirmedAt`.
- Session: the writer appends a complete Session line when it first observes the Agent Identity, when it observes a new server identity, when the Session name changes, when it observes the exit, and at each interval stop while the Agent Process runs. Each line holds the complete record, including every server identity observed so far. It is not a field delta. Each compaction also sets `lastLiveAt` to the compaction time for each Session whose Agent Process runs.
- The writer records an exit observation only when it observes the Agent Process live and then absent within one coverage interval. At an interval start, an Agent Process that is already absent gets no exit observation.
- Coverage: the writer appends a start line, a heartbeat line every 60 s, and a stop line.
- Compaction: each compaction writes one Compaction line.

A reader resolves the lines in file order:

1. For each Agent Identity, the last decodable Session line is the Session record. The reader does not merge fields across lines.
2. For each pid and Start Token, the last decodable Descendant line is the Descendant record.
3. For each interval id, the coverage interval spans from its start line to its last heartbeat, stop, or merged end.

Compaction writes the resolved state: one line per Session record, one line per Descendant record, and one merged Coverage line per interval. Heartbeat lines therefore do not accumulate past one compaction.

### End time and coverage in the report

A reader decides an Ended Session from the live current-user table. It does not wait for a stored exit record. The report therefore detects an ended agent when the app does not run. ORP-014 holds without the app.

The report sets `endedAt` with these rules:

1. If the Session record has an exit observation, `endedAt` is the time of that observation: the first observation without the Agent Process. `endedAfter` is null.
2. In every other case, `endedAt` is null. The row then contains `endedAfter`, the `lastLiveAt` value of the Session record. The Agent Process ended after that time.

Case 2 applies when the agent exits while the app does not run, while the setting is off with no Exposed Host, or during a crash gap. After a normal stop, `lastLiveAt` is the end of the last coverage interval in which the recorder observed the Agent Process live. After a crash, `lastLiveAt` is the last compaction time, at most 10 minutes before the last heartbeat. `endedAfter` is then a less precise lower bound, but it is still a correct lower bound. The report also contains `lastObservedAt` and `coverageGaps`, the number of gaps since `coverageSince`. `lastObservedAt` is the last heartbeat or stop of the newest coverage interval. A reader does not write an exit record.

### Storage, format, and concurrency

The store is `lineage/v1.jsonl` under the AIStats data directory (`AISTATS_HOME`). The directory mode is 0700. The file mode is 0600.

The file name carries the format version. A reader reads only the file of its own version. If only another version file exists, the report returns no rows and the reason `lineage_version_unsupported`. A new format version starts a new file and a new coverage interval. A reader skips a line that fails to decode. The report gives the number of skipped lines in `unreadableRecords`.

Concurrency follows the precedent of [ADR 0008](0008-cross-session-track-cursors.md):

- The app holds an exclusive non-blocking `flock` on `lineage/.writer.lock` while it records. A second app instance that cannot take the lock does not record.
- Each append and each compaction holds an exclusive `flock` on the store lock file. This is the existing `JSONLinesFile` lock pattern. A reader holds a shared `flock` while it reads.
- Compaction writes a temporary 0600 file in the same directory. It then renames that file over `v1.jsonl`.
- A reader never writes, renames, or deletes a store file. This differs from the presence listing, which deletes records of exited pids.

The Closed-Panel Recording setting is a Boolean in the app's user defaults domain under the key `lineageClosedPanelRecording`. This follows the existing `originAlerts` setting. A missing key means off. The store under `AISTATS_HOME` does not hold the setting. The MCP server and the CLI do not read it.

### Retention

The writer compacts at each recorder start and every 10 minutes during Active Recording. It also compacts before an append that would make the file exceed 2 MiB. Each compaction uses a successful table read from the same pass. If the table read fails, the writer skips the compaction and the pending append. A failed read never removes a record. A compaction applies these steps in order:

1. Set `lastConfirmedAt` to now for each Descendant record whose process runs with its Start Token.
2. Remove each Descendant record whose process does not run with its Start Token.
3. Remove each Session record that no retained Descendant record references and whose Agent Process has exited.
4. Merge the lines of each coverage interval into one Coverage line. Remove each coverage interval that ended more than 7 days ago.
5. If more than 2,000 coverage intervals remain, remove the oldest intervals until 2,000 remain.
6. If the file still exceeds 2 MiB, remove Descendant records by newest first-seen time first until the file is at most 1.5 MiB. The 0.5 MiB margin prevents a compaction before each following append. Step 6 does not remove Session, Coverage, or Compaction records.
7. Remove each Compaction line older than 7 days. If step 6 removed records, write one Compaction line with that count.

Retention by record type:

| Type | Retention |
| --- | --- |
| Descendant | While its process runs with its Start Token, at any age. The first successful compaction after the process exits removes it. During Active Recording that is at most 10 minutes after the exit. While the app does not record, the record stays until the next recorder start. |
| Session | While a retained Descendant record references it or its Agent Process runs. |
| Coverage | 7 days after the interval ends, and at most 2,000 intervals. |
| Compaction | 7 days. |

This replaces removal by oldest first-seen time. A live orphan stays in the store while it runs, at any age. This decision has no age limit for Descendant records. An age limit cannot remove a record that steps 1 and 2 keep, because step 1 confirms every retained record. Step 6 removes the newest Descendant records first, so a long-running orphan stays longest.

`coverageSince` is the start of the oldest retained coverage interval. Steps 4 and 5 move it forward. `endedAfter` comes from the Session record, so removal of a coverage interval does not change it.

`evictedRecords` is the sum of `evicted` over the retained Compaction lines. It therefore counts size evictions in the last 7 days. A reader computes it from the file. It does not need the writer.

Size estimate (budgets, not measured for a recorder):

| Content | Bound |
| --- | --- |
| Descendant records after step 2 | One per live current-user process. `kern.maxprocperuid` was 4,000 on the probe Mac. With the 256-byte record budget that is at most about 1,000 KB. The probe saw 935 to 943 processes, about 240 KB. |
| Coverage records after steps 4 and 5 | 2,000 intervals with a 128-byte merged line budget: at most 256 KB. |
| Heartbeat lines between compactions | 10 lines per 10-minute compaction interval. |
| Session records | One per referenced or live Agent Identity. Each referenced Session has at least one retained Descendant record. |
| Compaction records | One per compaction that evicted records in the last 7 days. None while every record stays within its budget. |

With every record within its budget, steps 2 to 5 keep the file below 2 MiB, and step 6 does not run. Step 6 runs only when records exceed their budget or many short-lived Descendants are appended between compactions. Their rate is not measured. The 2 MiB compaction trigger bounds the file in every case. Coverage lines do not grow with recording time. They hold at most about 256 KB plus the heartbeats of one compaction interval. So long Closed-Panel Recording does not move live Descendant records into step 6.

### Privacy

The recorder reads no arguments, environment values, working directories, process group ids, or session ids.

The recorder reads the executable path of each new pid with `proc_pidpath`. [Proc.swift:273](../../Sources/StatsCore/Proc.swift#L273) It derives the executable name from the path: the last path component, or the kernel command name when the path is unreadable or empty. [Proc.swift:274](../../Sources/StatsCore/Proc.swift#L274) The path stays in memory only for this derivation. The recorder does not store, log, cache, or report the path. ORP-003 checks the store.

A custom binary name can reveal a project name. The name stays on disk while the process runs. After the process exits, the name stays until the next successful compaction: at most 10 minutes during Active Recording, or until the next recorder start while the app does not record. The report returns the same name that `find_processes` already returns for a live process.

### Report surface

The report is the separate MCP tool `get_orphan_processes` and the CLI command `aistats orphans`. This ADR rejects a section of `get_agent_sessions`. `get_agent_sessions` measures CPU over an interval (AGT-030). ORP-023 prohibits interval measurement in the orphan report. A section would also share one 4,096-byte budget with session and origin rows.

The report object always contains these fields. SDD 0013 ORP-021 and ORP-022 list them.

| Level | Field | Value |
| --- | --- | --- |
| Report | `observedAt`, `processes`, `matched`, `truncated` | As in SDD 0013. |
| Report | `coverageSince` | Start of the oldest retained coverage interval. Null when no interval is retained. |
| Report | `lastObservedAt` | Last heartbeat or stop of the newest coverage interval. Null when no interval is retained. |
| Report | `coverageGaps` | Number of gaps between retained coverage intervals. |
| Report | `evictedRecords` | Sum of `evicted` over the retained Compaction lines. 0 when there is none. |
| Report | `unreadableRecords` | Number of lines that failed to decode. |
| Report | `reason` | `lineage_version_unsupported` when only another version file exists. Otherwise null. |
| Row | `endedAt`, `endedAfter` | Exactly one of them is non-null. |

### Termination and dialog hosting

The app generalizes the Confirmation Dialog. A consent value per action replaces the fixed `ReplacementConsent` type. Each consent value supplies the captured summary, the destructive button label, and the confirm action. Every [ADR 0007](0007-confirmation-dialog-hosting.md) rule stays in force:

- One app-modal panel per action.
- Capture of the initiating Host at presentation.
- `.applicationDefined` popover behavior during the modal loop, restored on every exit path.
- Return, Escape, and close cancel. Initial focus is on `취소`.

The termination consent captures the process name, pid, Start Token, Session name, and ended time at presentation. The destructive button is `프로세스 종료`. If `endedAt` is null, the dialog states that the end time is unknown and shows the time since `endedAfter`. Immediately before the signal, the app verifies these conditions:

1. The process belongs to the current UID.
2. The pid runs with the captured Start Token.
3. The Agent Identity of the Session record has no running process.
4. The Ancestor Walk of the process reaches no live Agent Process.

If all conditions hold, the app sends one SIGTERM to that pid with `kill`. It does not use `killpg`. After 2 s, the app checks the pid and Start Token again. It shows the process as exited or as still running. It never sends SIGKILL.

### Dismiss action

This decision adds no dismiss action. A development server that a user keeps on purpose stays in the report while it runs. A dismiss action adds persistent user state and a new privacy surface. It requires a separate ADR.

### Budgets and release gate

These values are budgets, not measurements: the 1 s interval, the 2 s observation guarantee, the 10 s detection limit, the 300 ms response limit, the 0.5% core limit, the 256-byte record, the 128-byte merged Coverage line, the 2,000-interval cap, the 2 MiB trigger, the 1.5 MiB eviction target, the 7-day Coverage and Compaction retention, the 10-minute compaction interval, the 60 s heartbeat, and the 60 s grace.

The CPU limits are a release gate, not an acceptance condition of this ADR. A release that includes the recorder MUST include a prototype measurement of these values, each with eight live Sessions:

- ORP-007 with one Host exposed (Exposed run).
- ORP-007 with both Hosts closed and Closed-Panel Recording on (Closed run).
- The amended PERF-004 with both Hosts closed and Closed-Panel Recording on.

The gate has these outcomes:

| Result at 1 s | Result at the 2 s fallback | Release content |
| --- | --- | --- |
| All values within their limits | Not measured | The recorder at 1 s with the closed-panel setting. |
| A value exceeds its limit | All values within their limits | The recorder at 2 s. ORP-004 changes to 4 s and ORP-041 to 2 s intervals in the same change. |
| A value exceeds its limit | Only Closed-run or PERF-004 values exceed their limits | The recorder at 2 s without the closed-panel setting. The release MUST NOT include the closed-panel setting. |
| A value exceeds its limit | The Exposed run exceeds the ORP-007 limit | The release MUST NOT include the recorder, the report tool, the CLI command, or the app action. Issue #12 stays open. A new decision is required. |

The fallback requires a new measurement of all three values. Removing the closed-panel setting does not change the Exposed run, so it cannot fix an Exposed-run failure.

## Consequences

- With the default setting, coverage is limited to time with an Exposed Host. App downtime and brief parent lifetimes also leave gaps. The report discloses gaps with `coverageSince`, `coverageGaps`, `lastObservedAt`, and `endedAfter`.
- A detached job whose intermediate shell exits before the first observation has unknown origin. ORP-005 is not met.
- With a Host exposed, the app reads the process table on two paths. This ADR does not amend PERF-005 or PERF-006. The SDD 0001 open-panel scenarios do not require a live Session, so the recorder does not run during their checks. The ORP-007 Exposed run measures the recorder increment with a Host exposed. ORP-050 makes that run a release gate. A PERF-005 or PERF-006 result therefore does not show the recorder cost.
- Tests before release: two Sessions that share an agent, a Server Process restart during one agent run, PID reuse, cancellation, a signal-resistant fixture, retention order with a live record first seen 8 days earlier, a reader during compaction, a second app instance, an unsupported version file, coverage merge and the 2,000-interval cap, eviction counts read by a separate reader, and recording cost with eight Sessions in the Exposed and Closed runs.
