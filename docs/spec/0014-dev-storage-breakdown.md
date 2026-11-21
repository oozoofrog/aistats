# SDD 0014 · Developer Storage Breakdown

Status · Proposed
Issue · [#13](https://github.com/oozoofrog/aistats/issues/13)
Accepted decision · [ADR 0010 · Measure a fixed set of developer directories in the app](../adr/0010-storage-accounting.md)

## Purpose and scope

An Architecture Decision Record (ADR) MUST be accepted before implementation of this specification starts. That ADR MUST make these decisions:

1. The exact set of Known Developer Directories, how the set can change, and whether users can add entries.
2. The Size Kind that a Storage Pass reports, and how it counts APFS clones, hard links, sparse files, and purgeable data.
3. How an agent reads the Storage Report: a new MCP tool, a new argument of an existing tool, or both. The ADR also decides the CLI command name.
4. The Storage Pass schedule, its wall-time budget, its CPU-time budget, and the conditions that defer a pass.
5. The volumes that the Volume List includes and omits, and how it identifies volumes that share one APFS container.
6. The locations that a Storage Pass excludes so that it never causes a macOS privacy consent prompt.
7. The disk metric and the window for the Drain Rate, and whether the result includes a time-to-low-disk estimate.

This specification covers a read-only report of storage use on this Mac for AI coding agents and the human user. The report has three parts. The Volume List gives the capacity and free space of mounted volumes. The directory part gives the sizes of Known Developer Directories, which the menu bar app measures in the background within a time budget. The Drain Rate tells how fast free space on the boot volume decreased in the recorded history. AIStats never deletes, moves, or changes files.

The key words "MUST", "MUST NOT", "SHOULD", "SHOULD NOT", and "MAY" in this document are to be interpreted as described in BCP 14 [RFC2119] [RFC8174] when, and only when, they appear in all capitals.

[RFC2119]: https://www.rfc-editor.org/rfc/rfc2119.html
[RFC8174]: https://www.rfc-editor.org/rfc/rfc8174.html

## Terms

| Term | Meaning |
| --- | --- |
| App | The AIStatsMenu menu bar app. |
| Server | The `aistats` stdio MCP server process. One Server runs for each connected agent session. |
| Volume List | The list of mounted volumes with their capacity and free space. |
| Known Developer Directory | A directory in the fixed set that the ADR defines, for example a build cache or a simulator data folder. |
| Storage Pass | One run of the App that measures the size of every Known Developer Directory. |
| Storage Report | The latest stored result of a Storage Pass, plus its metadata. |
| Size Kind | The size measure that a Storage Pass reports, either allocated bytes on disk or logical file length. |
| Drain Rate | The change of free space on the boot volume per hour, computed from the recorded history. |
| Low Disk Threshold | The 10 GiB free-space limit that `diagnose_system` and the Panel disk Warning use. |
| Storage Slice | One bounded part of a Storage Pass. The App keeps the traversal state in memory between slices. |
| Custom DerivedData Location | The directory that the Xcode preference `IDECustomDerivedDataLocation` names, when ADR 0010 accepts its value. |
| Excluded Location | A location that ADR 0010 lists as never walked, for example `~/Documents` or a network volume. |
| Normalized Path | A root path after the lexical normalization of ADR 0010: `~/` expanded, `.` components and the trailing `/` removed, `/System/Volumes/Data` mapped to `/`, and compared after Unicode decomposition and case folding. |
| Volume Class | The class of the volume of a root, `boot_data`, `network` or `local_other`, from a lexical mount-table match in ADR 0010. |
| Disk Read Time | The wall-clock time of the disk read that produced a history point's `diskAvailableBytes`. |

## Background and evidence

| Fact | Source |
| --- | --- |
| The sampler reads one volume only. The default path is `/`. | [SystemSampler.swift:43](../../Sources/StatsCore/SystemSampler.swift#L43), [SystemSampler.swift:203](../../Sources/StatsCore/SystemSampler.swift#L203) |
| A disk reading contains `mountPath`, `totalBytes`, `availableBytes`, and the optional `availableForImportantUsageBytes`. | [Snapshot.swift:67](../../Sources/StatsCore/Snapshot.swift#L67) |
| `availableBytes` comes from `statfs` free blocks. `availableForImportantUsageBytes` comes from the volume resource key and includes purgeable data. | [SystemSampler.swift:214](../../Sources/StatsCore/SystemSampler.swift#L214), [SystemSampler.swift:208](../../Sources/StatsCore/SystemSampler.swift#L208) |
| `diagnose_system` compares `availableForImportantUsageBytes`, or `availableBytes` when that is absent, with the 10 GiB threshold. The Panel Warning compares `availableBytes` with the same threshold. | [Diagnosis.swift:29](../../Sources/StatsCore/Diagnosis.swift#L29), [Diagnosis.swift:72](../../Sources/StatsCore/Diagnosis.swift#L72), [PanelData.swift:16](../../Sources/AIStatsMenu/PanelData.swift#L16), [PanelData.swift:26](../../Sources/AIStatsMenu/PanelData.swift#L26) |
| The App refreshes every 2 s and rereads disk and battery at most every 30 s. | [AppModel.swift:37](../../Sources/AIStatsMenu/AppModel.swift#L37), [AppModel.swift:38](../../Sources/AIStatsMenu/AppModel.swift#L38), [SystemSampler.swift:69](../../Sources/StatsCore/SystemSampler.swift#L69) |
| The App records one history point per refresh. Each point stores `diskAvailableBytes` from `availableBytes`. | [AppModel.swift:222](../../Sources/AIStatsMenu/AppModel.swift#L222), [Store.swift:120](../../Sources/StatsCore/Store.swift#L120), [Store.swift:132](../../Sources/StatsCore/Store.swift#L132) |
| History keeps 1,800 points, which is one hour at the 2 s cadence. The App appends points only while it runs. The points persist in `history.jsonl` after the App stops. The App counts as not recording when the newest point is 15 s old or older. | [Store.swift:140](../../Sources/StatsCore/Store.swift#L140), [Store.swift:142](../../Sources/StatsCore/Store.swift#L142), [Store.swift:147](../../Sources/StatsCore/Store.swift#L147) |
| `get_stats_history` already returns `diskAvailableChangeBytes` for the window, but no rate and no window-independent figure. | [Store.swift:239](../../Sources/StatsCore/Store.swift#L239), [Store.swift:256](../../Sources/StatsCore/Store.swift#L256) |
| When the App does not record, `get_stats_history` still returns the persisted points. It gives `recording: false`, `startCommand`, and a note that the history ends at the last recorded sample. | [Store.swift:192](../../Sources/StatsCore/Store.swift#L192), [Store.swift:207](../../Sources/StatsCore/Store.swift#L207), [Store.swift:209](../../Sources/StatsCore/Store.swift#L209) |
| The App runs sampling and store work on utility-QoS queues. | [AppModel.swift:68](../../Sources/AIStatsMenu/AppModel.swift#L68), [AppModel.swift:69](../../Sources/AIStatsMenu/AppModel.swift#L69) |
| Store files use mode 0600 in a 0700 directory under `$AISTATS_HOME`. | [Store.swift:6](../../Sources/StatsCore/Store.swift#L6), [Store.swift:54](../../Sources/StatsCore/Store.swift#L54), [Store.swift:88](../../Sources/StatsCore/Store.swift#L88) |
| The closed-panel App has a mean CPU budget below 1% over 60 s. | [0001-cyberpunk-panel.md](0001-cyberpunk-panel.md) PERF-004 |
| Observed on one Mac, panel state not controlled: a running App build used 0.57%, 0.64% and 0.76% of one core in three 60 s windows. | `proc_pid_rusage`, [ADR 0010](../adr/0010-storage-accounting.md) Context |
| The app bundle is ad-hoc signed without entitlements. | [bundle.sh:34](../../scripts/bundle.sh#L34), [bundle.sh:35](../../scripts/bundle.sh#L35) |
| No CLI command or MCP tool reports more than one volume or any directory size. | [main.swift:4](../../Sources/aistats/main.swift#L4), [MCPServer.swift:352](../../Sources/StatsCore/MCPServer.swift#L352) |
| A history point stores the sample time `t` only. The App reuses one disk reading for up to 30 s, so several points can carry one disk reading. | [Store.swift:112](../../Sources/StatsCore/Store.swift#L112), [SystemSampler.swift:69](../../Sources/StatsCore/SystemSampler.swift#L69) |
| `get_stats_history` removes `memoryUsedBytes` from each returned point to fit the response budget. | [Store.swift:204](../../Sources/StatsCore/Store.swift#L204) |
| Measured on one Mac: `IDECustomDerivedDataLocation` names a directory outside the home directory, and the default DerivedData directory is empty. | `defaults read com.apple.dt.Xcode IDECustomDerivedDataLocation` |
| Measured on one Mac with `du -skx`, two runs each: relocated DerivedData, 127,512 entries, 0.60–1.06 s CPU; `CoreSimulator/Devices`, 756,733 entries, 95.1 GiB, 16.2–17.7 s CPU and 30.8–33.4 s wall. | [ADR 0010](../adr/0010-storage-accounting.md) Context |
| Measured on one Mac: the DiskArbitration whole disk of each mounted APFS volume equals its `APFS Container` value in `diskutil info`. | `diskutil info` |

Agents that run builds need to know where disk space goes before a large build, an archive, or a simulator install. Today an agent runs `df` and `du` through a shell. `du` over a large build cache can run for a long time and block the agent turn. The Server runs once for each agent session, so a directory walk in the Server would repeat for every session. The App runs once per user, so the App is the single place to measure.

ADR 0010 fixes the set of Known Developer Directories. It selects SwiftPM, Archives, each `* DeviceSupport` child, `CoreSimulator/Caches`, `CoreSimulator/Devices`, the default DerivedData, and the Custom DerivedData Location. This specification covers simulator disk use as these directory totals. Per-device simulator data sizes are out of scope. The candidates before that decision were: `~/Library/Developer/Xcode/DerivedData`, `~/Library/Developer/Xcode/Archives`, `~/Library/Developer/Xcode/*DeviceSupport`, `~/Library/Developer/CoreSimulator/Devices`, `~/Library/Developer/CoreSimulator/Caches`, `~/Library/Caches/org.swift.swiftpm`, `~/.npm`, `~/Library/Caches/Yarn`, `~/Library/pnpm`, `~/.gradle/caches`, `~/Library/Caches/CocoaPods`, `~/Library/Caches/Homebrew`, `~/.cargo/registry`, and `~/go/pkg/mod`.

## Requirements

### Safety and scope

| ID | Requirement | Acceptance check |
| --- | --- | --- |
| STO-001 | AIStats MUST NOT delete, move, rename, modify, or purge any measured file or directory. | Create a fixture tree with known content and modification times. Run three Storage Passes. Compare a recursive manifest of paths, sizes, modes, and modification times before and after. Require no difference. |
| STO-002 | A Storage Pass MUST measure only Known Developer Directories and their contents. | Run a Storage Pass alone in a test process with a file-access trace (`fs_usage -f filesys` filtered to that process). Require that every opened or stat-read path is in the ADR 0010 pass access scope: inside a walked root, an `lstat` of a component of a root's Normalized Path, the entry names of `~/Library/Developer/Xcode`, a file of the preferences API, or inside the AIStats home. Require no access to a root that the pass reports in `notMeasured` with reason `protected_location`, `network_volume`, `volume_unqualified` or `unresolved_setting`. |
| STO-003 | A Storage Pass MUST NOT cause a macOS privacy consent prompt. | Reset privacy permissions for the App bundle identifier with `tccutil reset All`. Create every ADR 0010 root. Create a Custom DerivedData Location on each Volume Class that the ADR 0010 source table enables. Run a Storage Pass on each macOS version in that table. Require no consent prompt and no new entry in Privacy & Security settings. Record the macOS version, the Volume Class and the result in the review of the change that adds the table entry. |
| STO-004 | A Storage Pass MUST NOT follow symbolic links. | Put a symbolic link loop and a link to a 1 GiB fixture inside a measured fixture directory. Require that the pass ends and the reported size excludes the 1 GiB target. |
| STO-005 | A Storage Pass MUST NOT cross from the volume of a root into another mounted volume. | Mount a disk image inside a measured fixture directory. Require that the reported size excludes the content of the disk image. |
| STO-006 | The Storage Report MUST use `scope` `"current_user"`. | Decode a Storage Report. Require `scope == "current_user"`. |

### Volume List

| ID | Requirement | Acceptance check |
| --- | --- | --- |
| STO-007 | The Volume List MUST include the boot data volume and every mounted volume that Finder shows. | Mount a disk image and connect a USB volume. Compare the Volume List with the Finder sidebar Locations. Require every shown volume and the boot data volume. |
| STO-008 | The Volume List MUST report the number of omitted volumes in `volumesOmitted`. | Compare the Volume List with `mount` output. Require that included plus `volumesOmitted` equals the mount count. |
| STO-009 | Each volume entry MUST give `mountPath`, `totalBytes`, and `availableBytes` as byte integers. | Decode a result. Require the three fields on each readable entry with integer JSON values. |
| STO-010 | Each volume entry SHOULD give `availableForImportantUsageBytes` when the system provides it. | Decode the boot data volume entry. Require the field when the URL resource key returns a value. |
| STO-011 | A volume whose statistics cannot be read MUST appear in `unavailable` without byte fields. | Inject a statistics failure for one volume. Require that its entry has no byte fields and that its `mountPath` is listed in `unavailable`. |
| STO-012 | The Volume List MUST return within 200 ms when one network volume does not respond. | Inject a mount-table provider whose statistics call blocks for 30 s on one volume. Time the request. Require completion within 200 ms with that volume listed in `unavailable`. |
| STO-013 | The Server MAY build the Volume List and the Drain Rate during the tool call. | Not applicable. Neither part needs a directory walk. |
| STO-053 | Each local APFS volume entry SHOULD give `apfsContainer`, the BSD name of its whole disk from `DADiskCopyWholeDisk`. | Compare each `apfsContainer` value with the `APFS Container` value of `diskutil info` for that volume. Require equality. |
| STO-054 | The Volume List MUST NOT give a capacity sum across volumes. | Decode a result with two volumes in one APFS container. Require no total or sum field. |

### Storage Pass

| ID | Requirement | Acceptance check |
| --- | --- | --- |
| STO-014 | The Server and the CLI MUST NOT run a Storage Pass. | Call every Server tool and CLI command with a file-access trace. Require that no Server or CLI process enumerates a Known Developer Directory. |
| STO-015 | The App MUST run a Storage Pass off the main thread at utility or background quality of service. | Record a Storage Pass with Instruments or a signpost trace. Require that the directory walk has no main-thread samples and runs at utility QoS or lower. |
| STO-016 | A Storage Pass MUST NOT delay the 2 s metric refresh by more than 100 ms. | Record refresh timestamps during a Storage Pass over a fixture with one million files. Require every interval between 1.9 s and 2.1 s. |
| STO-017 | A Storage Slice and a Storage Pass MUST stop when they exceed their wall-time budgets in ADR 0010. | Use a test clock that advances 1 ms per directory entry and a fixture that takes longer than the pass wall cap. Require every slice to end at or before 2.001 s, which allows one directory entry of overrun. Require every pause from a slice end to the next slice start to be 60 s or more. Require the pass to end at or before 5 h plus 1 ms with `endReason` `pass_wall_cap` and a stored Storage Report. |
| STO-018 | A Storage Slice and a Storage Pass MUST stay within their CPU-time budgets in ADR 0010. The App MUST do all pass work inside Storage Slices. | Read the slice thread CPU time with `CLOCK_THREAD_CPUTIME_ID` at the start and end of each slice block over a large fixture. Require each slice at or below 110 ms, which allows 10 ms for the last directory entry. Require the sum at or below 30.01 s. Trace the pass with signposts. Require that the preference read, the mount-table read, report encoding and file writes occur inside slice blocks. |
| STO-019 | The App MUST continue to meet PERF-004 of SDD 0001, also during a Storage Pass. | Run the PERF-004 CPU check in a 60 s window with no Storage Pass. Then run it in five consecutive 60 s windows during a pass over a fixture with one million files. Require `mean < 1.0` in each window. Inject 450 ms of App CPU time into one 60 s window. Require that the next slice is skipped and that `slicesSkippedForCpu` counts it. |
| STO-020 | The App MUST NOT start Storage Passes more often than the interval that the ADR fixes, including across App restarts. | Run the App for three intervals with a test clock. Restart the App twice in each interval. Count started passes. Require at most one pass per interval. |
| STO-021 | The App SHOULD defer a Storage Pass on battery power, in Low Power Mode, or at thermal state serious or critical. | Use a test clock and an injected power and thermal source. For each condition, require no pass start while the condition holds. Set the condition in the middle of a pass. Require no slice start while it holds. Clear the condition with notifications suppressed. Require the next start within 15 min. Clear it with a notification. Require the next start within 1 s of the notification, or at the end of the current 60 s pause, whichever is later. |
| STO-041 | The Known Developer Directories MUST equal the ADR 0010 allowlist. | Create every SDD 0014 candidate in a fixture home. Create ten `* DeviceSupport` children of `~/Library/Developer/Xcode`. Run a pass. Require entries or `notMeasured` items for the ADR 0010 roots only. Require entries for the first eight children in ascending byte order of name, `deviceSupportOmitted` equal to 2, and no name of the other two children in the report. |
| STO-042 | The App MUST persist `lastPassStartedAt` before the first Storage Slice of each pass. | Stop the App during the first slice of a pass. Read `storage/schedule.json`. Require `lastPassStartedAt` equal to the pass start. |
| STO-043 | The App MUST start the first pass 120 s after launch when no pass started in the last six hours and no deferral condition holds. | Launch with a test clock, AC power, and no schedule file. Require a pass start at 120 s. Relaunch one hour later. Require no pass start before six hours from the first start. |
| STO-044 | The App MUST NOT walk a root whose Normalized Path is inside, or contains, an Excluded Location. The App MUST classify such a root without access to its path. | Set the Custom DerivedData Location to each of these values in turn: `~/Documents/DD`, `~/documents/DD`, `~/./Documents/DD/`, `/System/Volumes/Data` followed by the home path and `/Documents/DD`, `~/Library/Cookies/DD`, `~`, a path on a network volume, a path on an external local volume, and a path under `/tmp`. Run a pass with a file-access trace for each value. Require no access to each path, except the `lstat` calls of the redirection check for the `/tmp` value. Require a `notMeasured` item with reason `protected_location`, `network_volume`, `volume_unqualified` or `redirected` as ADR 0010 assigns. Inject a mount-table read that blocks for 30 s. Require `endReason` `mount_table_timeout` within 1 s and no walk. |

### Storage Report content

| ID | Requirement | Acceptance check |
| --- | --- | --- |
| STO-022 | Each directory entry MUST give `path`, `sizeBytes`, `complete`, and the `mountPath` of its volume. | Decode a Storage Report from a fixture pass. Require the four fields on each entry. |
| STO-023 | A `path` in a directory entry or a `notMeasured` item MUST start with `~/` when the directory is inside the user's home directory. Any other `path` MUST be absolute. | Decode a Storage Report that includes a Custom DerivedData Location inside the home directory and one outside it, with `notMeasured` items. Require that every path inside the home starts with `~/` and that no path contains the absolute home directory path. Require that each path outside the home equals its absolute Normalized Path. |
| STO-024 | The Storage Report MUST state the Size Kind in `sizeKind`. | Decode a Storage Report. Require `sizeKind` equal to the value that the ADR fixes. |
| STO-025 | The Storage Report MUST NOT include an entry for a Known Developer Directory that does not exist. | Run a pass with one Known Developer Directory absent. Require no entry for it. |
| STO-026 | An entry MUST set `complete` to `false` when the pass skipped any item of that directory. | Make one fixture subdirectory unreadable. Require `complete: false` for that entry. |
| STO-027 | An entry MUST set `complete` to `false` when the time budget stopped the pass inside that directory. | Use the STO-017 fixture. Require `complete: false` on the interrupted entry. |
| STO-028 | The Storage Report MUST give `measuredAt` and `passSeconds`. | Decode a Storage Report. Require an ISO 8601 `measuredAt` and a non-negative `passSeconds`. |
| STO-029 | The Storage Report MUST order directory entries by `sizeBytes`, largest first. | Run a fixture pass with three directories of known sizes. Require descending order. |
| STO-045 | The Storage Report MUST give `derivedDataLocation` as `default`, `custom`, or `unresolved`. The custom entry or its `notMeasured` item MUST give `source` `"xcode_setting"`. | Inject the Xcode preference as absent, the default path with a trailing `/`, an absolute path, a relative path, a number, and a path with a `..` component. Require `default`, `default`, `custom`, `unresolved`, `unresolved`, and `unresolved`. Require `source` on the custom entry. Require that no report contains the injected relative or `..` value. |
| STO-046 | The Storage Report MUST list each Known Developer Directory that the pass did not measure in `notMeasured`, with `reason`. Each item MUST give `path`, except an item with reason `unresolved_setting`, which MUST NOT give `path`. | Stop a fixture pass at the CPU cap before the last root. Require that root in `notMeasured` with reason `not_reached` and its `path`. Inject a relative Xcode preference value. Require an item with reason `unresolved_setting` and no `path`. |
| STO-050 | The App MUST store the Storage Report in `storage/report.json` and the schedule in `storage/schedule.json` under `AIStatsPaths.home`, each with mode 0600 in a 0700 directory. The App MUST treat an unreadable schedule file or one with an unknown `schemaVersion` as a pass started at App launch. | Run a pass with a fixture `AISTATS_HOME`. Require both paths, mode 0600 on both files, and mode 0700 on the directory. Store a schedule file with `schemaVersion` 99 and launch with a test clock. Require no pass start before six hours after launch, and `schemaVersion` 1 in the schedule file after the next pass starts. |
| STO-051 | The App MUST replace the Storage Report atomically. The report MUST give an integer `schemaVersion`. | Read the report in a loop during 100 passes. Require that every read decodes and gives `schemaVersion` 1. |
| STO-052 | A reader MUST treat a report with an unknown `schemaVersion` as absent. | Store a report with `schemaVersion` 99. Call the tool. Require `storage: null` and reason `unsupported_schema`. |

### Agent access

| ID | Requirement | Acceptance check |
| --- | --- | --- |
| STO-030 | An agent MUST get the Volume List, the Storage Report, and the Drain Rate in one tool call. | Send one `tools/call` request over stdio. Require all three parts in `structuredContent`. |
| STO-031 | The tool result MUST give `ageSeconds` of the Storage Report. | Read a report that is 120 s old with a test clock. Require `ageSeconds` between 120 and 121. |
| STO-032 | When no Storage Report exists, the JSON result MUST give `storage: null` and a reason field. | Remove the stored report. Call the tool. Require `storage: null` and reason `no_report`. |
| STO-033 | When the App does not run, the JSON result MUST give `appRunning: false` and the App start command. | Stop the App. Call the tool. Require `appRunning: false` and a field that contains `open -b` followed by `AIStatsPaths.appBundleIdentifier`. |
| STO-034 | The successful tool result MUST fit the response budget of SDD 0005. | Use a fixture with 32 volumes and every Known Developer Directory present. Measure the compact `structuredContent` size. Require the SDD 0005 limit or less, with omitted counts. |
| STO-035 | The CLI SHOULD print the same result with a `--json` option. | Run the CLI command that the ADR names with `--json`. Compare its JSON with the tool `structuredContent` from the same stored report. |

### Drain Rate

| ID | Requirement | Acceptance check |
| --- | --- | --- |
| STO-036 | The result MUST give `drainBytesPerHour` for the boot volume from recorded history. | Load a history fixture where free space drops 6 GiB in 30 min of Disk Read Time. Require `drainBytesPerHour` equal to 12 GiB within 1%. |
| STO-037 | The Drain Rate MUST give `windowSeconds` and `diskSamples` with the rate. | Decode the STO-036 result. Require both fields and their fixture values. |
| STO-038 | When history has fewer than two disk readings with distinct Disk Read Times, the result MUST give a reason field instead of `drainBytesPerHour`. | Use a history fixture with 15 points that share one Disk Read Time. Require no `drainBytesPerHour` and a JSON reason field. |
| STO-039 | A positive `drainBytesPerHour` MUST mean that free space decreased. | Use one fixture with decreasing free space and one with increasing free space. Require a positive and a negative value. |
| STO-040 | The result MAY give `estimatedSecondsToLowDisk` when free space decreases. | Not applicable. ADR 0010 omits the estimate in v1. |
| STO-047 | Each history point MUST give `diskReadAt` when it gives `diskAvailableBytes`. | Run the App for 70 s with a 30 s slow-metric interval. Require that points share `diskReadAt` until the next disk read, and that at least two distinct values exist. |
| STO-048 | The Drain Rate MUST use the first and last distinct Disk Read Times in the 60 minutes that end at the call time. It MUST ignore points without `diskReadAt`. | Load a fixture with mixed points, with and without `diskReadAt`. Require `windowSeconds` equal to the span of distinct Disk Read Times and `diskSamples` equal to their count. Stop the App. Use persisted history whose last Disk Read Time is 10 min before the call. Require a rate from the points in the window and `appRunning: false`. Move the last Disk Read Time to 61 min before the call. Require no `drainBytesPerHour` and a reason field. |
| STO-049 | `get_stats_history` MUST NOT return `diskReadAt`. | Call `get_stats_history` after the App records points with `diskReadAt`. Require no `diskReadAt` key in `structuredContent`. |

## Non-goals

- Deleting, cleaning, or purging caches, or giving shell commands that delete files.
- Sizes of directories that are not Known Developer Directories, such as project source trees or the full home directory.
- Other users' files and directories that need root access.
- Simulator boot budget or claims. SDD 0016 covers simulator resources.
- Per-device simulator data sizes and UDIDs. This specification reports simulator data only as directory totals.
- A Panel view for the Storage Report. A later revision of SDD 0001 covers Panel changes.
- Real-time file-system event monitoring.

## Dependencies and related specs

- [SDD 0004 · Summary facts in JSON](0004-summary-facts-in-json.md): STO-032 and STO-033 put the App state and start command in JSON.
- [SDD 0005 · Response size budget](0005-response-size-budget.md): STO-034 uses its byte budget.
- [SDD 0007 · Preflight hook](0007-preflight-hook.md): preflight can read the latest Storage Report. STO-014 forbids a Storage Pass from preflight.
- [SDD 0008 · CLI parity](0008-cli-parity.md): STO-035 follows its `--json` and exit-code conventions.
- [SDD 0016 · Simulator resources](0016-simulator-resources.md): SDD 0016 leaves simulator disk use to this specification. This specification covers it as the totals of `CoreSimulator/Devices`, `CoreSimulator/Caches`, and each `* DeviceSupport` directory.
- [SDD 0001 · Cyberpunk Panel](0001-cyberpunk-panel.md): PERF-004 and the Panel disk Warning.

## Open questions

ADR 0010 resolves the allowlist, unreached roots, the APFS container identifier, and the Drain Rate metric. These questions remain:

- Which ADR 0010 roots exist on typical developer Macs, and how long the App walk takes. The only figures are `du` proxies from one Mac.
- The closed-panel App CPU time under a controlled PERF-004 run. The ADR 0010 slice budget and admission threshold are proposals until STO-019 passes.
- Whether any ADR 0010 root causes a privacy consent prompt on macOS 14 or later. STO-003 must verify this before release.
- Whether a `local_other` volume, for example an external local disk, causes a removable-volume consent prompt for the App. Until STO-003 verifies it for a macOS version, ADR 0010 does not walk such volumes.
- Whether a pass started by the App is attributed to the App for privacy consent, and whether the same walk from the Server would be attributed to the agent host. This is an inference, not verified.
- Whether `getfsstat` with `MNT_NOWAIT` returns without blocking for an unresponsive network volume on current macOS. Not verified in this repository. ADR 0010 bounds the pass read with a 200 ms deadline.
- The minimum useful Drain Rate window. The disk value changes at most every 30 s. Not measured.
- Whether a future App Sandbox would block the walk or the Xcode preference read. The current bundle has no sandbox.
