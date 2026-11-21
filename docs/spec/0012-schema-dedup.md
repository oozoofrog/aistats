# SDD 0012 · Schema Deduplication

Status · Proposed
Issue · [#11](https://github.com/oozoofrog/aistats/issues/11)

## Purpose and scope

This specification makes the `tools/list` result smaller. Some clients load every tool schema into the model context at session start. The aistats tool listing repeats the selector property descriptions in three tools, and two tool descriptions are long. A smaller listing costs fewer context tokens in each session of such a client. The change must not make tool selection or argument use worse, so a selection check gates it.

The scope is the tool descriptions, the property descriptions, and the size of the `tools/list` result. The server Instructions are in [SDD 0011](0011-instructions-priority.md). Tool names, arguments, and validation stay the same.

The key words "MUST", "MUST NOT", "SHOULD", "SHOULD NOT", and "MAY" in this document are to be interpreted as described in BCP 14 [RFC2119] [RFC8174] when, and only when, they appear in all capitals.

[RFC2119]: https://www.rfc-editor.org/rfc/rfc2119.html
[RFC8174]: https://www.rfc-editor.org/rfc/rfc8174.html

## Terms

| Term | Meaning |
| --- | --- |
| Tool Listing | The compact JSON serialization of the `tools/list` result, `{"tools":[...]}`, in bytes. |
| Description | The `description` string of one tool. |
| Selector Properties | The input schema properties `pid`, `startToken`, `name`, `path`, `match`, and `argsContain`. |
| Eager-Loading Client | An MCP client that puts all tool schemas into the model context at session start. |
| Baseline | The v0.3.0 tool table. |
| Selection Check | The release check in SCH-009 that compares tool choice with two Tool Listings. |

## Background and evidence

| Fact | Evidence |
| --- | --- |
| The Tool Listing of v0.3.0 is about 8,653 bytes. Measured on the built v0.3.0 binary. The Descriptions total 3,461 bytes. The input schemas total 3,911 bytes. | [MCPServer.swift:318](../../Sources/StatsCore/MCPServer.swift#L318) to [MCPServer.swift:419](../../Sources/StatsCore/MCPServer.swift#L419) |
| The Selector Properties are defined once in source. | [MCPServer.swift:308](../../Sources/StatsCore/MCPServer.swift#L308) to [MCPServer.swift:316](../../Sources/StatsCore/MCPServer.swift#L316) |
| `find_processes`, `track_processes`, and `wait_for` each merge the full Selector Properties into their input schema. | [MCPServer.swift:368](../../Sources/StatsCore/MCPServer.swift#L368), [MCPServer.swift:378](../../Sources/StatsCore/MCPServer.swift#L378), [MCPServer.swift:399](../../Sources/StatsCore/MCPServer.swift#L399) |
| The Selector Property description text is 358 bytes per copy. The `argsContain` description is 200 bytes of that. The three copies total 1,074 bytes. Computed from the source text. | [MCPServer.swift:309](../../Sources/StatsCore/MCPServer.swift#L309) to [MCPServer.swift:315](../../Sources/StatsCore/MCPServer.swift#L315) |
| Two Descriptions hold cross-tool routing sentences: `get_system_stats` points to `diagnose_system`, and `get_top_processes` points to `find_processes`. | [MCPServer.swift:322](../../Sources/StatsCore/MCPServer.swift#L322), [MCPServer.swift:329](../../Sources/StatsCore/MCPServer.swift#L329) |
| No tool declares `outputSchema`. | [MCPServer.swift:318](../../Sources/StatsCore/MCPServer.swift#L318) to [MCPServer.swift:419](../../Sources/StatsCore/MCPServer.swift#L419) |
| The server validates every argument itself. Wrong types and out-of-range values are tool errors. | [MCPServer.swift:720](../../Sources/StatsCore/MCPServer.swift#L720) to [MCPServer.swift:803](../../Sources/StatsCore/MCPServer.swift#L803), [Proc.swift:316](../../Sources/StatsCore/Proc.swift#L316) to [Proc.swift:346](../../Sources/StatsCore/Proc.swift#L346) |

### Table 1 · Description sizes in v0.3.0

UTF-8 bytes of each Description, computed from the source text.

| Tool | Bytes | Source |
| --- | --- | --- |
| `get_system_stats` | 259 | [MCPServer.swift:322](../../Sources/StatsCore/MCPServer.swift#L322) |
| `get_top_processes` | 208 | [MCPServer.swift:329](../../Sources/StatsCore/MCPServer.swift#L329) |
| `get_stats_history` | 267 | [MCPServer.swift:342](../../Sources/StatsCore/MCPServer.swift#L342) |
| `diagnose_system` | 455 | [MCPServer.swift:355](../../Sources/StatsCore/MCPServer.swift#L355) |
| `find_processes` | 404 | [MCPServer.swift:365](../../Sources/StatsCore/MCPServer.swift#L365) |
| `track_processes` | 917 | [MCPServer.swift:375](../../Sources/StatsCore/MCPServer.swift#L375) |
| `wait_for` | 679 | [MCPServer.swift:396](../../Sources/StatsCore/MCPServer.swift#L396) |
| `get_environment` | 272 | [MCPServer.swift:412](../../Sources/StatsCore/MCPServer.swift#L412) |
| Total | 3,461 | |

Client behavior:

- Claude Code 2.1.328 in its default configuration defers tool schemas. A schema loads only when the model searches for the tool. A smaller schema still costs less when it loads.
- Gemini CLI loads all tool schemas at session start, according to its documentation. This was not captured live.

Estimate, not a measurement: at about 4 bytes per token, the v0.3.0 Tool Listing is about 2,200 tokens. The SCH-002 limit removes 320 to 716 bytes of Selector Property descriptions from two tools. The SCH-001 limit removes at least 572 bytes from the `track_processes` and `wait_for` Descriptions. The Tool Listing is then about 7,365 to 7,761 bytes, which saves about 220 to 320 tokens per session of an Eager-Loading Client.

## Requirements

| ID | Requirement | Acceptance check |
| --- | --- | --- |
| SCH-001 | Each Description MUST be at most 512 bytes in UTF-8. | Unit test `toolDescriptionsFitBudget`: iterate `MCPServer.tools`. Verify the byte count of each `description`. |
| SCH-002 | Outside `find_processes`, each Selector Property description MUST be at most 48 bytes in UTF-8. | Unit test: read the Selector Properties of `track_processes` and `wait_for`. Verify the byte count of each `description`. |
| SCH-003 | Each Selector Property MUST keep its Baseline `type`, `enum`, `default`, `minimum`, `maximum`, `minLength`, and `maxLength` in every tool. | Unit test: compare these keys in each tool with a Baseline fixture of the Selector Properties. |
| SCH-004 | The Tool Listing of the Baseline tool set SHOULD be at most 7,780 bytes, about 10% below the Baseline. | Unit test `toolsListFitsByteBudget`: serialize `["tools": MCPServer.tools]` with `JSONWriter`. Measure the byte count. Use a build without the additions of other specs. |
| SCH-005 | From the release that implements this specification, the Tool Listing MUST NOT exceed the Baseline size. | Record the Baseline size with the SCH-004 serialization first. The test fails when a later tool table exceeds it. Additions from other specs count toward the same limit. |
| SCH-006 | Each fact removed from a Description MUST remain in an input schema, a property description, an error message, or the result JSON. | The change request has a table: removed clause, new location. A reviewer verifies each row in the source. |
| SCH-007 | Input schemas MUST NOT use `$ref` or `$defs`. | Unit test: search each input schema for these keys at any depth. |
| SCH-008 | Tool names, titles, and annotations MUST NOT change. | Unit test: compare `name`, `title`, and `annotations` of each tool with the Baseline fixture. |
| SCH-009 | A Description or property description change MUST NOT ship unless the Selection Check shows no loss. | Use a fixture of at least 24 task prompts, 3 or more per tool, each with the expected first tool and its required arguments. Give the same model the Baseline and the candidate Tool Listing with all schemas loaded. Run each 3 times. Pass when the summed correct count of the candidate is equal to or greater than the Baseline count. |
| SCH-010 | The Selection Check fixture SHOULD include near-miss prompts for each tool pair in Table 2. | Review the fixture. Verify at least 2 prompts per pair. |
| SCH-011 | The cross-tool routing sentences of the Baseline SHOULD remain in the Descriptions. | Review: the `get_system_stats` Description names `diagnose_system`. The `get_top_processes` Description names `find_processes`. |
| SCH-012 | A Description SHOULD state the unit of each CPU percentage that the tool returns. | Review: `get_top_processes`, `track_processes`, and `wait_for` state "percent of one core" or "percent of all cores" where each applies. |

### Table 2 · Near-miss tool pairs

| Pair | Typical confusion |
| --- | --- |
| `get_top_processes` and `find_processes` | ranking against lookup of one process |
| `get_system_stats` and `diagnose_system` | numbers against a verdict |
| `track_processes` and `wait_for` | observe over time against block until a condition |
| `get_stats_history` and `get_system_stats` | past trend against current reading |

## Non-goals

- Removal of the JSON text that duplicates `structuredContent` in tool results. The MCP specification recommends the duplicate. In one observation on Claude Code 2.1.328, the model received only `structuredContent`.
- New `outputSchema` declarations. A later addition counts toward SCH-005.
- Changes to the server Instructions. See [SDD 0011](0011-instructions-priority.md).
- Changes to argument names, ranges, or validation.
- A split or merge of tools.

## Dependencies and related specs

- [SDD 0002](0002-port-lookup.md) adds a `port` Selector Property and a `wait_for` condition. These count toward SCH-005.
- [SDD 0006](0006-wait-for-conditions.md) adds `wait_for` conditions and arguments. These count toward SCH-005.
- [SDD 0009](0009-agent-sessions-mcp.md) adds the `get_agent_sessions` tool. Its Description and input schema count toward SCH-005.
- [SDD 0010](0010-delta-responses.md) adds a `since` argument. It counts toward SCH-005.
- [SDD 0011](0011-instructions-priority.md) uses the Selection Check of SCH-009.
- [SDD 0008](0008-cli-parity.md) maps every input schema property to a CLI option. SCH-003 keeps that map valid.

## Open questions

- The list of Eager-Loading Clients is not verified. Only Gemini CLI is documented as one, and its loading was not captured live.
- The model, the client, and the prompt wording for the Selection Check are not chosen. A check without a client needs a harness that presents the Tool Listing directly to a model.
- Whether a 48-byte `argsContain` description in `wait_for` reduces correct use of the argument is not measured. The full rule stays in `find_processes`, and the error messages state the valid combinations.
- The 8,653-byte Baseline was measured on the binary. The SCH-004 serialization can differ by a few bytes. SCH-005 uses the value from that serialization.
- Token counts are estimates at about 4 bytes per token. No tokenizer measured them.

## Release check

The 0.3.0 listing measured 8,653 compact UTF-8 bytes. The candidate listing with nine tools measured 6,921 bytes. Three independent runs selected the first tool and its effective arguments for the same 24 prompts on both listings. Both scored 72/72. The candidate also passed nine selections over three new session prompts. The baseline has no session tool. The [prompt fixture](../../scripts/fixtures/tool-selection.json) records the expected answers.

| Shortened clause | Where the client gets the fact |
| --- | --- |
| Snapshot interval, top five, alternative verdict | Snapshot description, sampleIntervalSeconds, topProcesses |
| CPU scale, ranking, current-user scope and targeted lookup | Ranking description, sort and limit, server instructions |
| History window, recording cadence, sample count, aggregates, absent recorder | History description, minutes, maxPoints, window statistics and recorder hint in the result |
| Diagnostic thresholds, evidence order and readiness | Diagnostic description, purpose enum, status, readiness and evidence fields |
| Selector syntax, defaults, identity, unreadable fields, transient bind | Full selector properties in find_processes, its description and matched rows |
| Duration, tick, capture and spike limits | Track schema ranges and sampleOnSpike property |
| Instance overlap, root exits, summed usage and single-member peak | Track description, aggregate, restartCount and additionalInstances |
| Child executable counts, events, threads and trimmed lists | Track description, spawn, events, spikes and omission counts |
| Scoped waits, target exit, idle readings, deadline, failure state | Wait description, condition, trackId, timeoutSeconds and state/reason |
| OS build, architecture, Xcode selection and Swift version | Environment description, includeToolchain default and environment fields |
