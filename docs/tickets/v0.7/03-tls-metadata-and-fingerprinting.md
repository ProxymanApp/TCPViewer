# v0.7.3 TLS Metadata And Fingerprinting

## Summary
Define a focused TLS analysis surface with handshake metadata, SNI, version/cipher details, and fingerprint summaries where available.

## What To Build
- Specify handshake metadata models and TLS summary rows.
- Define how JA3/JA3S-style fingerprint summaries are represented when available from the core layer.
- Cover partially captured handshakes and unsupported TLS details.

## Requirements
- TLS metadata must work without requiring decryption.
- The app must distinguish parsed metadata from decrypted content.
- The feature must integrate with decode-as and later TLS key-log decryption.

## Dependencies
- v0.6.3 decode-as and protocol overrides.
- v0.7.2 HTTP analysis and object export foundation.

## Tests
- Unit tests: cover handshake-field mapping and fingerprint summary formatting.
- Integration tests: cover TLS handshake fixtures with complete, partial, and ambiguous sessions.
- UI tests: out of scope.

## Out Of Scope
- TLS payload decryption.
- Certificate trust evaluation.
