# v0.6.3 Decode-As And Protocol Overrides

## Summary
Define the controls that let analysts force ambiguous traffic to decode as a different protocol or override non-standard ports.

## What To Build
- Model decode-as rules and override scope.
- Specify how overrides affect packet detail, filters, stream analysis, and saved workspaces.
- Define validation and fallback behavior when an override cannot apply cleanly.

## Requirements
- Decode-as rules must be explicit, reversible, and profile-friendly.
- Overrides must not mutate raw capture data.
- The feature must work with both transport-level and limited app-layer decoders.

## Dependencies
- v0.3.2 core packet decode surface.
- v0.4.2 filter UX and saved filters.

## Tests
- Unit tests: cover override rule storage, conflict resolution, and decode selection.
- Integration tests: cover non-standard-port HTTP, TLS, and WebSocket fixtures plus invalid override scenarios.
- UI tests: out of scope.

## Out Of Scope
- Custom plugin dissectors.
- Broad protocol-pack management.
