# ADR 0010 · Measure a fixed set of developer directories in the app

Status: Accepted

## Context

[SDD 0014](../spec/0014-dev-storage-breakdown.md) requests storage evidence within a fast agent call. A recursive scan can block on protected or remote storage. [SDD 0016](../spec/0016-simulator-resources.md) leaves simulator disk use to SDD 0014.

Read-only `du -skx` walks on one Mac give these figures. Each root was walked twice. The figures are proxies for the App walk, not App measurements.

| Root | Entries | Allocated size | Wall time | CPU time (user + sys) |
| --- | --- | --- | --- | --- |
| Relocated DerivedData on an external local volume | 127,512 | 8.4 GiB | 0.63–1.86 s | 0.60–1.06 s |
| `~/Library/Developer/CoreSimulator/Devices` | 756,733 | 95.1 GiB | 30.8–33.4 s | 16.2–17.7 s |
| `~/Library/Developer/Xcode/iOS DeviceSupport` | 9,499 | 12.6 GiB | 0.10–0.13 s | 0.10–0.11 s |
| `~/Library/Caches/org.swift.swiftpm` | 1,507 | 3.4 GiB | ≤ 0.02 s | ≤ 0.01 s |

A separate `find -x -ls` walk of the same DerivedData took 1.14 s wall and 1.13 s CPU. On that Mac, `IDECustomDerivedDataLocation` in the `com.apple.dt.Xcode` preferences names a directory on an external local volume, with a trailing `/`. The default `~/Library/Developer/Xcode/DerivedData` is empty there.

On the same Mac, a running App build used a mean of 0.57%, 0.64% and 0.76% of one core in three consecutive 60 s windows, read with `proc_pid_rusage`. The panel state and the agent workload were not controlled. This is one observation, not a PERF-004 run. It shows that the margin under the 1% PERF-004 limit of [SDD 0001](../spec/0001-cyberpunk-panel.md) can be 0.25% of one core or less.

## Decision drivers

Avoid privacy prompts and unbounded walks. Identify incomplete and unmeasured roots. Preserve the two-second screen refresh. Keep PERF-004 of SDD 0001 without an exception. Report the largest developer caches, including relocated DerivedData and simulator data. Keep the stored report private, versioned and atomically replaced.

## Considered options

- An on-demand Server walk. It adds more than one second per call and repeats for each session.
- General home-directory enumeration. It increases privacy scope.
- A single bounded App pass with a 200 ms CPU budget. It covers roughly 22,000 entries by linear estimate. Large roots stay incomplete on every pass.
- A bounded App pass in resumable slices with a pass cap. It completes the measured roots and keeps each slice short. This is the decision.
- An exception to PERF-004 during a Storage Pass. It needs an SDD 0001 amendment and makes the closed-panel budget depend on the pass. Rejected.
- Fixed default paths only. A relocated DerivedData reports zero with no signal.
- Fixed paths plus the DerivedData location from the Xcode preference. This is the decision.
- All 14 candidate roots of SDD 0014. Privacy qualification and CPU cost grow with each root.

## Decision

Known Developer Directories. Use this allowlist in v1, in this order:

1. `~/Library/Caches/org.swift.swiftpm`.
2. `~/Library/Developer/Xcode/Archives`.
3. DeviceSupport roots, as defined below.
4. `~/Library/Developer/CoreSimulator/Caches`.
5. `~/Library/Developer/Xcode/DerivedData`.
6. The Custom DerivedData Location, as defined below.
7. `~/Library/Developer/CoreSimulator/Devices`.

Resolve the fixed paths relative to the current user's home. Change the allowlist only through a reviewed specification revision. Do not let users add roots. Report simulator data as directory totals only. Do not report per-device sizes or UDIDs, consistent with ADR 0012.

DeviceSupport roots. Read the entry names of `~/Library/Developer/Xcode` once per pass, without descent. Select the direct children whose name ends with ` DeviceSupport`. Sort them by name in ascending byte order of the UTF-8 name. The first eight children are Known Developer Directories. Report each one as its own entry. Give the report `deviceSupportOmitted`, the count of the ninth and later children. Do not walk, name or list those children.

