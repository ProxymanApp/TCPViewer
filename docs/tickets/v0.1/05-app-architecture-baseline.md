# v0.1.5 App Architecture Baseline

## Summary
Define the core app structure for session state, document state, background work, and large-capture safety before UI and engine features expand.

## What To Build
- Document the major app subsystems and their responsibilities.
- Define stable models for packets, streams, filters, graphs, expert events, and profiles.
- Set expectations for background decoding, cancellation, and thread-safe updates into SwiftUI.

## Requirements
- Keep the app target free of direct PcapPlusPlus ownership and pointer logic.
- State management must scale to large traces without blocking the main thread.
- The architecture must support multiple windows and saved workspaces later in the roadmap.

## Dependencies
- v0.1.2 PcapPlusPlusCore integration strategy.
- v0.1.4 test harness and fixtures strategy.

## Tests
- Unit tests: cover reducers, view models, selection logic, and background state transitions.
- Integration tests: cover document open/save/reopen state movement with fixture captures.
- UI tests: out of scope.

## Out Of Scope
- Final visual design details.
- Full performance optimization work.
