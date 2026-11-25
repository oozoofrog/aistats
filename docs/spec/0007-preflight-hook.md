# SDD 0007 · Preflight Hook

Status · Proposed
Issue · [#6](https://github.com/oozoofrog/aistats/issues/6)

## Purpose and scope

This specification adds the `aistats preflight` CLI command. An agent hook runs the command before a heavy shell command, such as a build or a test run. The command reads instantaneous load signals of the Mac. It prints nothing when the Mac is ready. It prints a short caution in the hook output format of the agent when a signal crosses a threshold. The agent then decides whether to wait, to diagnose, or to continue.

The scope is the command, its output formats, its latency budget, its exit statuses, and an optional `aistats install claude-code --hooks` registration. The command never blocks or cancels the agent's command. Gemini CLI and Cursor have no confirmed non-blocking channel that adds context for the model before execution, so this specification gives them no hook output.

The key words "MUST", "MUST NOT", "SHOULD", "SHOULD NOT", and "MAY" in this document are to be interpreted as described in BCP 14 [RFC2119] [RFC8174] when, and only when, they appear in all capitals.

[RFC2119]: https://www.rfc-editor.org/rfc/rfc2119.html
[RFC8174]: https://www.rfc-editor.org/rfc/rfc8174.html

## Terms

| Term | Meaning |
| --- | --- |
| Preflight | One run of `aistats preflight`. |
| Hook | An agent-configured command that the agent runs before a tool call. Claude Code and Codex call this event `PreToolUse`. |
| Agent Mode | A Preflight with the `--agent` option. Its stdout is for the agent's hook runner. |
| Signal | One reading in Table 1. |
| Caution Signal | A Signal whose reading meets the Table 1 condition. |
| App Sample | The newest history point that the AIStats app recorded, when it is less than 15 seconds old. |
| Readiness | The Preflight verdict: `ready`, `caution`, or `unknown`. The values match `diagnose_system` readiness. |
| Context Text | The `additionalContext` string in Agent Mode output. |
| Hook Input | The JSON object that the agent writes to the stdin of a Hook. |

## Background and evidence

| Fact | Evidence |
| --- | --- |
| The CLI has no preflight command. The commands are stats, top, history, agents, mcp, status, install, uninstall, track, and setup. | [main.swift:4](../../Sources/aistats/main.swift#L4) to [main.swift:28](../../Sources/aistats/main.swift#L28) |
| `diagnose_system` measures for 1.0 s with two samples. A hook cannot afford this before every matched command. | [Diagnosis.swift:101](../../Sources/StatsCore/Diagnosis.swift#L101) to [Diagnosis.swift:107](../../Sources/StatsCore/Diagnosis.swift#L107), [SystemSampler.swift:48](../../Sources/StatsCore/SystemSampler.swift#L48) to [SystemSampler.swift:52](../../Sources/StatsCore/SystemSampler.swift#L52) |
| The first CPU tick reading only primes the counters. A single sample cannot give a CPU percentage. | [SystemSampler.swift:121](../../Sources/StatsCore/SystemSampler.swift#L121) to [SystemSampler.swift:122](../../Sources/StatsCore/SystemSampler.swift#L122) |
| The diagnosis thresholds are CPU 85%, load average 2× logical cores, free disk 10 GiB, and battery 20%. | [Diagnosis.swift:28](../../Sources/StatsCore/Diagnosis.swift#L28) to [Diagnosis.swift:33](../../Sources/StatsCore/Diagnosis.swift#L33) |
| Memory pressure warning or critical, and thermal state serious or critical, are evidence in the diagnosis. Swap is reported only in the memory pressure detail. | [Diagnosis.swift:61](../../Sources/StatsCore/Diagnosis.swift#L61) to [Diagnosis.swift:72](../../Sources/StatsCore/Diagnosis.swift#L72) |
| Heavy work readiness is `ready`, `caution`, or `unknown`. A missing reading never counts as fine. | [Diagnosis.swift:89](../../Sources/StatsCore/Diagnosis.swift#L89) to [Diagnosis.swift:94](../../Sources/StatsCore/Diagnosis.swift#L94) |
| Memory pressure is one `sysctl` read. Load average is one `getloadavg` call. The current sampler ignores a `getloadavg` failure. | [SystemSampler.swift:183](../../Sources/StatsCore/SystemSampler.swift#L183) to [SystemSampler.swift:193](../../Sources/StatsCore/SystemSampler.swift#L193), [SystemSampler.swift:113](../../Sources/StatsCore/SystemSampler.swift#L113) to [SystemSampler.swift:114](../../Sources/StatsCore/SystemSampler.swift#L114) |
| A history point holds CPU, memory, memory pressure, network, free disk, and battery. It holds no load average, thermal state, or swap. | [Store.swift:111](../../Sources/StatsCore/Store.swift#L111) to [Store.swift:121](../../Sources/StatsCore/Store.swift#L121) |
| The app is "not recording" when its newest point is 15 s old or older. | [Store.swift:142](../../Sources/StatsCore/Store.swift#L142), [Store.swift:162](../../Sources/StatsCore/Store.swift#L162) to [Store.swift:165](../../Sources/StatsCore/Store.swift#L165) |
| `HistoryStore.latest()` decodes the whole history file to return its last point. | [Store.swift:158](../../Sources/StatsCore/Store.swift#L158) to [Store.swift:160](../../Sources/StatsCore/Store.swift#L160) |
| The CLI exits with status 1 on every error and writes `aistats: <message>` to stderr. | [main.swift:184](../../Sources/aistats/main.swift#L184) to [main.swift:189](../../Sources/aistats/main.swift#L189) |
| `aistats setup` prints registration commands only. | [main.swift:155](../../Sources/aistats/main.swift#L155) to [main.swift:171](../../Sources/aistats/main.swift#L171) |
| Registration changes only the `aistats` entry of a target config and backs it up first (guarantees G1 to G4). | [AgentRegistration.swift:7](../../Sources/StatsCore/AgentRegistration.swift#L7) to [AgentRegistration.swift:30](../../Sources/StatsCore/AgentRegistration.swift#L30) |

Agent hook behavior, from the official agent documentation (fetched 2026-11-21):

- Claude Code: plain stdout of a `PreToolUse` hook does not reach the model. The non-blocking channel is `{"hookSpecificOutput":{"hookEventName":"PreToolUse","additionalContext":"..."}}`. A handler can carry an `if` filter such as `Bash(xcodebuild *)`. Hook output is capped at 10,000 characters. A `PreToolUse` hook that times out does not block. Exit status 2 from a `PreToolUse` command hook blocks the tool call.
- Codex CLI: hooks are on by default. Plain stdout of `PreToolUse` is ignored. `hookSpecificOutput.additionalContext` is supported, with a cap of about 2,500 tokens.
- Gemini CLI: plain output of `BeforeTool` goes to the user only. No non-blocking pre-execution context channel exists. `AfterTool` has `additionalContext`.
- Cursor: non-JSON output of `beforeShellExecution` blocks the command. No confirmed non-blocking pre-execution channel for model context exists.

A synchronous Hook runs before every matched command. Its run time adds to each of those commands.

### Table 1 · Signals

Thresholds equal the `diagnose_system` thresholds, so Preflight and `diagnose_system` agree on the same readings.

| Signal (`metric`) | Source | Caution condition | Unit |
| --- | --- | --- | --- |
| `loadAverage` | 1-minute load average from `getloadavg` | at or above 2 × logical cores | runnable threads |
| `memoryPressure` | kernel memory pressure level | `warning` or `critical` | level (1 warning, 2 critical) |
| `thermal` | `ProcessInfo` thermal state | `serious` or `critical` | level (2 serious, 3 critical) |
| `diskFree` | free space for important usage on `/`; free blocks if that value is unreadable | below 10 GiB | bytes |
| `battery` | internal battery, on battery power and not charging | below 20% | percent |
| `cpu` | `cpuPercent` of the App Sample | at or above 85% | percent of all cores |

The `memoryPressure` detail also states swap used, as the diagnosis does. Swap alone is not a Caution Signal.

## Requirements

### Command and measurement

| ID | Requirement | Acceptance check |
| --- | --- | --- |
| PRE-001 | The CLI MUST provide `aistats preflight [--agent claude-code\|codex] [--json]`. | Run `aistats help`. Verify that the usage lists the command and both options. Run each option form and verify that each one completes. |
| PRE-002 | Preflight MUST evaluate only the Signals in Table 1 with the Table 1 conditions. | Unit test with fixture readings just below and at each threshold. Compare each Caution Signal with `Diagnosis.make` evidence for the same readings. |
| PRE-003 | Preflight MUST NOT take a two-sample CPU measurement. | Unit test with a sampler spy. Verify zero calls to `measure(interval:)` and zero sleeps. |
| PRE-004 | Preflight MUST NOT start a subprocess. | Inspect the call graph from the command entry point. Verify that no path reaches `Subprocess.run` or `Process`. |
| PRE-005 | Each Preflight MUST finish within 200 ms wall time. | Run the release binary 20 times in a loop with `--agent claude-code` and a sample Hook Input on stdin. Use the release check Mac with the AIStats app running. Record each wall time. Verify that the maximum is below 200 ms. |
| PRE-006 | The median Preflight wall time SHOULD be below 100 ms. | Use the 20 runs from PRE-005. Report the median. |
| PRE-007 | Preflight MUST read the `cpu` Signal only from an App Sample. | Unit test with a fixture history file. A point 10 s old with `cpuPercent` 90 gives a `cpu` Caution Signal. A point 20 s old gives `cpu` in `unavailable`. |
| PRE-008 | Preflight MUST report an unreadable Signal as unavailable, never as a reading of 0. | Unit test with injected failures for each Signal, including a failed `getloadavg`. Verify that the metric is in `unavailable` and not in `signals`. |
| PRE-009 | Preflight MUST work without the AIStats app and without an MCP session. | Set `AISTATS_HOME` to a new empty folder. Make sure that the app is not running. Verify a normal result with `cpu` in `unavailable`. |
| PRE-010 | Readiness MUST be `caution` when at least one Caution Signal exists. | Unit test with one Caution Signal and other Signals unreadable. Verify `caution`. |
| PRE-011 | Readiness MUST be `ready` only when no Caution Signal exists and `loadAverage`, `memoryPressure`, and `diskFree` are readable. | Unit test each of the three Signals unreadable with no Caution Signal. Verify `unknown` each time. Verify `ready` when all three are readable. |

### Agent Mode output

| ID | Requirement | Acceptance check |
| --- | --- | --- |
| PRE-012 | In Agent Mode, Preflight MUST exit with status 0 on every path. | Run with each of: healthy fixture, caution fixture, malformed Hook Input, unknown option, unknown `--agent` value, and an unwritable data folder. Verify status 0 each time. |
| PRE-013 | In Agent Mode, Preflight MUST write error text to stderr only. | Use the error runs of PRE-012. Verify empty stdout and a nonempty stderr line that starts with `aistats: `. |
| PRE-014 | In Agent Mode, Preflight MUST write nothing to stdout when Readiness is `ready` or `unknown`. | Run with healthy and with insufficient fixtures. Verify 0 bytes on stdout with `wc -c`. |
| PRE-015 | With `--agent claude-code` and Readiness `caution`, stdout MUST be one JSON object in the Table 2 shape. | Parse stdout with a strict JSON parser. Compare the complete key set with Table 2. Verify one trailing newline at most and no other bytes. |
| PRE-016 | With `--agent codex` and Readiness `caution`, stdout MUST be one JSON object in the Table 2 shape. | As PRE-015, with `--agent codex`. |
| PRE-017 | Agent Mode output MUST NOT contain a permission decision or a stop instruction. | Verify that stdout has no `permissionDecision`, `decision`, `continue`, `stopReason`, or `suppressOutput` key at any depth. |
| PRE-018 | The `--agent` option MUST accept only `claude-code` and `codex`. | Run with `--agent antigravity`, `--agent cursor`, and `--agent claude-desktop`. Verify empty stdout, status 0, and a stderr message that names the missing non-blocking pre-execution channel. |
| PRE-019 | The Context Text MUST be at most 512 bytes in UTF-8. | Fixture with all six Signals in caution and a 255-byte mount path. Measure the Context Text. |
| PRE-020 | The Context Text MUST name each Caution Signal with its observed value and its threshold. | Fixture per Signal. Verify the metric name, the value, and the threshold in the text. |
| PRE-021 | The Context Text MUST name `wait_for` and `aistats wait` as options before heavy work. | Substring check on a caution fixture. |
| PRE-022 | The Context Text MUST name `diagnose_system` and `aistats diagnose` as the way to find the busy processes. | Substring check on a caution fixture. |
| PRE-023 | The Context Text MUST NOT tell the agent to cancel or skip its command. | Review the text of every caution fixture. Verify that waiting and diagnosing are stated as options. |

### Table 2 · Agent Mode output

`TEXT` is the Context Text. Codex uses the same shape (see Open questions).

```json
{"hookSpecificOutput":{"hookEventName":"PreToolUse","additionalContext":"TEXT"}}
```

### Hook Input and repetition

| ID | Requirement | Acceptance check |
| --- | --- | --- |
| PRE-024 | Preflight MUST NOT read stdin when stdin is a terminal. | Run `aistats preflight --agent claude-code` in an interactive terminal. Verify that it returns within the PRE-005 budget without input. |
| PRE-025 | Preflight MUST read at most 64 KiB of Hook Input. | Pipe 1 MiB of data. Verify completion within PRE-005 and status 0. |
| PRE-026 | Preflight MUST stop reading Hook Input when the PRE-005 budget would otherwise be exceeded. | Hold stdin open with no data and no end of file. Verify that the command finishes within 200 ms. |
| PRE-027 | In Agent Mode, Preflight SHOULD suppress output when it emitted the same Caution Signal set for the same session in the last 300 s. | Send the same Hook Input with a `session_id` twice within 300 s. Verify empty stdout the second time. Change the Caution Signal set and verify output. Use another `session_id` and verify output. |
| PRE-028 | Without a session id in the Hook Input, Preflight MUST NOT suppress output. | Send Hook Input without `session_id` twice. Verify output both times. |
| PRE-029 | Preflight MUST store suppression state only in the AIStats data folder, with file mode 0600. | Inspect the files after PRE-027. Verify their location under `AISTATS_HOME` and their mode. |

### Human and script output

| ID | Requirement | Acceptance check |
| --- | --- | --- |
| PRE-030 | Without `--agent` and `--json`, Preflight MUST print one summary line, then one line per Caution Signal. | Run with healthy and caution fixtures. Verify the first line states the Readiness. |
| PRE-031 | With `--json` and without `--agent`, stdout MUST be one JSON object with the Table 3 fields. | Decode stdout. Verify the field names and types in Table 3. |
| PRE-032 | Without `--agent`, the exit status MUST be 0 for `ready`, 3 for `caution`, 4 for `unknown`, and 1 for an error. | Run each fixture and one invalid option. Verify each status. These values follow the exit status table of [SDD 0008](0008-cli-parity.md). |

### Table 3 · `--json` fields

| Field | Type | Meaning |
| --- | --- | --- |
| `readiness` | string | `ready`, `caution`, or `unknown`. |
| `signals` | array | Caution Signals. Each item has `metric`, `observed`, `threshold`, `unit`, and `detail`, as `diagnose_system` evidence. |
| `unavailable` | array of string | Table 1 metrics that could not be read. Absent when empty. |
| `cpuSource` | string | `app_sample` or `none`. |
| `observedAt` | string | ISO 8601 time of the reading. |
| `elapsedMs` | number | Wall time of the Preflight measurement in milliseconds. |

### Hook registration

| ID | Requirement | Acceptance check |
| --- | --- | --- |
| PRE-033 | `aistats setup` SHOULD print a Claude Code hook configuration snippet that runs Preflight in Agent Mode. | Run `aistats setup`. Parse the printed snippet as JSON. Verify the `PreToolUse` event, the `Bash` matcher, and the `--agent claude-code` option. |
| PRE-034 | The CLI MAY provide `aistats install claude-code --hooks` and `aistats uninstall claude-code --hooks`. | Not applicable when absent. When present, apply PRE-035 to PRE-039. |
| PRE-035 | `install --hooks` MUST change only the hook handler whose command runs this binary with `preflight`. | Use a disposable Claude Code config folder with other hooks and settings. Compare every byte outside the AIStats handler before and after the change. |
| PRE-036 | `install --hooks` MUST write a byte-exact backup of the settings file before a change. | Verify a backup under `AISTATS_HOME/backups/` whose SHA-256 equals the original file. |
| PRE-037 | Each installed handler MUST run Preflight with `--agent claude-code` and an `if` filter for one heavy command pattern. | Inspect the written handler. Compare the patterns with the agreed default list (see Open questions). |
| PRE-038 | `uninstall --hooks` MUST remove only the AIStats handler. | Install, add an unrelated handler by hand, then uninstall. Verify that the unrelated handler and all other bytes remain. |
| PRE-039 | `install --hooks` MUST fail with status 1 for `codex`, `antigravity`, `claude-desktop`, and `cursor`. | Run each. Verify status 1, an unchanged config, and a message that names the reason. |

## Non-goals

- Blocking, delaying, or rewriting the agent's command.
- Hook output for Gemini CLI `BeforeTool` or Cursor `beforeShellExecution`.
- `install --hooks` for Codex. Its hook config format is not verified.
- Busy process names in the Context Text. A per-process CPU percentage needs two samples.
- Changes to the `diagnose_system` thresholds.
- Records of Preflight runs in the agents activity log or the app's recent calls.

## Dependencies and related specs

- [SDD 0008 · CLI Parity](0008-cli-parity.md) defines `aistats wait`, `aistats diagnose`, and the exit status table. The Context Text names these commands.
- [SDD 0006 · wait_for conditions](0006-wait-for-conditions.md) defines the wait conditions that the Context Text recommends.
- [SDD 0005 · Response size budget](0005-response-size-budget.md) does not apply. Preflight is not an MCP tool.
- Registration guarantees G1 to G4 in `AgentRegistration.swift` cover only the `aistats` MCP entry. An ADR SHOULD extend them to the Claude Code settings file before PRE-034 is implemented.

## Open questions

- Latency is not measured. The unknown costs are process launch of the release binary, the decode of the full history file by `HistoryStore.latest()` (up to 3,600 lines between compactions), and the battery read through IOKit.
- Codex `hookEventName`, its tool name for shell commands, and its matcher syntax are not verified. Codex hook exit status semantics are not verified.
- Whether Codex Hook Input carries a session id is not verified. Claude Code Hook Input carries `session_id`.
- The default heavy command pattern list for PRE-037 is not decided. A proposal: `xcodebuild *`, `swift build*`, `swift test*`, `cargo build*`, `cargo test*`, `npm run build*`, `pnpm build*`, `gradle*`, `./gradlew*`, `make*`.
- The 300 s suppression window in PRE-027 is a proposal. No usage data supports it.
- The 200 ms budget in PRE-005, the 100 ms median in PRE-006, and the 512-byte Context Text limit in PRE-019 are proposals. No measurement supports them.
- Whether Cursor treats empty stdout from `beforeShellExecution` as a pass is not verified.
- Whether a user-only message for Gemini CLI `BeforeTool` is useful is not decided.
