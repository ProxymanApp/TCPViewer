# v0.9.4 TLS Decryption v1

## Summary
Define limited TLS decryption for supported TLS-over-TCP sessions using imported key-log files so Packetry can support practical encrypted-traffic debugging in v1.

## What To Build
- Specify the key-log import workflow and supported decryption scope.
- Define how decrypted payload views relate to raw packets, metadata, and follow-stream workflows.
- Cover unsupported sessions, missing secrets, and partial decryption outcomes clearly.

## Requirements
- The feature must remain limited to key-log-based TLS-over-TCP workflows in v1.
- Decrypted views must never obscure the raw encrypted packet truth.
- The decryption state must be explicit and testable.

## Dependencies
- v0.7.3 TLS metadata and fingerprinting.
- v0.6.1 TCP reassembly and IP defragmentation.

## Tests
- Unit tests: cover key-log parsing, session-secret matching, and decryption-state handling.
- Integration tests: cover successful, partial, and failing decryption scenarios using TLS key-log fixtures.
- UI tests: out of scope.

## Out Of Scope
- QUIC decryption.
- Automated browser key capture.
