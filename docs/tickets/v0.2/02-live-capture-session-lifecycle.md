# v0.2.2 Live Capture Session Lifecycle

## Status
COMPLETE

## Summary
Define the live capture engine contract for starting, stopping, pausing, resuming, and reporting capture health during long-running sessions.

## What To Build
- Model capture session states and legal transitions.
- Define error, packet-loss, and recovery signaling from `PcapPlusPlusCore` to the app.
- Cover long-running capture stability and safe teardown.

## Requirements
- Session control must support cancellation and repeated start-stop cycles.
- Packet-loss visibility must be explicit instead of hidden.
- The contract must not assume a single-window or single-document future.

## Delivered Artifacts
- `PcapPlusPlusCore/CoreFacadeTypes.swift` adds `LiveCaptureSessionProviding`, `PacketIngestEvent`, `CaptureHealthSnapshot`, and the public lifecycle phase model.
- `PcapPlusPlusCore/NativeLiveCaptureSession.swift` wraps one native session inside an actor-backed Swift handle, exposes an `AsyncThrowingStream`, and supports `start`, `pause`, `resume`, and `stop`.
- `PcapPlusPlusCore/NativeBridge/PacketryNativeBridge.mm` owns the actual live device, translates native phase and drop counters, and keeps packet ownership on the core side.
- `Packetry/WorkspaceFoundation.swift` consumes live session events per window and keeps packet counts, drop counters, and lifecycle state cancelable at the controller layer.

## Verification
- `WindowControllerTests.liveCaptureLifecycleAppliesEventsAndHealth()`
- `xcodebuild test -project Packetry.xcodeproj -scheme Packetry -destination 'platform=macOS'`

## Dependencies
- v0.2.1 interface inventory and selection contract.
- v0.1.5 app architecture baseline.

## Tests
- Unit tests: cover lifecycle state transitions, pause/resume rules, and error propagation.
- Integration tests: cover successful capture sessions, teardown, restart, and simulated dropped-packet scenarios.
- UI tests: out of scope.

## Out Of Scope
- Ring buffer file rotation details.
- Display filter behavior.
