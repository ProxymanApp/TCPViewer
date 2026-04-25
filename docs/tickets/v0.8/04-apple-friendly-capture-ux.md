# v0.8.4 Apple-Friendly Capture UX

## Summary
Define the native macOS capture experience for interface quirks, permissions, and Apple-platform expectations without promising full wireless analysis depth.

## What To Build
- Refine interface presentation, empty states, and capture-start ergonomics for macOS users.
- Document how TCPViewer handles Apple-specific interface naming and availability quirks.
- Cover graceful messaging for unsupported or limited interface modes.

## Requirements
- The capture UX must feel native and understandable to users who have never used packet tools before.
- Apple-specific quirks must be surfaced without cluttering the common case.
- The feature must remain compatible with the v0.5 onboarding path.

## Dependencies
- v0.1.3 macOS capture permissions and onboarding strategy.
- v0.2.1 interface inventory and selection contract.

## Tests
- Unit tests: cover interface presentation models and empty-state decisions.
- Integration tests: cover common macOS interface combinations and unsupported interface scenarios.
- UI tests: out of scope.

## Out Of Scope
- Full Wi-Fi monitor-mode tooling.
- Platform support beyond macOS.
