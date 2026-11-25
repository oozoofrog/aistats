# SDD 0018 · Monitor a paired Mac from an iPhone

Status: Proposed

## User flow

Both devices sign in to the same iCloud account and use the private CloudKit database. The Mac must be awake with AIStats running. The user approves the iPhone on the Mac. On a different network, the user opens the iPhone app, selects the Mac, and sees its current processes. Each row shows the process name and its observed resource use. The screen shows when the Mac sampled the data. If the Mac stops responding, the screen identifies the last sample as stale and disables termination requests.

The user selects a process and taps **종료 요청**. Both devices show the process name and PID. The Mac offers **취소** as its default action and **종료** as the explicit approval. The iPhone shows a pending request until the Mac supplies a result or the request expires.

## Acceptance

- REM-001. With Wi-Fi disabled on the iPhone and the Mac online on a separate network, a paired phone MUST receive a fresh Mac sample. An unpaired phone MUST receive no process data.
- REM-002. The Mac MUST send only the process identity, display name, resource readings, origin category and sample time. It MUST omit arguments, paths and environment values.
- REM-003. Revoking the pairing MUST stop access to new samples. The Mac MUST reject pending requests from the revoked device, including requests approved locally after revocation.
- REM-004. A request MUST identify one process by PID and start token. Before acting, the Mac MUST check the pairing, expiry, local approval, process owner and current start token. A mismatch, decline or timeout MUST result in zero signals.
- REM-005. The Mac MAY send one SIGTERM to an eligible process after approval. A repeated request identifier MUST NOT cause another signal, including after a restart. Both screens MUST distinguish signal delivery from observed process exit.
- REM-006. The Mac MUST record the time, paired device, process display name and outcome for a termination request. The audit record MUST obey REM-002.
- REM-007. With no active remote viewer and no local panel exposed, the remote feature MUST add no process sampling. A lost connection MUST expire the viewer's sampling session.
- REM-008. A sleeping or offline Mac MUST NOT be shown as live. Reconnecting MUST NOT execute an expired termination request.

## Verification

Use a paired iPhone on cellular data and a Mac on another network. Launch a disposable user-owned process and verify a fresh reading. Exercise approval, cancellation, expiration, replay, PID reuse and revocation. Inspect the two screens, the Mac audit record and the observed process state after each action. Disconnect the phone and measure sampling after the viewer session expires.

See [ADR 0013](../adr/0013-icloud-remote-process-monitor.md) for transport and approval.
