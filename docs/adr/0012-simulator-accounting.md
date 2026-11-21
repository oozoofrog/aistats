# ADR 0012 · Account for visible simulator process trees without an owner registry

Status: Proposed

## Context

[SDD 0016](../spec/0016-simulator-resources.md) requests resource usage per visible device. A launchd_sim process can exist independently of the session that requested the device.

## Decision drivers

Support systems without a selected Xcode. Observe devices without changing their state. Keep host service memory separate from device totals.

## Considered options

A simctl subprocess can enumerate device metadata but adds an Xcode dependency and variable latency. Parsing device files and application paths depends on filesystem layout. An external claim registry introduces a format and ownership dependency.

## Decision

Use each current-user launchd_sim process identity as a device root. Include all visible device sets, including previews. Measure only that root and its observed descendants over one second. Stop at nested roots. Exclude independent host services. Report the sum of physical footprints and one-core CPU percentages. Distinguish unreadable measurements from zero.

Use no optional device identity source or claim registry in v1. Omit UDID, name, runtime and owner; set ownerUnknown to no_source. This adds zero subprocess latency and requires no Xcode installation. Do not derive identity from executable paths. Expose get_simulator_usage and aistats sims --json. Defer a panel section and heavy-work diagnosis changes.

## Consequences

Users identify devices by root PID, token and boot time. The report cannot name the owning session. Verify the empty case, multiple synthetic roots, exclusion of host services, incomplete metrics and the no-Xcode case. Check latency against existing booted devices only when they are available for authorized testing.
