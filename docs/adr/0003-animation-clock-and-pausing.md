# ADR 0003 · Animation clock and pausing

Status: Accepted

## Context

AIStats uses one model with two possible Hosts. Popover and window lifecycle callbacks update a set of visible panels. The model's two-second timer also supports the Status Item and history while both Hosts are closed. The redesign adds ambient loops and bounded transitions with a separate rendering lifetime. [main.swift:74](../../Sources/AIStatsMenu/main.swift#L74), [AppModel.swift:47](../../Sources/AIStatsMenu/AppModel.swift#L47), [AppModel.swift:71](../../Sources/AIStatsMenu/AppModel.swift#L71), [AppModel.swift:90](../../Sources/AIStatsMenu/AppModel.swift#L90)

## Decision drivers

- Zero screen updates, frame deliveries, and Canvas calls to each closed Host.
- Zero animation ticks when no Host is exposed.
- Independent Phase per Host and effect across data updates, pauses, and rate changes.
- Immediate static output with Reduce Motion.
- Preserve metric sampling and the closed-panel history path.
- Test time and exposure transitions without depending on real delays.

## Considered options

| Option | Benefits | Costs |
| --- | --- | --- |
| Per-view `TimelineView` or SwiftUI repeat animations | Local code and familiar SwiftUI lifecycle. | Many render sources, extra work with two Hosts, and separate interruption and pause state for each effect. |
| One `TimelineView` inside a selected Host | Native schedule and one nominal source. | Requires an owner handoff when the selected Host loses exposure. Sharing a scheduled time from one hosting tree into another adds lifecycle work. |
| One app-owned monotonic Animation Clock | Explicit lifetime independent of Host view identity. Shared frame timestamps, policy, and trace points. | Requires a small app-level scheduler and exposure adapter. |

## Decision

Use one main-actor Animation Clock with a cancellable source and monotonic elapsed time. Enable delivery only for Exposed Hosts with eligible motion. Deliver at no more than 30 fps for one-shots. Apply each effect's limit from Table 5. Coalesce work due at the same tick into one delivery per Host. Cancel the source when the final consumer stops. Send frame inputs only to the affected rendering subtree.

Use show, close, hide, minimize, and window occlusion events to determine exposure. After popover content attaches, identify its hosting window. Read `occlusionState.contains(.visible)` for each Host's own window. Treat partial visibility as exposure. Use an opaque rectangular covering window for full-occlusion verification. A transparent or nonrectangular cover can leave the flag set. [Apple occlusion state](https://developer.apple.com/documentation/appkit/nswindow/occlusionstate-swift.property)

At close start, disconnect the Host's screen-data subscription synchronously. Remove the Host from process-scan eligibility before detaching its content. Disable frame delivery in the same main-actor callback. Detach the Panel subtree from the retained Host shell. Before it runs, each queued delivery or draw checks exposure and subscription identity. Build each newly exposed screen from the latest Screen Snapshot and fresh frame cells. Store paused phase separately from the frame cells. Track the union of Exposed Hosts for process-scan eligibility. Use the same lock for process ID enumeration and invalidation of the process generation. An admitted scan can finish without updating closed content.

Pause on loss of exposure or motion suppression. Store the last drawn Phase per Host and effect. Discard a loop's stored Phase when its data trigger ceases. Start each new loop at Phase 0. Check intervals per Host and effect; for Busy sweep, per row. Invalidate the process-list generation when the last Exposed Host loses exposure, and apply a scan's process list only if its generation is current. Store Busy sweep Phase per row. Use that Phase on the first resumed frame. Derive later Phase from elapsed monotonic time. Active and quiet limits change sampling times without changing the Phase origin. During a Quiet Period, Grid drift and Edge shimmer have 8 fps limits. Chart scan has a 10 fps limit. Hazard march retains 15 fps while a Warning is active. Busy sweep retains 15 fps independently of the Quiet Period. Use the SDD's positive rate reductions only where permitted.

Schedule boot on an explicit Open with Reduce Motion off. Start it at the first exposed frame. Discard a pending boot on close or when Reduce Motion turns on. Settle one-shots on loss of exposure and when Reduce Motion turns on. Keep the static settings state in one app-level NSWorkspace observer. Apply its values to the Animation Clock and all active hosting trees. [SDD animation catalog](../spec/0001-cyberpunk-panel.md#animation-catalog), [SDD closed Host checks](../spec/0001-cyberpunk-panel.md#closed-host-and-occlusion-checks)

## Consequences

The sampler, history, and Status Item can continue while no Panel receives delivery. Exposed Hosts can share a timestamp and keep independent phases. Tests check closed Host updates and draws with the other Host open and with both closed. Separate per-Host and per-effect traces show the cost of overlapping loops and one-shots.
