# v1.0.2 Documentation Bundle

## Summary
Define the end-user and support documentation required for a stable TCPViewer release.

## What To Build
- Produce the user guide, troubleshooting guide, capture-permission guide, and curated regression sample catalog.
- Document supported workflows, limitations, and recovery steps.
- Keep product documentation aligned with the actual v1 scope.

## Requirements
- Documentation must cover both beginner setup and advanced analysis workflows.
- Capture-permission guidance must be specific to macOS.
- Sample captures should help future regression testing as well as user education.

## Dependencies
- v0.5.5 release-grade permissions onboarding.
- v1.0.1 stability sweep.

## Tests
- Unit tests: not applicable for the documentation files themselves.
- Integration tests: validate documented workflows against the actual shipped behavior during release verification.
- UI tests: out of scope.

## Out Of Scope
- Marketing copy or website content.
- Video tutorials.
