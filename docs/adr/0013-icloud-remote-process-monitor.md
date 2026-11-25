# ADR 0013 · Connect a paired iPhone through the private CloudKit database

Status: Accepted for transport and local termination approval

## Context

Issue #18 requires access from cellular data without a VPN. The user selected the same iCloud account on both devices. The Mac may sleep or lose network access. Account membership alone does not identify an approved phone.

## Decision

Use the private database of a shared CloudKit container. Both apps must be signed for that container in the same CloudKit environment. Each device must have an available iCloud account. A fresh handshake with the Mac is required before the phone shows a live connection.

Pair each phone explicitly on the Mac. Bind approval to a device public key and keep the private key in the phone's device-only Keychain. The Mac must authorize signed viewer leases and termination requests. Keep samples encrypted for the approved viewer before saving them in CloudKit. Unpairing stops new samples for that key and invalidates its outstanding requests.

Treat CloudKit as asynchronous storage. The phone must show sample time and request status. The Mac checks expiry on receipt and again before local approval. After a restart it must treat a partially executed request as indeterminate and must not send the signal again. Use bounded polling while viewing. Push notifications may wake a client but cannot provide proof of delivery or freshness.

## Consequences

The Mac needs outbound internet access and must be awake with AIStats running to publish fresh data or approve a request. The phone can use cellular data. Neither device needs an inbound listener or VPN. Switching accounts discards the active device selection and clears process data from the screen. Revocation cannot recall information already seen.

A LAN-only listener cannot meet the cellular acceptance check. A VPN would require a separate account or client. A custom relay would add a service to operate.
