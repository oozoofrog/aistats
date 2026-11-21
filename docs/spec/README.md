# AIStats design specifications

## Specification

- [SDD 0001 · Cyberpunk Panel](0001-cyberpunk-panel.md)
- [SDD 0002 · Port Lookup](0002-port-lookup.md) · [#1](https://github.com/oozoofrog/aistats/issues/1)
- [SDD 0003 · Top Process Identity](0003-top-process-identity.md) · [#2](https://github.com/oozoofrog/aistats/issues/2)
- [SDD 0004 · Summary Facts in Structured Content](0004-summary-facts-in-json.md) · [#3](https://github.com/oozoofrog/aistats/issues/3)
- [SDD 0005 · Response Size Budget](0005-response-size-budget.md) · [#4](https://github.com/oozoofrog/aistats/issues/4)
- [SDD 0006 · Wait-for Conditions](0006-wait-for-conditions.md) · [#5](https://github.com/oozoofrog/aistats/issues/5)
- [SDD 0007 · Preflight Hook](0007-preflight-hook.md) · [#6](https://github.com/oozoofrog/aistats/issues/6)
- [SDD 0008 · CLI Parity](0008-cli-parity.md) · [#7](https://github.com/oozoofrog/aistats/issues/7)
- [SDD 0009 · Agent Sessions over MCP](0009-agent-sessions-mcp.md) · [#8](https://github.com/oozoofrog/aistats/issues/8)
- [SDD 0010 · Delta Responses](0010-delta-responses.md) · [#9](https://github.com/oozoofrog/aistats/issues/9)
- [SDD 0011 · Instructions Priority](0011-instructions-priority.md) · [#10](https://github.com/oozoofrog/aistats/issues/10)
- [SDD 0012 · Schema Deduplication](0012-schema-dedup.md) · [#11](https://github.com/oozoofrog/aistats/issues/11)
- [SDD 0013 · Orphan Report](0013-orphan-report.md) · [#12](https://github.com/oozoofrog/aistats/issues/12)
- [SDD 0014 · Developer Storage Breakdown](0014-dev-storage-breakdown.md) · [#13](https://github.com/oozoofrog/aistats/issues/13)
- [SDD 0015 · Job Duration Baselines](0015-job-duration-baselines.md) · [#14](https://github.com/oozoofrog/aistats/issues/14)
- [SDD 0016 · Simulator Resources](0016-simulator-resources.md) · [#15](https://github.com/oozoofrog/aistats/issues/15)
- [SDD 0017 · Live Process Origin](0017-process-origin.md) · [#16](https://github.com/oozoofrog/aistats/issues/16)

## Architecture decisions

- [ADR 0001 · Record architecture decisions](../adr/0001-record-architecture-decisions.md)
- [ADR 0002 · Rendering technology](../adr/0002-rendering-technology.md)
- [ADR 0003 · Animation clock and pausing](../adr/0003-animation-clock-and-pausing.md)
- [ADR 0004 · Typography and fonts](../adr/0004-typography-and-fonts.md)
- [ADR 0005 · Design tokens in code](../adr/0005-design-tokens-in-code.md)
- [ADR 0006 · Visual verification](../adr/0006-visual-verification.md)
- [ADR 0007 · Confirmation dialog hosting](../adr/0007-confirmation-dialog-hosting.md)
- [ADR 0008 · Cross-session track cursor storage](../adr/0008-cross-session-track-cursors.md)
- [ADR 0009 · Record observed descendant identities for the orphan report](../adr/0009-orphan-lineage.md)

## Document conventions

SDD means Spec-Driven Development. The specification states observable behavior and the check for each requirement. It uses [BCP 14](https://www.rfc-editor.org/info/bcp14) with the uppercase requirement keywords defined by RFC 2119 and RFC 8174. Use a stable area-prefixed ID for each requirement, such as `ANI-001`. Keep IDs when refining a requirement. Assign new IDs to new behaviors. Mark removed requirements as Withdrawn. Keep Withdrawn IDs reserved. Give each mandatory requirement a falsifiable acceptance check.

Use [ASD-STE100](https://www.asd-ste100.org/) principles in requirement sentences. Use active voice, one requirement per sentence, and consistent terms. Limit instructions to 20 words and descriptive sentences to 25 words. Keep original Korean UI literals and mark variable fields.

ADRs record context, drivers, options, the decision, and consequences. Proposed ADRs await maintainer review. Accepted ADRs record decisions for implementation. The specification takes precedence over reference mockups.
