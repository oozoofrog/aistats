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
| `get_system_stats` | CPU, memory with pressure and swap, disk, network, battery, thermal state |
| `get_top_processes` | Top processes by CPU or memory footprint |
| `find_processes` | Look up processes by pid, executable name or path (exact or glob, optional `argsContain`); returns a `startToken` that guards against pid reuse |
| `track_processes` | Watch processes in the background for up to 2 hours: CPU and memory min/avg/max/last, lifetime peak footprint, restarts, child spawns per minute and per executable, CPU spikes with busiest threads and an optional `sample` capture |
| `wait_for` | Wait (up to 55 s per call) for `cpu_idle`, `process_exit` or `memory_pressure_normal` instead of sleeping; on timeout it says what is still busy |
| `get_environment` | macOS version, chip, RAM, cores, Xcode and Swift versions |
| `get_stats_history` | Trend over the last hour (recorded by the menu bar app) |

## Build

```sh
swift build -c release            # aistats and AIStatsMenu
swift test                        # unit tests
scripts/bundle.sh                 # dist/AIStats.app, ad-hoc signed
scripts/smoke-mcp.sh dist/AIStats.app/Contents/MacOS/aistats   # end-to-end MCP checks
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
default.

## CLI

```sh
aistats stats                     # one-shot system summary
aistats top --sort memory --limit 10
aistats track --name Xcode --children --duration 60 --spike-cpu 200
aistats --help
```

## License

MIT. See [LICENSE](LICENSE).
