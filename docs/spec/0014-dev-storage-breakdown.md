# SDD 0014 · Developer Storage Breakdown

Status · Proposed
Issue · [#13](https://github.com/oozoofrog/aistats/issues/13)
Proposed decision · [ADR 0010 · Measure a fixed set of developer directories in the app](../adr/0010-storage-accounting.md)

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

## Background and evidence

| Fact | Source |
| --- | --- |
| The sampler reads one volume only. The default path is `/`. | [SystemSampler.swift:42](../../Sources/StatsCore/SystemSampler.swift#L42), [SystemSampler.swift:197](../../Sources/StatsCore/SystemSampler.swift#L197) |
| A disk reading contains `mountPath`, `totalBytes`, `availableBytes`, and the optional `availableForImportantUsageBytes`. | [Snapshot.swift:67](../../Sources/StatsCore/Snapshot.swift#L67) |
| `availableBytes` comes from `statfs` free blocks. `availableForImportantUsageBytes` comes from the volume resource key and includes purgeable data. | [SystemSampler.swift:202](../../Sources/StatsCore/SystemSampler.swift#L202), [SystemSampler.swift:207](../../Sources/StatsCore/SystemSampler.swift#L207) |
| `diagnose_system` compares `availableForImportantUsageBytes`, or `availableBytes` when that is absent, with the 10 GiB threshold. The Panel Warning compares `availableBytes` with the same threshold. | [Diagnosis.swift:29](../../Sources/StatsCore/Diagnosis.swift#L29), [Diagnosis.swift:74](../../Sources/StatsCore/Diagnosis.swift#L74), [PanelData.swift:16](../../Sources/AIStatsMenu/PanelData.swift#L16), [PanelData.swift:26](../../Sources/AIStatsMenu/PanelData.swift#L26) |
| The App refreshes every 2 s and rereads disk and battery at most every 30 s. | [AppModel.swift:35](../../Sources/AIStatsMenu/AppModel.swift#L35), [AppModel.swift:36](../../Sources/AIStatsMenu/AppModel.swift#L36), [SystemSampler.swift:68](../../Sources/StatsCore/SystemSampler.swift#L68) |
| The App records one history point per refresh. Each point stores `diskAvailableBytes` from `availableBytes`. | [AppModel.swift:177](../../Sources/AIStatsMenu/AppModel.swift#L177), [Store.swift:120](../../Sources/StatsCore/Store.swift#L120), [Store.swift:132](../../Sources/StatsCore/Store.swift#L132) |
| History keeps 1,800 points, which is one hour at the 2 s cadence. History exists only while the App runs. | [Store.swift:140](../../Sources/StatsCore/Store.swift#L140), [Store.swift:142](../../Sources/StatsCore/Store.swift#L142) |
| `get_stats_history` already returns `diskAvailableChangeBytes` for the window, but no rate and no window-independent figure. | [Store.swift:188](../../Sources/StatsCore/Store.swift#L188), [Store.swift:203](../../Sources/StatsCore/Store.swift#L203) |
| When the App does not record, `get_stats_history` puts the start command only in the summary text. | [MCPServer.swift:450](../../Sources/StatsCore/MCPServer.swift#L450), [MCPServer.swift:452](../../Sources/StatsCore/MCPServer.swift#L452) |
| The App runs sampling and store work on utility-QoS queues. | [AppModel.swift:66](../../Sources/AIStatsMenu/AppModel.swift#L66), [AppModel.swift:67](../../Sources/AIStatsMenu/AppModel.swift#L67) |
| Store files use mode 0600 in a 0700 directory under `$AISTATS_HOME`. | [Store.swift:6](../../Sources/StatsCore/Store.swift#L6), [Store.swift:54](../../Sources/StatsCore/Store.swift#L54), [Store.swift:87](../../Sources/StatsCore/Store.swift#L87) |
| The closed-panel App has a mean CPU budget below 1% over 60 s. | [0001-cyberpunk-panel.md](0001-cyberpunk-panel.md) PERF-004 |
| The app bundle is ad-hoc signed without entitlements. | [bundle.sh:32](../../scripts/bundle.sh#L32) |
| No CLI command or MCP tool reports more than one volume or any directory size. | [main.swift:4](../../Sources/aistats/main.swift#L4), [MCPServer.swift:318](../../Sources/StatsCore/MCPServer.swift#L318) |

Agents that run builds need to know where disk space goes before a large build, an archive, or a simulator install. Today an agent runs `df` and `du` through a shell. `du` over a large build cache can run for a long time and block the agent turn. The Server runs once for each agent session, so a directory walk in the Server would repeat for every session. The App runs once per user, so the App is the single place to measure.

Candidate Known Developer Directories (the ADR fixes the set; existence on a given Mac is not verified): `~/Library/Developer/Xcode/DerivedData`, `~/Library/Developer/Xcode/Archives`, `~/Library/Developer/Xcode/*DeviceSupport`, `~/Library/Developer/CoreSimulator/Devices`, `~/Library/Developer/CoreSimulator/Caches`, `~/Library/Caches/org.swift.swiftpm`, `~/.npm`, `~/Library/Caches/Yarn`, `~/Library/pnpm`, `~/.gradle/caches`, `~/Library/Caches/CocoaPods`, `~/Library/Caches/Homebrew`, `~/.cargo/registry`, and `~/go/pkg/mod`.

## Requirements

### Safety and scope

| ID | Requirement | Acceptance check |
| --- | --- | --- |
| STO-001 | AIStats MUST NOT delete, move, rename, modify, or purge any measured file or directory. | Create a fixture tree with known content and modification times. Run three Storage Passes. Compare a recursive manifest of paths, sizes, modes, and modification times before and after. Require no difference. |
| STO-002 | A Storage Pass MUST measure only Known Developer Directories and their contents. | Run a Storage Pass alone in a test process with a file-access trace (`fs_usage -f filesys` filtered to that process). Require that every opened or stat-read path is inside a Known Developer Directory or the AIStats home. |
| STO-003 | A Storage Pass MUST NOT cause a macOS privacy consent prompt. | Reset privacy permissions for the App bundle identifier with `tccutil reset All`. Run a Storage Pass on macOS 14 and the current test macOS. Require no consent prompt and no new entry in Privacy & Security settings. |
| STO-004 | A Storage Pass MUST NOT follow symbolic links. | Put a symbolic link loop and a link to a 1 GiB fixture inside a measured fixture directory. Require that the pass ends and the reported size excludes the 1 GiB target. |
| STO-005 | A Storage Pass MUST NOT cross into another mounted volume. | Mount a disk image inside a measured fixture directory. Require that the reported size excludes the content of the disk image. |
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
| STO-013 | The Server MAY build the Volume List during the tool call. | Not applicable. The Volume List needs no directory walk. |

### Storage Pass

| ID | Requirement | Acceptance check |
| --- | --- | --- |
| STO-014 | The Server and the CLI MUST NOT run a Storage Pass. | Call every Server tool and CLI command with a file-access trace. Require that no Server or CLI process enumerates a Known Developer Directory. |
| STO-015 | The App MUST run a Storage Pass off the main thread at utility or background quality of service. | Record a Storage Pass with Instruments or a signpost trace. Require that the directory walk has no main-thread samples and runs at utility QoS or lower. |
| STO-016 | A Storage Pass MUST NOT delay the 2 s metric refresh by more than 100 ms. | Record refresh timestamps during a Storage Pass over a fixture with one million files. Require every interval between 1.9 s and 2.1 s. |
| STO-017 | A Storage Pass MUST stop when it exceeds the wall-time budget that the ADR fixes. | Use a test clock and a fixture that takes longer than the budget. Require that the pass ends at the budget and stores a Storage Report. |
| STO-018 | A Storage Pass MUST stay within the CPU-time budget that the ADR fixes. | Measure App CPU time with `proc_pid_rusage` across one pass over the fixture. Require the CPU time at or below the budget. |
| STO-019 | Outside a Storage Pass, the App MUST continue to meet PERF-004 of SDD 0001. | Run the PERF-004 CPU check in a 60 s window that contains no Storage Pass. Require `mean < 1.0`. |
| STO-020 | The App MUST NOT start Storage Passes more often than the interval that the ADR fixes. | Run the App for three intervals with a test clock. Count started passes. Require at most one pass per interval. |
| STO-021 | The App SHOULD defer a Storage Pass on battery power, in Low Power Mode, or at thermal state serious or critical. | Simulate each condition with an injected power and thermal source. Require no pass start while the condition holds. |

### Storage Report content

| ID | Requirement | Acceptance check |
| --- | --- | --- |
| STO-022 | Each directory entry MUST give `path`, `sizeBytes`, `complete`, and the `mountPath` of its volume. | Decode a Storage Report from a fixture pass. Require the four fields on each entry. |
| STO-023 | A directory `path` MUST start with `~/` when the directory is inside the user's home directory. | Decode a Storage Report. Require no entry that contains the absolute home directory path or the user name. |
| STO-024 | The Storage Report MUST state the Size Kind in `sizeKind`. | Decode a Storage Report. Require `sizeKind` equal to the value that the ADR fixes. |
| STO-025 | The Storage Report MUST NOT include an entry for a Known Developer Directory that does not exist. | Run a pass with one Known Developer Directory absent. Require no entry for it. |
| STO-026 | An entry MUST set `complete` to `false` when the pass skipped any item of that directory. | Make one fixture subdirectory unreadable. Require `complete: false` for that entry. |
| STO-027 | An entry MUST set `complete` to `false` when the time budget stopped the pass inside that directory. | Use the STO-017 fixture. Require `complete: false` on the interrupted entry. |
| STO-028 | The Storage Report MUST give `measuredAt` and `passSeconds`. | Decode a Storage Report. Require an ISO 8601 `measuredAt` and a non-negative `passSeconds`. |
| STO-029 | The Storage Report MUST order directory entries by `sizeBytes`, largest first. | Run a fixture pass with three directories of known sizes. Require descending order. |

### Agent access

| ID | Requirement | Acceptance check |
| --- | --- | --- |
| STO-030 | An agent MUST get the Volume List, the Storage Report, and the Drain Rate in one tool call. | Send one `tools/call` request over stdio. Require all three parts in `structuredContent`. |
| STO-031 | The tool result MUST give `ageSeconds` of the Storage Report. | Read a report that is 120 s old with a test clock. Require `ageSeconds` between 120 and 121. |
| STO-032 | When no Storage Report exists, the JSON result MUST give `storage: null` and a reason field. | Remove the stored report. Call the tool. Require `storage: null` and a JSON reason field. |
| STO-033 | When the App does not run, the JSON result MUST give `appRunning: false` and the App start command. | Stop the App. Call the tool. Require `appRunning: false` and a field that contains `open -b` followed by `AIStatsPaths.appBundleIdentifier`. |
| STO-034 | The successful tool result MUST fit the response budget of SDD 0005. | Use a fixture with 32 volumes and every Known Developer Directory present. Measure the compact `structuredContent` size. Require the SDD 0005 limit or less, with omitted counts. |
| STO-035 | The CLI SHOULD print the same result with a `--json` option. | Run the CLI command that the ADR names with `--json`. Compare its JSON with the tool `structuredContent` from the same stored report. |

### Drain Rate

| ID | Requirement | Acceptance check |
| --- | --- | --- |
| STO-036 | The result MUST give `drainBytesPerHour` for the boot volume from recorded history. | Load a history fixture where free space drops 6 GiB in 30 min. Require `drainBytesPerHour` equal to 12 GiB within 1%. |
| STO-037 | The Drain Rate MUST give `windowSeconds` and `diskSamples` with the rate. | Decode the STO-036 result. Require both fields and their fixture values. |
| STO-038 | When history has fewer than two disk readings, the result MUST give a reason field instead of `drainBytesPerHour`. | Use a history fixture with one disk reading. Require no `drainBytesPerHour` and a JSON reason field. |
| STO-039 | A positive `drainBytesPerHour` MUST mean that free space decreased. | Use one fixture with decreasing free space and one with increasing free space. Require a positive and a negative value. |
| STO-040 | The result MAY give `estimatedSecondsToLowDisk` when free space decreases. | Not applicable. If present, check it against the Low Disk Threshold and the fixture rate. |

## Non-goals

- Deleting, cleaning, or purging caches, or giving shell commands that delete files.
- Sizes of directories that are not Known Developer Directories, such as project source trees or the full home directory.
- Other users' files and directories that need root access.
- Simulator boot budget or claims. SDD 0016 covers simulator resources.
- A Panel view for the Storage Report. A later revision of SDD 0001 covers Panel changes.
- Real-time file-system event monitoring.

## Dependencies and related specs

- [SDD 0004 · Summary facts in JSON](0004-summary-facts-in-json.md): STO-032 and STO-033 put the App state and start command in JSON.
- [SDD 0005 · Response size budget](0005-response-size-budget.md): STO-034 uses its byte budget.
- [SDD 0007 · Preflight hook](0007-preflight-hook.md): preflight can read the latest Storage Report. STO-014 forbids a Storage Pass from preflight.
- [SDD 0008 · CLI parity](0008-cli-parity.md): STO-035 follows its `--json` and exit-code conventions.
- [SDD 0016 · Simulator resources](0016-simulator-resources.md): simulator data folders appear here only as directory sizes.
- [SDD 0001 · Cyberpunk Panel](0001-cyberpunk-panel.md): PERF-004 and the Panel disk Warning.

## Open questions

- Which candidate directories exist on typical developer Macs, and how long a pass over each takes. No measurement exists.
- Whether any candidate directory under `~/Library` causes a privacy consent prompt on macOS 14 or later. Not verified.
- Whether a pass started by the App is attributed to the App for privacy consent, and whether the same walk from the Server would be attributed to the agent host. This is an inference, not verified.
- Whether `getfsstat` with `MNT_NOWAIT` returns without blocking for an unresponsive network volume on current macOS. Not verified in this repository.
- How the Storage Report shows Known Developer Directories that an interrupted pass did not reach, for example by omission count or by values from the previous pass. Not decided.
- How to show that several volumes share one APFS container, so that agents do not add their free space. Not decided.
- Whether the Drain Rate should use `availableBytes` (what history stores) or `availableForImportantUsageBytes` (what `diagnose_system` uses). History stores only `availableBytes` today.
- The disk value in history changes at most every 30 s. The minimum useful Drain Rate window is not measured.
- Whether a future App Sandbox would block the walk. The current bundle has no sandbox.
