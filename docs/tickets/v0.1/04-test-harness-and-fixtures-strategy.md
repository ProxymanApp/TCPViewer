# v0.1.4 Test Harness And Fixtures Strategy

## Summary
Define the fixture library, test split, and regression strategy so Packetry and `PcapPlusPlusCore` can be verified with unit and integration tests from the start.

## What To Build
- Describe the shared fixture catalog for TCP, UDP, retransmits, malformed packets, HTTP, TLS, DNS, WebSocket, and macOS metadata samples.
- Define which tests belong in `PacketryTests` vs `PcapPlusPlusCoreTests`.
- Document deterministic expectations for file round-trips, parsing, and graph/stat outputs.

## Requirements
- Every future runtime ticket must reference unit and integration coverage.
- Fixtures must include both happy-path and failure-path captures.
- Test strategy must avoid UI automation.

## Dependencies
- v0.1.1 roadmap and docs scaffold.

## Tests
- Unit tests: cover fixture loaders, shared expectation builders, and helpers once implemented.
- Integration tests: cover end-to-end fixture processing across both targets.
- UI tests: out of scope.

## Out Of Scope
- Benchmark implementation.
- CI pipeline configuration beyond what is needed for test execution expectations.
