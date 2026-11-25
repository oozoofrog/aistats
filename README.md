# AIStats

A macOS menu bar system monitor whose main users are AI coding agents. The `aistats` binary is an
MCP server (stdio) and a CLI that answer "what is this Mac doing?" in one call, instead of agents running
`ps`, `top`, `lsof`, `sample` and `sleep` loops and reading pages of output.

- **Menu bar app (AIStatsMenu):** CPU, memory, disk and top processes; which agents are connected and
  what they asked recently; one-click registration of the MCP server with each agent. The UI is in Korean.
- **MCP server / CLI (`aistats`):** compact JSON answers (each response aims to stay under 4 KiB).

Requires macOS 14 or later. Only the current user's processes are readable (others need root).

## MCP tools

| Tool | Use it for |
|---|---|
| `diagnose_system` | The Mac feels slow, or before a build/test/heavy job: returns the likely cause (CPU, load average, memory pressure, thermal throttling, low disk, battery) and the busiest processes |
| `get_system_stats` | CPU, memory with pressure and swap, disk, network, battery, thermal state. Pass a returned cursor as `since` for changes |
| `get_top_processes` | Top processes by CPU or memory footprint, with PID, start token and readable parent PID |
| `find_processes` | Look up processes by TCP listening port, pid, executable name or path (exact or glob, optional `argsContain`); returns a `startToken` that guards against pid reuse. Set `includeBaseline: true` for the duration baseline of each row's job (up to 3) |
| `track_processes` | Watch processes in the background for up to 2 hours: CPU and memory min/avg/max/last, lifetime peak footprint, restarts, child spawns per minute and per executable, CPU spikes with busiest threads and an optional `sample` capture. Gives `baseline`, the median, p90 and suggested timeout of past runs of the same job, when earlier tracks or `process_exit` waits saw it exit |
| `wait_for` | Wait (up to 55 s per call) for `cpu_idle`, `process_exit` `memory_pressure_normal`, `process_started`, `disk_free_above` or `port_listening` instead of sleeping; on timeout it says what is still busy |
| `get_environment` | macOS version, chip, RAM, cores, Xcode and Swift versions |
| `get_process_tree` | Rank agent subtrees, shared hosts and unattributed processes by CPU, footprint or disk I/O. Use `aistats tree --sort mem` for a terminal tree. |
| `get_simulator_usage` | CPU (percent of one core), summed footprint and process count for each booted simulator device, keyed by its `launchd_sim` root PID, start token and boot time. Host services are excluded; no UDID, name or owner. Use `aistats sims --json` in a terminal. |
| `get_developer_storage` | Capacity and free space of the boot data volume and Finder-visible volumes, the menu bar app's cached sizes of Xcode, SwiftPM and simulator folders (allocated bytes, measured in the background at most every six hours), and how fast free space on the boot volume dropped in the last hour. Never walks folders itself. Use `aistats storage --json` in a terminal. |
| `get_agent_sessions` | List live sessions, recent calls, and CPU leaders by their nearest agent process. Set `origin: true` for CPU, memory or disk rankings, launch chains and session or ancestor filters |
| `get_orphan_processes` | Live processes that an ended agent session left behind, such as a dev server started by a tool call. Built from parent links the menu bar app records while a session is live (only while the panel is open, unless 패널을 닫아도 계보 기록 is on). Reports coverage start, gaps and the last observation; an empty list covers only the recorded time. Never signals; terminate a process from the app after a confirmation. Use `aistats orphans --json` in a terminal. |
| `get_stats_history` | Trend over the last hour, recording state and recovery hints (recorded by the menu bar app) |

## Build

```sh
swift build -c release            # aistats and AIStatsMenu
swift test                        # unit tests
scripts/bundle.sh                 # /Applications/AIStats.app, ad-hoc signed
AISTATS_SIGN_IDENTITY=<identity SHA-1> scripts/bundle.sh   # signed with that identity
scripts/smoke-mcp.sh /Applications/AIStats.app/Contents/MacOS/aistats   # end-to-end MCP checks
```

## Register with an agent

From the menu bar panel, press 연결 (connect) next to the agent. Or from a terminal:

```sh
aistats status                    # registration state for every agent
aistats install claude-code       # or codex, gemini, claude-desktop, cursor, all
aistats uninstall codex
```

Registration only adds, updates or removes the `aistats` entry in the agent's configuration, through the
agent's own CLI where one exists (Claude Code, Codex, Gemini CLI) or by editing only that member's bytes in
the JSON file (Claude Desktop, Cursor). An `aistats` entry that AIStats did not create is never replaced
unless you confirm that exact entry: `aistats install <agent> --replace <fingerprint>` (the fingerprint is
shown by `aistats status`). A byte-exact backup of the configuration is written before every change.
`aistats install --help` lists exactly what is changed.

Data, including those backups, lives in `$AISTATS_HOME`, or `~/Library/Application Support/AIStats` by
default. Job duration baselines live in its `durations` folder: each run is stored as a keyed hash of the
executable path and a fixed build or test subcommand, its duration and exit time, never as command text.
Lineage records for the orphan report live in its `lineage` folder: pid, start token, executable name, agent
identity, session name and times, never arguments, environment values, working directories or paths.

## CLI

```sh
aistats find --name Xcode --json
aistats diagnose --purpose heavy_work
aistats env --no-toolchain
aistats wait disk_free_above --above-gib 10
aistats preflight --json          # fast readiness check before heavy work
aistats stats                     # one-shot system summary
aistats top --sort memory --limit 10
aistats sims --json               # CPU and memory per booted simulator device
aistats storage --json            # volume free space, developer folder sizes, drain rate
aistats orphans --json            # live processes left by ended agent sessions (read-only)
aistats track --name Xcode --children --duration 60 --spike-cpu 200
aistats find --pid 1234 --include-baseline   # past run durations of that process's job
aistats baselines clear           # delete recorded job durations and replace their signature key
aistats --help
```

## License

MIT. See [LICENSE](LICENSE).