Normalized Path. Normalize every root path before any other step. Use the Normalized Path for every later step, including the walk and the report.

1. Expand a leading `~/` to the current home path.
2. Remove empty components and `.` components. Remove a trailing `/`.
3. Map a leading `/System/Volumes/Data/` to `/`. Map `/System/Volumes/Data` alone to `/`.
4. Compare paths component by component, after Unicode canonical decomposition and case folding. Use this comparison for the home test, the default-path test, the Excluded Location test and the mount-table match.

Custom DerivedData Location. Read `IDECustomDerivedDataLocation` from the `com.apple.dt.Xcode` preferences domain at the start of each pass. Use only the public preferences API. Accept a string that is an absolute path or starts with `~/`, and that has no `..` component. Normalize the accepted path. Treat it as a Known Developer Directory. Give the report a top-level `derivedDataLocation`:

- `default` when the preference is absent, or when its Normalized Path equals the Normalized Path of the default DerivedData directory. Add no custom root in this case.
- `custom` for another accepted path. Mark the custom entry, or its `notMeasured` item, with `source: "xcode_setting"`.
- `unresolved` for any other value, for example a non-string value, a relative path, a `~user/` path or a path with a `..` component. Report a `notMeasured` item with reason `unresolved_setting`, `source: "xcode_setting"` and no `path`. Do not store or return the preference value.

Keep measuring the default path when it exists, because it can hold stale data. A custom path that does not exist gets no entry, as for every root. Do not follow other Xcode location settings in v1.

Report paths. Give a path inside the current home as `~/` plus the rest of the Normalized Path. Give any other path as its absolute Normalized Path, without rewriting. Apply this rule to directory entries and to `notMeasured` items. An absolute path outside the home can contain the user name, for example in a volume folder. Accept this. The path is the user's own Xcode setting. The report has mode 0600, and only processes of the same user read it.

Volume Class. Classify the volume of each root before any access to the root. Read the mount table once per pass with `getfsstat` and `MNT_NOWAIT`. Run that read on a helper thread with a 200 ms deadline. Apply step 3 of the Normalized Path to each mount path. Match the Normalized Path of the root against the mount paths by the longest component prefix. Do not stat, open or resolve the root to classify it. Use these classes:

| Volume Class | Rule | Enabled in v1 |
| --- | --- | --- |
| `boot_data` | The match is the mount at `/` or `/System/Volumes/Data`. | Yes |
| `network` | The matched mount has no `MNT_LOCAL` flag. | Never |
| `local_other` | Any other matched local mount, for example an external disk, a disk image or another internal volume. | No |

Volume qualification. Keep a source table of the enabled pairs of Volume Class and macOS major version. v1 enables `boot_data` on macOS 14 and on the current test macOS. Add a pair only through a reviewed source change. That change must include the STO-003 result for that class on that macOS version. On a macOS version newer than every table entry, enable `boot_data` only. Report a root on the `network` class with reason `network_volume`. Report a root on another class that is not enabled for the running macOS with reason `volume_unqualified`. When the mount-table read misses its deadline, end the pass with `endReason` `mount_table_timeout`. Walk no root in that case. Report every root in `notMeasured` with reason `not_reached`.

Excluded Locations. Never walk a root whose Normalized Path is inside, or contains, one of these locations:

