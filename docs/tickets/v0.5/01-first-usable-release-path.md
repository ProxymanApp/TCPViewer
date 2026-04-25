# v0.5.1 First Usable Release Path

## Summary
Define the minimum complete workflow for the first MVP desktop release so users can install TCP Viewer, capture traffic, inspect packets, and save their work.

## What To Build
- Stitch together the launch, capture, open/save, and analysis workflows into one coherent product path.
- Define MVP release criteria and unacceptable failure modes.
- Document the flows that must work end-to-end before v0.5 is considered shippable.

## Requirements
- New users must not need manual recovery steps for normal capture and save/open behavior.
- The MVP path must include both live and offline analysis.
- Release expectations must remain narrow enough to ship without v1-only features.

## Dependencies
- v0.2 capture-core tickets.
- v0.3 core-inspector tickets.
- v0.4 filters-and-triage tickets.

## Tests
- Unit tests: cover top-level workflow state transitions and failure recovery states.
- Integration tests: cover launch-to-capture-to-save/open flows with representative fixtures and mocked capture states.
- UI tests: out of scope.

## Out Of Scope
- TLS decryption.
- CLI automation.
