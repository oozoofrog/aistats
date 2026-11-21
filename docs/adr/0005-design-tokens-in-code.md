# ADR 0005 · Design tokens in code

Status: Accepted

## Context

The Panel, both Hosts, and the Confirmation Dialog share a color palette, type scale, geometry, and motion timings. The implementation needs a single source of values. The specification needs readable values for design reviews and verification. [SDD design tokens](../spec/0001-cyberpunk-panel.md#design-tokens)

## Decision drivers

- Make the visual vocabulary consistent across components.
- Make numeric values easy to audit against Tables 1–5.
- Keep the plain SwiftPM build and avoid a code generation step.
- Keep accessibility overrides easy to test.

## Considered options

| Option | Benefits | Costs |
| --- | --- | --- |
| Per-view literals | Direct and quick for a single component. | Small visual changes need edits across several components. Overrides drift between Hosts. |
| One typed Swift Theme | Named values in one file. Simple fixed variants for per-user accessibility settings. | A human review and tests keep the file and specification in sync. |
| Token file plus code generation or runtime parsing | Useful if several independent platforms need the same tokens. | Adds an input format, generation or decoding, and build integration for one client. |

## Decision

Place one internal `Theme` type in the AIStatsMenu target. Use named groups for color, type, dimensions, effects, and motion. Give token properties the names and units used in Tables 1–5. Keep sRGB values inspectable as hexadecimal data. Resolve appearance overrides at the Panel and Confirmation Dialog boundary. Use the shared NSWorkspace state from ADR 0003. Use the same tokens under either Host. Include the fixed-width gutters, per-button states, and active and quiet frame limits in Theme. Keep product names, Korean copy, and sampling constants in their existing concerns.

Treat the SDD as the contract and `Theme` as the implementation. Update both together when a visual value changes. Review each changed constant against its table row. Test exact values for motion and geometry, sRGB contrast pairs, and effective accessibility variants.

## Consequences

Implementation values stay discoverable and type checked. Theme parity needs a review whenever the SDD or `Theme` changes. The runtime has no new token parser, generator, or package dependency.
