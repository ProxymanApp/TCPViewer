# v0.2.4 Offline File Pipeline

## Status
COMPLETE

## Summary
Define how TCPViewer opens, reopens, saves, and saves-as capture files so offline analysis is a first-class workflow from the beginning.

## What To Build
- Establish file I/O contracts for `pcap` and `pcapng`.
- Define document states for open, modified, saved, and reopened captures.
- Prepare internal abstractions for later merge/import/export work without committing to the full export surface yet.

## Requirements
- File operations must preserve packet ordering and timestamps.
- The app must be able to reopen existing captures quickly and deterministically.
- The file layer must support future metadata-rich `pcapng` workflows.

## Delivered Artifacts
- `PcapPlusPlusCore/Models/CoreProtocols.swift` adds `OfflineCaptureDocumentProviding`, while `PcapPlusPlusCore/Models/CaptureModels.swift` owns document metadata and explicit open/save/reopen phases.
- `PcapPlusPlusCore/Services/OfflineCapture/NativeOfflineCaptureDocument.swift` replaces the one-shot loader with an actor-backed document handle that streams packet batches and metadata changes during open, save, and reopen.
- `PcapPlusPlusCore/NativeBridge/TCPViewerNativeBridge.mm` reads real `pcap` and `pcapng` files, persists packet order and timestamps, preserves `pcapng` metadata on `pcapng` round-trips, and intentionally drops unsupported metadata when saving to `pcap`.
- `TCPViewer/WorkspaceFoundation.swift` wires save, save-as, and reopen flows into the window snapshot and keeps background work cancelable per window.

## Verification
- `PcapPlusPlusCoreTests.offlineDocumentsRoundTripPcapngMetadataAndDropUnsupportedMetadataInPcap()`
- `WindowControllerTests.documentOpenReopenSaveAndSaveAsUpdateSnapshot()`

## Dependencies
- v0.1.2 PcapPlusPlusCore integration strategy.
- v0.1.5 app architecture baseline.

## Tests
- Unit tests: cover document-state transitions and save-path validation.
- Integration tests: cover open/save/save-as/reopen round-trips for `pcap` and `pcapng` fixtures.
- UI tests: out of scope.

## Out Of Scope
- Merge UI.
- Export tables or stream payloads.
