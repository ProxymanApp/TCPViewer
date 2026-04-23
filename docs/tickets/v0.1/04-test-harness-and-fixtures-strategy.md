# v0.1.4 Test Harness And Fixtures Strategy

Status: COMPLETE

## Owned Artifacts
- [docs/testing/test-harness-and-fixtures.md](../../testing/test-harness-and-fixtures.md)
- [Fixtures/README.md](../../../Fixtures/README.md)
- [Fixtures/manifest.json](../../../Fixtures/manifest.json)
- [PacketryTests/FixtureLocator.swift](../../../PacketryTests/FixtureLocator.swift)
- [PacketryTests/CaptureAccessModelTests.swift](../../../PacketryTests/CaptureAccessModelTests.swift)
- [PcapPlusPlusCoreTests/FixtureLocator.swift](../../../PcapPlusPlusCoreTests/FixtureLocator.swift)
- [PcapPlusPlusCoreTests/CoreFacadeTypesTests.swift](../../../PcapPlusPlusCoreTests/CoreFacadeTypesTests.swift)

## Definition Of Done
- Create a shared fixture layout under `Fixtures/` with starter category directories and a manifest.
- Document naming, versioning, deterministic expectations, and target ownership.
- Add fixture-locator helpers and smoke coverage in both existing test targets.

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
- Unit tests: cover fixture-locator helpers, onboarding-state models, and starter core-facade behavior in the existing test targets.
- Integration tests: cover end-to-end fixture catalog discovery across both targets now, then expand to full packet-processing flows as captures and goldens are added.
- UI tests: out of scope.

## Out Of Scope
- Benchmark implementation.
- CI pipeline configuration beyond what is needed for test execution expectations.
