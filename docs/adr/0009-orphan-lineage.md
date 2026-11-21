# ADR 0009 · Record observed descendant identities for the orphan report

Status: Proposed

## Context

[SDD 0013](../spec/0013-orphan-report.md) needs evidence from before a parent exits. A live tree cannot recover a parent that has already disappeared.

## Decision drivers

Limit CPU overhead across multiple sessions. Bound retention and disclose observation gaps. Keep the report read-only for agents.

## Considered options

A recorder in each server repeats work and loses coverage on disconnect. Process groups can include unrelated work. Reading environment markers exposes unrelated secrets. A single app recorder can reuse one current-user process table.

## Decision

Have the app sample once per second while live sessions exist. Record only an observed nearest-agent chain with matching start tokens. Record coverage start, gaps and last successful observation. Keep recording when the panel closes on a separate, opt-in recording path. Acceptance requires meeting the CPU limits of SDD 0013 and separating coverage from the panel exposure rule. ORP-001 and ORP-004 apply during enabled recording coverage. PERF-010 continues to prohibit hidden panel sampling. An accepted decision would explicitly authorize only the independent recorder.

End ownership when the agent instance exits. A server disconnect alone does not end ownership. Keep an observed session label and both server and agent identities. Store versioned JSON Lines in a private lineage subdirectory of the app data directory. Use 0700 for directories and 0600 for files. Remove oldest records first at seven days or 2 MiB, whichever limit comes first. Store ORP-002 fields in descendant records. In separate session records keep the session label, server identity, agent identity and first observed agent exit time for endedAt. Include coverage gaps with their timestamps. Apply the same retention and privacy rules to both. A detached job missed by the recorder has unknown origin.

Expose get_orphan_processes and the orphans CLI as read-only reports. If the app offers termination, confirm “프로세스 종료” with process name, PID, session name and elapsed time. Set 취소 as the default. Recheck current UID, instance token, ended owner and absence of a live agent immediately before sending one SIGTERM to that PID. Report exit or continued operation; never escalate.

## Consequences

App downtime and brief parent lifetimes can leave gaps. Verify a missed detached job remains unknown. Test two sessions sharing an agent, PID reuse, cancellation, a signal-resistant fixture, bounded retention and eight-session recording cost before release.
