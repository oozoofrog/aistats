# ADR 0011 · Derive local duration baselines from observed track exits

Status: Proposed

## Context

[SDD 0015](../spec/0015-job-duration-baselines.md) needs repeated uncensored durations. A wait measures time after attachment and a track can stop while a process continues.

## Decision drivers

Protect command arguments, bound the store, and disclose timing precision. Keep baseline lookup independent of starting another track.

## Considered options

Hashing a command line groups subcommands precisely but requires collecting secrets. Grouping only by basename conflates unrelated installations. Measuring each wait conflates wait length with run length.

## Decision

Compute HMAC-SHA256 of the resolved executable path using an installation-local random key. Persist the digest and a bounded basename label. Exclude arguments, working directory, user identity and toolchain version from the signature. Compute the label from the current lookup when storing it would reveal the account name.

Record only observed exits of root instances in MCP and CLI tracks. Compute duration from the process instance start, and keep exit resolution. Deduplicate by instance and start token across recorders. Discard live, cancelled and interrupted observations. Keep no censored records and exclude them from the sample count. Include observed exits of jobs with unknown exit status. Track tick work enqueues records for a serialized writer.

Use versioned JSON Lines with a stable separate interprocess lock and atomic compaction. Keep the newest 64 runs per signature, 128 most recently used signatures and 30 days. Store files with mode 0600 under the private app data directory. Skip malformed records. Require five completed runs before giving median, nearest-rank p90, maximum and last exit time. For an even count average the middle pair for the median. Suggest ceil(1.25 × p90), clamped to 10–7,200 seconds. Cap any wait recommendation at 55 seconds.

Return baseline on track start and status, and on an explicit find_processes lookup with includeBaseline. Resolve a live identity before computing its signature. Provide aistats baselines clear to erase all runs.

## Consequences

Different tasks using one executable share a baseline. Toolchain upgrades can temporarily skew estimates. Verify store privacy, concurrent recorders, retention boundaries, censored jobs, percentile calculations and the 256-byte baseline size.