- `~/Desktop`, `~/Documents`, `~/Downloads`, `~/Pictures`, `~/Movies` and `~/Music`.
- Any path inside `~/Library` that is not inside `~/Library/Developer` or `~/Library/Caches/org.swift.swiftpm`. This covers, for example, `~/Library/Mobile Documents`, `~/Library/CloudStorage`, `~/Library/Containers`, `~/Library/Group Containers`, `~/Library/Mail`, `~/Library/Messages`, `~/Library/Safari`, `~/Library/Calendars`, `~/Library/Cookies`, `~/Library/HomeKit`, `~/Library/Metadata/CoreSpotlight`, `~/Library/Application Support/AddressBook`, `~/Library/Application Support/CallHistoryDB` and `~/Library/Application Support/com.apple.TCC`.
- On the `boot_data` class outside the current home: `/System`, `/Library`, `/Applications`, `/private` and `/Users`. The `/Users` rule covers other users' home directories and `/Users/Shared`.
- A mount path of a `network` volume.

The containment test excludes, for example, a custom root of `~`, `~/Library` or `/`. The six fixed roots do not overlap these locations. The rule applies in practice to the Custom DerivedData Location. Report an excluded root in `notMeasured` with reason `protected_location` or `network_volume`. Do this test on the Normalized Path only, before any access to the root. This list is a reviewed baseline, not a claim of completeness. The `~/Library` rule is an allowlist, so new protected folders in `~/Library` stay excluded. STO-003 stays the release gate.

Redirection check. After a root passes the Volume Class and Excluded Location tests, `lstat` each component of its Normalized Path from the top. Stop at the first symbolic link. Report a root with a symbolic-link component in `notMeasured` with reason `redirected`, and do not walk it. For example, a root under `/tmp` is redirected, because `/tmp` is a symbolic link.

Pass access scope. A pass accesses only these paths: the contents of the walked roots, the `lstat` calls of the redirection check, the entry names of `~/Library/Developer/Xcode`, the files of the preferences API, and `AIStatsPaths.home`. The Volume Class and Excluded Location tests access no path.

Walk rules. Do not follow symbolic links. Do not cross from the volume of a root into another mounted volume.

Size Kind. Use allocated bytes from file block counts, `sizeKind` `allocated_blocks`. Deduplicate hard links by volume and inode within a pass, across slices. Count each distinct clone inode separately. Sparse holes contribute no allocated blocks. Count purgeable blocks while allocated. Directory totals cannot predict the bytes reclaimed by deletion.

Storage Slices and pass caps. Run a pass as a sequence of Storage Slices on a utility-QoS serial queue. Run each slice as one queue block. Do all pass work inside slices, including the preference read, the CPU admission test, the mount-table classification, the redirection check, report encoding and file writes. Keep the traversal state in App memory between slices. Measure slice CPU time with `CLOCK_THREAD_CPUTIME_ID` at the start and end of each slice block. The pass CPU time is the sum of the slice CPU times. Use these budgets:

| Budget | Value | Basis |
| --- | --- | --- |
| Slice wall time | 2 s | Proposal. It keeps each burst short. |
| Slice CPU time | 100 ms | Budget. See the PERF-004 bound below. |
| Pause from the end of a slice to the start of the next slice | 60 s or more | Budget. A 60 s window then contains at most one slice. |
| Pass CPU time | 30 s | Budget. It is about 1.7 times the measured 17.7 s maximum for one root. |
| Pass wall time | 5 h | Budget. The measured roots need an estimated 3 h at the slice budgets. It stays below the six-hour interval. |

Check the slice budgets after each directory entry. End the slice when either slice budget is reached. One directory entry can overrun a budget. Bound that overrun to 10 ms of CPU time in the checks. End the pass when every root is complete or a pass cap is reached. Give the report `endReason` `complete`, `pass_cpu_cap`, `pass_wall_cap` or `mount_table_timeout`. Mark the interrupted entry `complete: false`. List each root that the pass did not reach in `notMeasured` with reason `not_reached`. Give the report `cpuSeconds` and `slices`. A root larger than the pass caps stays incomplete. Its `complete: false` flag discloses this.

