# v0.5.5 Release-Grade Permissions Onboarding

## Summary
Turn the macOS capture-permissions strategy into a release-grade onboarding flow suitable for first-time Packetry users.

## What To Build
- Define the MVP onboarding steps, retry behavior, and recovery flows for capture access.
- Cover empty-state guidance when no usable interfaces are available.
- Specify how the app distinguishes setup problems from runtime capture failures.

## Requirements
- The onboarding flow must be clear enough for non-expert users.
- Failure messaging must guide recovery instead of exposing raw system details only.
- The MVP release cannot depend on UI tests to validate onboarding quality.

## Dependencies
- v0.1.3 macOS capture permissions and onboarding strategy.
- v0.5.1 first usable release path.

## Tests
- Unit tests: cover onboarding-state reducers and message selection logic.
- Integration tests: cover successful setup, denied setup, no-interface states, and recovery after fixing permissions.
- UI tests: out of scope.

## Out Of Scope
- Code signing and notarization.
- Wireless capture depth.
