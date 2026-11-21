# ADR 0010 · Measure a fixed set of developer directories in the app

Status: Proposed

## Context

[SDD 0014](../spec/0014-dev-storage-breakdown.md) requests storage evidence within a fast agent call. A recursive scan can block on protected or remote storage.

## Decision drivers

Avoid privacy prompts and unbounded walks. Identify incomplete measurements. Preserve the two-second screen refresh.

## Considered options

An on-demand server walk adds unpredictable latency. General home-directory enumeration increases privacy scope. A bounded app pass makes the time and coverage visible.

## Decision

Limit v1 to Xcode DerivedData and Archives under the current user's Library/Developer/Xcode directory, and the org.swift.swiftpm cache under Library/Caches. Resolve these fixed paths relative to the current user's home. Change the allowlist only through a reviewed specification revision. Exclude user-added roots, protected folders, symlinks, mounted subtrees, remote roots and roots redirected through symlinks. Qualify each supported macOS version for absence of consent prompts before enabling a root.

Use allocated bytes from file block counts, sizeKind allocated_blocks. Deduplicate hard links by volume and inode within a pass. Count each distinct clone inode separately. Sparse holes contribute no allocated blocks. Count purgeable blocks while allocated. Directory totals cannot predict the bytes reclaimed by deletion.

Schedule a utility-queue pass at most once every six hours on AC power. Defer in Low Power Mode or serious/critical thermal state. Budget five seconds wall time and 200 ms of process CPU per pass. Mark the current entry incomplete on timeout. Report the count of unvisited roots. Atomically replace the private cached report. Expose get_developer_storage and aistats storage --json. Both read cached data. Use the first and last valid availableBytes readings in the latest 60 minutes. Divide the decrease by actual elapsed hours. Omit the rate with fewer than two distinct observation times. Omit time-to-low-disk estimates.

Include the boot data volume and Finder-visible mounted volumes. Count omitted mounts. Use cached mount-table statistics for network volumes. Return unavailable when statistics are missing. Group APFS volumes by a publicly verified container identifier when available. Otherwise omit the identifier and suppress cross-volume capacity sums.

## Consequences

The initial set omits other build systems. Allocated bytes can double-count shared clone blocks. Verify hard links, sparse files, clones, slow mounts, permission denial and deadline interruption on fixtures before enabling the pass.