PERF-004 bound. Because of the 60 s pause, any 60 s window contains at most one slice. Pass work then adds at most 110 ms of CPU time in any 60 s window, about 0.18% of one core. The App observation in Context shows that this alone does not guarantee the 1% limit. So use a CPU admission test at the start of each slice. Read the App process CPU time with `proc_pid_rusage`. When the App used more than 440 ms of CPU time in the last 60 s, skip the slice and wait another pause. 440 ms plus 110 ms is 550 ms, about 0.92% of 60 s. The 440 ms threshold is a proposal. A skipped slice ends at once and does not count in `slices`. Its CPU time counts in the pass CPU time. Give the report `slicesSkippedForCpu`. This decision makes no exception to PERF-004. STO-019 applies PERF-004 during a pass. If the STO-019 check fails on a test Mac, lower the slice CPU budget or the admission threshold before release.

Pass coverage. 30 s of CPU time at 100 ms per slice gives 300 slices. With a pause of 60 s, they take about 5 h, so the two pass caps meet. The measured roots on the boot data volume need about 17.8 s of CPU time by the `du` proxy. That is about 178 slices, or about 3 h, when no slice is skipped. Skipped slices and deferral pauses make the pass longer. A pass that reaches the wall cap reports `pass_wall_cap` and `complete: false`. At the measured rates of 4.7–23 µs CPU per entry, the 30 s cap covers about 1.3 to 6.4 million entries. These are linear estimates. The worst-case mean pass CPU over six hours is 30 s in 21,600 s, about 0.14% of one core.

Schedule. Start at most one pass in each six-hour interval. Persist `lastPassStartedAt` before the first slice of each pass. Use that time across App restarts. After App launch, start the first pass 120 s later when no pass started in the last six hours. The 120 s delay is a proposal. Otherwise schedule the next pass at `lastPassStartedAt` plus six hours. Treat a stored time later than the current time as the current time.

Deferral. Defer a pass start on battery power, in Low Power Mode, or at thermal state serious or critical. Start no slice while a deferral condition holds, also in the middle of a pass. The pass wall cap keeps running during such a pause. Recheck the conditions at least once every 15 minutes. Also recheck on each power, Low Power Mode or thermal notification. When the conditions clear, start the deferred pass or the next slice within 1 s of the recheck, or at the end of the current pause, whichever is later. Do not resume a pass after an App restart. The previous report stays until the next pass ends.

Storage files. Keep the files in a `storage` subdirectory of `AIStatsPaths.home`. Use mode 0700 for the directory. Use mode 0600 for each file. Write `storage/schedule.json` with `lastPassStartedAt`. Write `storage/report.json` only when a pass ends. Write each file to a temporary file in the same directory, then rename it over the old file. Give both files an integer `schemaVersion`, starting at 1. Increase it for each incompatible change. Treat a report with an unknown `schemaVersion` as absent, with reason `unsupported_schema`. Treat a schedule file that is unreadable or has an unknown `schemaVersion` as `lastPassStartedAt` equal to the App launch time. The next pass then starts six hours after launch, so STO-020 holds. That pass replaces the file with `schemaVersion` 1. Store only root paths, sizes, flags, mount paths, counts and times. Do not store names inside roots, project names, arguments, environment values or the raw preference value. The estimated report size is a few kilobytes.

Agent access. Expose `get_developer_storage` and `aistats storage --json`. Read the Storage Report section only from `storage/report.json`. Build the Volume List and the Drain Rate in the Server or CLI at call time. Never run a Storage Pass from the Server or CLI. Give `storage: null` with reason `no_report`, `unreadable` or `unsupported_schema` when the report cannot be used.

Drain Rate. Add an optional `diskReadAt` to each history point. It is the wall-clock time of the disk read that produced `diskAvailableBytes`. History points can reuse one disk read for up to 30 s, so one `diskReadAt` value is one disk reading. The window is the 60 minutes that end at the call time. History persists in `history.jsonl` while the App is stopped. So the window can hold points that the App recorded before it stopped. Use the first and last disk readings with distinct `diskReadAt` values in that window. Divide the decrease of `availableBytes` by the elapsed hours between their read times. Ignore points without `diskReadAt`. Omit the rate with fewer than two distinct read times in the window. The result already gives `appRunning`, so an agent can see that the window ends before the call time. Keep `diskReadAt` out of `get_stats_history` results to protect the SDD 0005 budget. Omit time-to-low-disk estimates.

