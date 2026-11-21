# ADR 0008 · Cross-session track cursor storage

Status: Accepted

## Context

[SDD 0010](../spec/0010-delta-responses.md) requires track status cursors to survive the reporting session. Track storage currently retains the latest report. It cannot recover a previous caller's fitted report or distinguish a late spike capture from a newly reported spike.

## Decision drivers

Preserve the 64-byte cursor limit, track identity, event omission counts and existing retention boundaries. Preserve the exact state the caller received after response trimming.

## Considered options

- Keep bases in session memory. A second session cannot use them.
- Encode the base in the cursor. Arbitrary retained rows and changed spike details do not fit in 64 bytes.
- Retain a bounded index beside each track. This introduces storage and cleanup across concurrent sessions.

## Decision

Keep a private index under the existing tracks directory. Keep eight bases per track. Each base contains section digests, the event watermark, and spike identifiers with digests of the details returned. Keep arguments, environment, executable paths and sample text out of the index. Bind every cursor to a track ID. Serialize writers with a per-track lock and replace the index atomically. Remove the index when its track report expires.

## Consequences

Readers in different sessions can recognize the same base without retaining copies of process details. Eviction requires a full response with an expired-cursor reason. System snapshot cursors use the session memory already specified by DLT-021 through DLT-023.
