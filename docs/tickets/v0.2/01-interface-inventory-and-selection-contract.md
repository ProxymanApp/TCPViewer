# v0.2.1 Interface Inventory And Selection Contract

## Status
COMPLETE

## Summary
Define how TCPViewer discovers network interfaces and presents them to the app with enough metadata for capture setup and analyst trust.

## What To Build
- Model interface identity, display name, addresses, link type, activity preview hooks, and capture capability flags.
- Define the selection contract the UI will use before a capture starts.
- Include support for loopback, hidden, and unavailable interfaces.

## Requirements
- Interface discovery must originate from `PcapPlusPlusCore`.
- App-facing models must be stable and testable.
- The contract must support future macOS-specific metadata and wireless-facing quirks without redesign.

## Delivered Artifacts
- `PcapPlusPlusCore/Models/CaptureModels.swift` expands `CaptureInterfaceSummary` with technical name, description, loopback state, availability reason, activity preview, addresses, and capability flags.
- `PcapPlusPlusCore/NativeBridge/TCPViewerNativeBridge.mm` performs real interface discovery through `PcapPlusPlus` and maps macOS-facing capability and availability metadata into stable descriptors.
- `PcapPlusPlusCore/NativeBridge/NativeBridgeSupport.swift` adds deterministic sorting so selectable non-loopback interfaces appear first, loopback follows, and disabled/hidden/unavailable interfaces fall to the end.
- `TCPViewer/WorkspaceFoundation.swift` recomputes selection validity on refresh and clears stale selections with an explicit user-facing reason instead of silently failing start.

## Verification
- `CoreFacadeTypesTests.interfaceSortingPrefersSelectableEthernetThenLoopbackThenUnavailable()`
- `WindowControllerTests.refreshClearsStaleInterfaceSelectionWhenInventoryChanges()`

## Dependencies
- v0.1.2 PcapPlusPlusCore integration strategy.
- v0.1.5 app architecture baseline.

## Tests
- Unit tests: cover capability mapping, sorting, filtering, and display-name formatting.
- Integration tests: cover discovery on machines with multiple interface types and simulated unavailable interfaces.
- UI tests: out of scope.

## Out Of Scope
- Starting live capture.
- Permissions onboarding UX copy.