Use `availableBytes`, not `availableForImportantUsageBytes`, for these reasons. History stores only `availableBytes`. It changes only when blocks are allocated or freed. The important-usage value also changes when macOS reclassifies purgeable data, which is not write activity. The Panel disk Warning uses `availableBytes`. `diagnose_system` keeps its own threshold metric. The two metrics differ, which is one more reason to omit a time-to-low-disk estimate.

Volume List. Include the boot data volume and Finder-visible mounted volumes. Count omitted mounts. Use cached mount-table statistics for network volumes. Return unavailable when statistics are missing. For each local APFS volume, set `apfsContainer` to the BSD name of the whole disk from DiskArbitration `DADiskCopyWholeDisk`, for example `disk3`. On one Mac, this name equalled the `APFS Container` value of `diskutil info` for every mounted APFS volume checked. The name is valid only within one result, because BSD numbers can change at boot. Omit `apfsContainer` when the lookup fails or the volume is not APFS. Give no cross-volume capacity sums.

Amendments to SDD 0014. This decision amends STO-002, STO-003, STO-005, STO-013, STO-017, STO-018, STO-019, STO-020, STO-021, STO-023, STO-038, STO-041, STO-044, STO-045, STO-046, STO-048 and STO-050. It adds STO-041 through STO-054. The changes are these:

- STO-002 keeps its MUST. Its check now allows the pass access scope above.
- STO-003 now tests each enabled pair of Volume Class and macOS version.
- STO-005 now names the volume of each root.
- STO-013 now also covers the Drain Rate.
- STO-017 and STO-018 now apply to each slice and to the pass, with the budgets above and a stated overrun bound.
- STO-018 now measures slice thread CPU time, not process CPU time. Process CPU time also contains the sampler and the Panel, so it cannot isolate the pass. All pass work runs inside slices, so the slice clock covers it. STO-019 now bounds process CPU time during a pass.
- STO-019 keeps its MUST and widens its scope. It now applies PERF-004 also during a Storage Pass. SDD 0001 is not amended.
- STO-020 now holds across App restarts and unreadable schedule files.
- STO-021 keeps its SHOULD. Its check now covers mid-pass pauses and rechecks.
- STO-023 keeps its MUST and now also covers `notMeasured` paths. Its check no longer forbids the user name in a path outside the home.
- STO-038 now counts disk readings by distinct read time.
- STO-044 now uses the Normalized Path, the Volume Class and reason `volume_unqualified`.
- STO-046 keeps its MUST. It now makes `path` absent for reason `unresolved_setting`, on purpose, so that no preference value is stored.
- STO-048 now fixes the window end at the call time.
- STO-050 now covers `storage/schedule.json`.

The other amendments keep their keywords. The checks of STO-032, STO-036 and STO-040 now name the reason value, the Disk Read Time and the v1 omission.

## Consequences

The initial set omits other build systems and relocated Archives. Allocated bytes can double-count shared clone blocks. A relocated DerivedData on a `local_other` volume shows in `notMeasured` with reason `volume_unqualified` until a reviewed change enables `local_other` for that macOS version. On the Mac measured above, the DerivedData size is therefore unavailable in v1. The `derivedDataLocation` field still shows the relocation. To enable it, run STO-003 with a Custom DerivedData Location on an external fixture volume, then add the passing pair to the source table. A path that reaches a protected folder through a symbolic link is skipped as `redirected`. The redirection check and the boot-data rules can also skip harmless paths, for example a DerivedData under `/tmp`. The history point format gains one optional field. A first report can arrive about 3 h after the first App launch on a Mac like the measured one, and later on a busy Mac. Verify hard links across slices, sparse files, clones, slow mounts, permission denial, slice and pass caps, restarts, path normalization and each excluded location on fixtures before enabling the pass.
