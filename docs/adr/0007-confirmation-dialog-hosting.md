# ADR 0007 · Confirmation dialog hosting

Status: Accepted

## Context

The current replacement path opens an app-modal `NSAlert` from a redacted summary and Fingerprint. Its first button, `덮어쓰기`, is the Return default. The Panel can reside in a transient popover or a standalone window. The existing install operation permits ordinary installation or path updates if a conflict disappears. [AppModel.swift:189](../../Sources/AIStatsMenu/AppModel.swift#L189), [main.swift:15](../../Sources/AIStatsMenu/main.swift#L15)

## Decision drivers

- Use the same dialog in both Hosts.
- Preserve the text, exact Fingerprint, cancellation, and keyboard focus.
- Keep the transient popover as the initiating context during confirmation.
- Keep destination configuration changes in the registrar.

## Considered options

| Option | Benefits | Costs |
| --- | --- | --- |
| Keep `NSAlert` | Native behavior with limited wiring. | System layout does not provide the requested chamfered content, selectable summary presentation, and custom hazard strip. |
| In-Panel SwiftUI overlay or per-Host sheet | Overlay can follow the Host. A window sheet can use native modality. | An overlay needs its own focus and pointer handling. A fallback sheet and transient popover use different attachment rules. |
| App-modal `NSPanel` with SwiftUI content | The same native modal boundary and designed content apply to both Hosts. | Requires explicit modal teardown and focus restoration. |

## Decision

Use one AppKit modal panel per action with SwiftUI content. Capture the initiating Host, Agent Target, redacted summary, and Fingerprint at presentation. Display the captured summary and Fingerprint without further truncation. Apply `.applicationDefined` to the initiating popover before entering the modal loop. Restore `.transient` on every exit path. Set initial focus and the Return action to `취소`. Use Escape and close for cancellation. Restore the initiating action or row focus only if the Host remains open.

Route explicit confirmation to a GUI-only registrar operation. Require a name conflict with the captured Fingerprint at locked inspection. Carry the inspected Entry identity to the existing final re-check. Reuse the existing backup procedure. External CLIs lack atomic compare-and-write. For those writes, the guarantee holds through the final re-check. External writes can race with JSON rename or the agent CLI after the final validation. Leave the public CLI contract unchanged. [SDD confirmation dialog](../spec/0001-cyberpunk-panel.md#replace-confirmation-dialog)

If a registration check for the target is in progress at confirmation, submit the captured Fingerprint after the check completes. Deliver display accessibility changes on the main run loop in modal panel mode as well as in common modes. Apply each change to both Hosts and the open dialog.

## Consequences

Native modal routing protects the underlying controls. Return now cancels in both Hosts as an intentional safety change. Verify mouse, Return, Escape, close, and VoiceOver in both Hosts. Check outside click after every modal exit path. Test deletion, conversion to an owned Entry, and replacement with a different conflict. Require byte equality and zero change-command calls for each refusal.
