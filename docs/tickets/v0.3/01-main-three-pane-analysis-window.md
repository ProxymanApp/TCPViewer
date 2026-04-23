# v0.3.1 Main Three-Pane Analysis Window

## Summary
Define the primary Packetry desktop workflow: packet list, decoded packet detail tree, and raw bytes pane in one efficient analysis layout.

## What To Build
- Specify the layout model and panel responsibilities for the three panes.
- Define selection synchronization between list, details, and bytes.
- Cover default desktop layout behavior and future multi-window compatibility.

## Requirements
- The three-pane workflow must be fast for both live and offline captures.
- The layout must support large traces without blocking the main thread.
- The design should reflect a modern macOS-native SwiftUI experience without breaking the proven analyst workflow.

## Dependencies
- v0.1.5 app architecture baseline.
- v0.2.5 packet ingest model.

## Tests
- Unit tests: cover selection state, pane synchronization, and layout preference persistence hooks.
- Integration tests: cover loading packets into the list and selecting packets to update detail and bytes panes together.
- UI tests: out of scope.

## Out Of Scope
- Advanced graphs and statistics windows.
- Packet triage features such as mark or ignore.
