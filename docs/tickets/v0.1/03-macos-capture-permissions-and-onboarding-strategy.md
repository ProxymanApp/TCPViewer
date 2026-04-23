# v0.1.3 macOS Capture Permissions And Onboarding Strategy

## Summary
Plan a reliable macOS-native onboarding path for packet capture, including non-root capture setup, permission failures, and first-run guidance.

## What To Build
- Define the supported non-root capture model and fallback behavior.
- Document the onboarding states the app must handle before capture can start.
- Define user-facing failure messages for missing permissions, hidden interfaces, and unsupported capture states.

## Requirements
- The app must not require users to guess how to enable capture access.
- The plan must explicitly cover first launch, upgrades, broken setup, and recovery.
- Guidance must fit macOS-native expectations and not depend on UI tests.

## Dependencies
- v0.1.1 roadmap and docs scaffold.

## Tests
- Unit tests: cover permission-state models and recovery-state transitions.
- Integration tests: cover successful onboarding, denied access, broken setup, and recovery flows using mocked permission states.
- UI tests: out of scope.

## Out Of Scope
- Wireless capture depth.
- Release engineering and code signing.
