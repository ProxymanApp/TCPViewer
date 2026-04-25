# v0.1.3 macOS Capture Permissions And Onboarding Strategy

Status: COMPLETE

## Owned Artifacts
- [docs/product/capture-permissions-and-onboarding.md](../../product/capture-permissions-and-onboarding.md)
- [TCPViewer/CaptureAccessModels.swift](../../../TCPViewer/CaptureAccessModels.swift)

## Definition Of Done
- Define the supported non-root macOS capture model and the repair path TCPViewer will guide users through.
- Lock the onboarding state machine for first run, missing helper, broken helper, denied access, no eligible interfaces, unsupported interfaces, upgrade revalidation, and repair/retry recovery.
- Land pure Swift onboarding models in the app target so later UI work can bind to one stable contract.

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
- Unit tests: cover blocker-to-step mapping, ready-state detection, and recovery-state transitions in `TCPViewerTests`.
- Integration tests: cover mocked helper states for successful onboarding, denied access, broken setup, and repair-retry recovery once the onboarding surface is wired into the app.
- UI tests: out of scope.

## Out Of Scope
- Wireless capture depth.
- Release engineering and code signing.
