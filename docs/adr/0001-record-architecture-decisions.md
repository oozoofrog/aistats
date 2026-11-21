# ADR 0001 · Record architecture decisions

Status: Accepted

## Context

AIStats is a SwiftPM project with a menu bar app and a shared CLI and MCP binary. The Panel redesign adds choices about rendering, motion, assets, and verification. The specification records visible behavior and acceptance checks. Maintainers also need the reasoning behind changes that cross component boundaries. [SDD 0001](../spec/0001-cyberpunk-panel.md)

## Decision drivers

- Preserve a traceable reason for each architectural choice.
- Keep decisions small enough to review and supersede independently.
- Keep acceptance criteria in the specification.

## Considered options

| Option | Trade-off |
| --- | --- |
| Pull request descriptions and source comments | Low initial effort. Rationale is split across changes and depends on review history. |
| One design document for behavior and decisions | Easy to start. Superseding one choice can obscure the history of the other choices. |
| Numbered Markdown ADRs linked from the specification index | Keeps one decision and its alternatives together. Adds one small document per material choice. |

## Decision

Record material architecture decisions in numbered, MADR-style Markdown files in `docs/adr/`. Use Context, Decision drivers, Considered options, Decision, Consequences, and a status. Link each decision to its requirements or verification section. Start each proposal as Proposed. Set the status to Accepted when maintainers accept the decision. Use a new ADR to supersede a decision that has taken effect. [MADR](https://adr.github.io/madr/)

## Consequences

The specification can change with product behavior while the ADRs preserve rejected options and build constraints. Each architectural change adds a short document and an index entry. A small implementation choice can stay in the implementation review.
